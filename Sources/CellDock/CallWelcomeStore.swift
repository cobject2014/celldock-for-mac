import Combine
import Foundation

@MainActor
final class CallWelcomeStore: ObservableObject {
    static let shared = CallWelcomeStore()
    typealias Synthesize = (CallWelcomeConfiguration) async throws -> Data
    @Published private(set) var configuration = CallWelcomeConfiguration()
    @Published private(set) var isGenerating = false
    @Published private(set) var lastError: String?
    @Published private(set) var cachedPCM: Data?
    private let directory: URL
    private let synthesize: Synthesize

    // One atomic file binds the exact configuration to its converted audio. Failed
    // generation or a crash during saving cannot pair new text with an old greeting.
    private struct Saved: Codable {
        let configuration: CallWelcomeConfiguration
        let pcm: Data?
    }

    init(directory: URL? = nil,
         synthesize: @escaping Synthesize = { try await CallTTSClient.synthesize(configuration: $0) }) {
        self.directory = directory ?? AppDataDirectory.userApplicationSupport().appendingPathComponent("CallWelcome")
        self.synthesize = synthesize
        let url = self.directory.appendingPathComponent("welcome.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
                configuration = saved.configuration
                if let pcm = saved.pcm, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 8000 * 2 * 300 {
                    cachedPCM = pcm
                } else if configuration.enabled { lastError = CallWelcomeError.notPrepared.localizedDescription }
            } catch { lastError = CallWelcomeError.storage.localizedDescription }
        }
    }

    var audioForCall: Data? { configuration.enabled ? cachedPCM : nil }

    func setEnabled(_ enabled: Bool) throws {
        guard !isGenerating else { throw CallWelcomeError.busy }
        if enabled && cachedPCM == nil { throw CallWelcomeError.notPrepared }
        var value = configuration; value.enabled = enabled
        try persist(value, pcm: cachedPCM)
        configuration = value
        lastError = nil
    }

    func save(_ value: CallWelcomeConfiguration) async throws {
        guard !isGenerating else { throw CallWelcomeError.busy }
        try value.validate()
        isGenerating = true; lastError = nil
        defer { isGenerating = false }
        do {
            let pcm: Data
            if value.hasSameSpeech(as: configuration), let cachedPCM { pcm = cachedPCM }
            else { pcm = try await synthesize(value) }
            try Task.checkCancellation()
            guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 8000 * 2 * 300 else { throw CallWelcomeError.invalidAudio }
            try persist(value, pcm: pcm)
            configuration = value; cachedPCM = pcm
        } catch {
            if !(error is CancellationError) { lastError = CallWelcomeError.message(for: error) }
            throw error
        }
    }

    private func persist(_ value: CallWelcomeConfiguration, pcm: Data?) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Saved(configuration: value, pcm: pcm))
            let temporary = directory.appendingPathComponent(".welcome-\(UUID()).json")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw CallWelcomeError.storage
            }
            let destination = directory.appendingPathComponent("welcome.json")
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        } catch { throw CallWelcomeError.storage }
    }
}
