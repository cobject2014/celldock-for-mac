import Foundation
import CryptoKit
import CommonCrypto
import Security

public enum BackupArchive {
    private static let chunkSize = 1_048_576
    private static let magic = Data("CDOCKB01".utf8)
    private static let rounds: UInt32 = 600_000

    public static func seal(_ snapshot: BackupSnapshot, to output: URL, password: String,
                            progress: (UInt64) -> Void, cancelled: () -> Bool) throws {
        try BackupPolicy.validateManifest(snapshot.manifest)
        guard password.count >= 12 else { throw BackupError.shortPassword }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw BackupError.invalid("destination exists") }
        let privateRoot = try BackupFiles.privateDirectory()
        defer { try? FileManager.default.removeItem(at: privateRoot) }
        let local = privateRoot.appendingPathComponent("encrypted")
        let salt = try random(16), prefix = try random(8)
        let header = magic + bytes(rounds) + salt + prefix
        let key = try derive(password, salt: salt)
        let handle = try BackupFiles.newFile(local)
        defer { try? handle.close() }
        try handle.write(contentsOf: header)
        var sequence: UInt32 = 0
        var total: UInt64 = 0
        func frame(_ type: UInt8, _ data: Data) throws {
            guard !cancelled() else { throw BackupError.cancelled }
            guard sequence < UInt32.max else { throw BackupError.invalid("too many frames") }
            let frameHeader = Data([type]) + bytes(sequence) + bytes(UInt32(data.count))
            let nonce = try AES.GCM.Nonce(data: prefix + bytes(sequence))
            let box = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: header + frameHeader)
            try handle.write(contentsOf: frameHeader + box.ciphertext + box.tag)
            sequence += 1
        }
        let manifestData = try JSONEncoder().encode(snapshot.manifest)
        guard manifestData.count <= BackupPolicy.maxManifest else { throw BackupError.invalid("manifest too large") }
        try frame(0, manifestData)
        for (index, entry) in snapshot.manifest.files.enumerated() {
            let url = try BackupFiles.checkedFile(root: snapshot.root, path: entry.path)
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            var offset: UInt64 = 0
            var hash = SHA256()
            while offset < entry.size {
                let data = try exact(reader, Int(min(UInt64(chunkSize), entry.size - offset)))
                hash.update(data: data)
                try frame(1, bytes(UInt32(index)) + bytes(offset) + data)
                offset += UInt64(data.count); total += UInt64(data.count); progress(total)
            }
            guard try reader.read(upToCount: 1)?.isEmpty != false,
                  hex(hash.finalize()) == entry.sha256 else { throw BackupError.invalid("source changed") }
        }
        try frame(2, Data(SHA256.hash(data: manifestData)) + bytes(sequence) + bytes(total))
        try handle.synchronize()
        try handle.close()
        guard !cancelled() else { throw BackupError.cancelled }
        let partial = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        try FileManager.default.copyItem(at: local, to: partial)
        let published = try FileHandle(forWritingTo: partial)
        try published.synchronize(); try published.close()
        guard try BackupFiles.hash(local) == BackupFiles.hash(partial), !cancelled() else { throw BackupError.cancelled }
        // moveItem refuses to replace an existing destination.
        try FileManager.default.moveItem(at: partial, to: output)
    }

    public static func open(_ archive: URL, into staging: URL, password: String,
                            progress: (UInt64) -> Void, cancelled: () -> Bool) throws -> BackupSnapshot {
        guard !FileManager.default.fileExists(atPath: staging.path) else { throw BackupError.invalid("staging exists") }
        let reader = try FileHandle(forReadingFrom: archive)
        defer { try? reader.close() }
        let header = try exact(reader, 36)
        guard header.prefix(8) == magic, number(header.subdata(in: 8..<12)) == UInt64(rounds) else {
            throw BackupError.invalid("unsupported archive")
        }
        let key = try derive(password, salt: header.subdata(in: 12..<28))
        let prefix = header.suffix(8)
        var sequence: UInt32 = 0
        var total: UInt64 = 0
        func frame(_ expected: UInt8, length: Int? = nil) throws -> Data {
            guard !cancelled() else { throw BackupError.cancelled }
            guard sequence < UInt32.max else { throw BackupError.invalid("too many frames") }
            let frameHeader = try exact(reader, 9)
            let count = Int(number(frameHeader.suffix(4)))
            guard frameHeader[0] == expected, number(frameHeader.subdata(in: 1..<5)) == UInt64(sequence),
                  count <= (expected == 0 ? BackupPolicy.maxManifest : chunkSize + 12),
                  length == nil || count == length else { throw BackupError.invalid("invalid frame") }
            let ciphertext = try exact(reader, count)
            let tag = try exact(reader, 16)
            let nonce = try AES.GCM.Nonce(data: prefix + bytes(sequence))
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(sealed, using: key, authenticating: header + frameHeader)
            sequence += 1
            return plaintext
        }
        let manifestData = try frame(0)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        try BackupPolicy.validateManifest(manifest)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: staging) } }
        for (index, entry) in manifest.files.enumerated() {
            let url = staging.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let writer = try BackupFiles.newFile(url)
            defer { try? writer.close() }
            var hash = SHA256()
            var offset: UInt64 = 0
            while offset < entry.size {
                let expectedCount = Int(min(UInt64(chunkSize), entry.size - offset))
                let data = try frame(1, length: expectedCount + 12)
                guard number(data.prefix(4)) == UInt64(index), number(data.subdata(in: 4..<12)) == offset else {
                    throw BackupError.invalid("entry offset mismatch")
                }
                let payload = data.dropFirst(12)
                try writer.write(contentsOf: payload); hash.update(data: payload)
                offset += UInt64(payload.count); total += UInt64(payload.count); progress(total)
            }
            guard hex(hash.finalize()) == entry.sha256 else { throw BackupError.invalid("entry checksum mismatch") }
            try writer.synchronize(); try writer.close()
        }
        let expectedEnd = Data(SHA256.hash(data: manifestData)) + bytes(sequence) + bytes(total)
        guard try frame(2, length: 44) == expectedEnd, try reader.read(upToCount: 1)?.isEmpty != false else {
            throw BackupError.invalid("missing or invalid end marker")
        }
        success = true
        return BackupSnapshot(root: staging, manifest: manifest)
    }

    private static func derive(_ password: String, salt: Data) throws -> SymmetricKey {
        guard password.utf8.count <= 4096 else { throw BackupError.invalid("password too long") }
        var output = Data(count: 32)
        let passwordBytes = Array(password.utf8)
        let result = output.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordBytes.withUnsafeBytes { pass in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.bindMemory(to: Int8.self).baseAddress,
                        pass.count, saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, out.bindMemory(to: UInt8.self).baseAddress, 32)
                }
            }
        }
        guard result == kCCSuccess else { throw BackupError.invalid("key derivation failed") }
        defer { output.resetBytes(in: 0..<output.count) }
        return SymmetricKey(data: output)
    }
    private static func random(_ size: Int) throws -> Data {
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, size, $0.baseAddress!) }
        guard result == errSecSuccess else { throw BackupError.invalid("random source failed") }
        return data
    }
    private static func bytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }
    private static func number<S: DataProtocol>(_ bytes: S) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    private static func exact(_ file: FileHandle, _ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let data = try file.read(upToCount: count - result.count), !data.isEmpty else { throw BackupError.invalid("truncated archive") }
            result.append(data)
        }
        return result
    }
}

public enum BackupFiles {
    public static func privateDirectory(parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let root = parent.appendingPathComponent("CellDock-backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    static func newFile(_ url: URL) throws -> FileHandle {
        guard !FileManager.default.fileExists(atPath: url.path), FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw BackupError.invalid("cannot create file")
        }
        return try FileHandle(forWritingTo: url)
    }
    public static func checkedFile(root: URL, path: String) throws -> URL {
        try BackupPolicy.validateRelativePath(path)
        var url = root
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw BackupError.invalid("symbolic link") }
        }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw BackupError.invalid("not a regular file") }
        return url
    }
    public static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
