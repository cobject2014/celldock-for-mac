import Foundation

public enum BackupPolicy {
    public static let maxManifest = 16 * 1024 * 1024
    public static let maxBytes: UInt64 = 1 << 40
    public static let rootFiles: Set<String> = ["messages.json", "calls.json", "recordings.json", "deleted-message-ids.json", "preferences.plist", "credentials.json"]
    public static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              rootFiles.contains(path) || (parts.count == 2 && ["Recordings", "Sounds"].contains(String(parts[0]))) else {
            throw BackupError.invalid("invalid entry path")
        }
    }
    public static func validateManifest(_ manifest: BackupManifest) throws {
        guard manifest.formatVersion == 1, manifest.files.count <= 100_000,
              manifest.messageCount >= 0, manifest.callCount >= 0, manifest.recordingCount >= 0 else { throw BackupError.invalid("unsupported manifest") }
        var paths = Set<String>()
        var total: UInt64 = 0
        for file in manifest.files {
            try validateRelativePath(file.path)
            let folded = file.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(folded).inserted, file.sha256.count == 64,
                  file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  file.size <= maxBytes, total <= maxBytes - file.size else { throw BackupError.invalid("invalid or duplicate entry") }
            total += file.size
        }
    }
}
