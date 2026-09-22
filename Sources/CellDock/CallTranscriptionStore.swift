import Combine
import Foundation

@MainActor
final class CallTranscriptionStore: ObservableObject {
    static let shared = CallTranscriptionStore()
    typealias Transcribe = (URL, Bool, CallTranscriptionConfiguration) async throws -> String
    typealias Send = (String, String) async throws -> Void

    @Published private(set) var configuration = CallTranscriptionConfiguration()
    @Published private(set) var jobs: [CallTranscriptionJob] = []
    @Published private(set) var lastError: String?
    private let directory: URL
    private let recordingsDirectory: URL
    private let transcribe: Transcribe
    private let send: Send
    private let pause: (UInt64) async throws -> Void
    private var worker: Task<Void, Never>?
    private var activeID: UUID?
    private var canReadJobs = true

    init(directory: URL? = nil, recordingsDirectory: URL? = nil,
         transcribe: @escaping Transcribe = { try await CallASRClient.transcribe(fileURL: $0, remoteOnly: $1, configuration: $2) },
         send: @escaping Send = { webhook, text in
             let session = URLSession(configuration: .ephemeral)
             defer { session.invalidateAndCancel() }
             try await WeComWebhook.send(webhookURL: webhook, text: text, session: session)
         },
         pause: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        let root = directory == nil || recordingsDirectory == nil ? AppDataDirectory.userApplicationSupport() : nil
        self.directory = directory ?? root!.appendingPathComponent("CallTranscriptions")
        self.recordingsDirectory = recordingsDirectory ?? root!.appendingPathComponent("Recordings")
        self.transcribe = transcribe
        self.send = send
        self.pause = pause
        do {
            let url = self.directory.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: url.path) {
                configuration = try JSONDecoder().decode(CallTranscriptionConfiguration.self, from: Data(contentsOf: url))
            }
        } catch { lastError = CallTranscriptionError.storage.localizedDescription }
        do {
            let url = self.directory.appendingPathComponent("transcriptions.json")
            if FileManager.default.fileExists(atPath: url.path) {
                jobs = try JSONDecoder().decode([CallTranscriptionJob].self, from: Data(contentsOf: url))
                for index in jobs.indices where jobs[index].phase == .transcribing || jobs[index].phase == .sending {
                    jobs[index].phase = .queued
                }
            }
        } catch {
            canReadJobs = false
            lastError = CallTranscriptionError.storage.localizedDescription
        }
    }

    func configure(_ value: CallTranscriptionConfiguration) throws {
        if value.enabled { try value.validate() }
        try write(value, name: "settings.json")
        configuration = value
        lastError = nil
        // Apply edits/disable to the active request as well as queued jobs.
        worker?.cancel()
        start()
    }

    func enqueue(_ record: CallRecordingRecord) {
        guard canReadJobs, configuration.includes(record), !jobs.contains(where: { $0.id == record.id }) else { return }
        jobs.append(CallTranscriptionJob(record: record))
        do {
            try persistJobs()
            start()
        } catch {
            jobs.removeAll { $0.id == record.id }
            lastError = CallTranscriptionError.storage.localizedDescription
        }
    }

    func retry(_ id: UUID) {
        guard configuration.enabled, let index = jobs.firstIndex(where: { $0.id == id && $0.phase == .failed }) else { return }
        jobs[index].phase = .queued
        jobs[index].error = nil
        do { try persistJobs(); start() }
        catch {
            jobs[index].phase = .failed
            lastError = CallTranscriptionError.storage.localizedDescription
        }
    }

    func remove(_ id: UUID) {
        if activeID == id { worker?.cancel() }
        jobs.removeAll { $0.id == id }
        do { try persistJobs() }
        catch { lastError = CallTranscriptionError.storage.localizedDescription }
    }

    func start() {
        guard canReadJobs, configuration.enabled, worker == nil,
              jobs.contains(where: { $0.phase == .queued }) else { return }
        worker = Task { [weak self] in await self?.runQueue() }
    }

    private func runQueue() async {
        defer {
            let wasCancelled = Task.isCancelled
            activeID = nil
            worker = nil
            if wasCancelled { start() }
        }
        while configuration.enabled, !Task.isCancelled,
              let job = jobs.first(where: { $0.phase == .queued }) {
            activeID = job.id
            do {
                let config = configuration
                try config.validate()
                var current = job
                if current.transcript == nil {
                    current.phase = .transcribing
                    try update(current)
                    let text = try await transcribe(recordingsDirectory.appendingPathComponent(job.record.fileName),
                                                    job.record.wasAutomaticallyAnswered == true, config)
                    try Task.checkCancellation()
                    current.transcript = text
                    current.messages = CallTranscriptionText.messages(record: job.record, transcript: text)
                }
                current.phase = .sending
                current.error = nil
                // Checkpoints belong to one destination. Correcting/replacing the webhook
                // sends the complete saved transcript to the new destination on retry.
                if current.deliveryWebhookURL != config.webhookURL {
                    current.deliveryWebhookURL = config.webhookURL
                    current.sentMessageCount = 0
                }
                try update(current)
                while current.sentMessageCount < current.messages.count {
                    // WeCom allows 20 messages/minute per robot. Pace this queue,
                    // including transitions between recordings and manual retries.
                    try await pause(3_100_000_000)
                    try Task.checkCancellation()
                    try await send(current.deliveryWebhookURL!, current.messages[current.sentMessageCount])
                    // Preserve a confirmed acknowledgement even if disabled during the request.
                    current.sentMessageCount += 1
                    try update(current)
                    try Task.checkCancellation()
                }
                current.phase = .sent
                try update(current)
            } catch {
                guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
                jobs[index].phase = Task.isCancelled ? .queued : .failed
                jobs[index].error = Task.isCancelled ? nil : CallTranscriptionError.message(for: error)
                do { try persistJobs() }
                catch { lastError = CallTranscriptionError.storage.localizedDescription; return }
            }
        }
    }

    private func update(_ job: CallTranscriptionJob) throws {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw CancellationError() }
        jobs[index] = job
        try persistJobs()
    }

    private func persistJobs() throws { try write(jobs, name: "transcriptions.json") }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(name)
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw CallTranscriptionError.storage }
    }
}
