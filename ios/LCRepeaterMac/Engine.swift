import Foundation

/// One JSON line from the Whisper·Claude engine (engine_cli.py, bundled as Contents/Helpers/lcr-engine).
struct EngineEvent: Decodable, Sendable {
    let event: String
    var label: String?
    var fraction: Double?
    var message: String?
    var code: String?
    var lesson: String?
    var audio: String?
    var whisper: Bool?
    var claude: String?
    var model: Model?
    var received: Int64?
    var total: Int64?

    struct Model: Decodable, Sendable {
        let ready: Bool
        let path: String
    }
}

struct EngineError: LocalizedError, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }

    static let missingHelper = EngineError(code: "no_engine", message:
        "이 빌드에는 Whisper·Claude 엔진이 들어 있지 않아요. scripts/build_mac.sh로 빌드한 앱을 써 주세요.")
}

/// Runs the bundled Python pipeline, which keeps Whisper transcription and `claude -p` translation
/// identical to the Windows/web version. The helper is not needed for Apple's on-device processing.
enum Engine {
    /// Shared with the previous Python Mac app, so a model it already downloaded is reused.
    static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    static var supportDirectory: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("LC Repeater", isDirectory: true)
    }
    static var modelURL: URL {
        supportDirectory.appendingPathComponent("models", isDirectory: true).appendingPathComponent(modelName)
    }

    /// `LCR_ENGINE` points a development build at engine_cli.py; release builds use the bundled helper.
    static var executableURL: URL? {
        if let override = ProcessInfo.processInfo.environment["LCR_ENGINE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lcr-engine")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    static var isBundled: Bool { executableURL != nil }

    /// Runs one engine command and returns its final `done` event. Progress and log events go to
    /// `onEvent`. Cancelling the task stops the helper together with whisper-cli and claude.
    static func run(_ arguments: [String],
                    onEvent: @escaping @MainActor @Sendable (EngineEvent) -> Void = { _ in }) async throws -> EngineEvent {
        guard let executable = executableURL else { throw EngineError.missingHelper }
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = ["--watch-stdin", "--model", modelURL.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUTF8"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        // The helper exits (and stops its children) when this pipe closes, even if the app crashes.
        process.standardInput = box.input
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("lcr-engine-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log)
        process.standardError = errorHandle
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: log)
        }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            var final: EngineEvent?
            let decoder = JSONDecoder()
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let event = try? decoder.decode(EngineEvent.self, from: Data(line.utf8)) else { continue }
                switch event.event {
                case "done", "error": final = event
                default: await onEvent(event)
                }
            }
            while process.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
            box.close()
            try Task.checkCancellation()
            if let final, final.event == "done", process.terminationStatus == 0 { return final }
            if let final, final.event == "error" {
                throw EngineError(code: final.code ?? "failed", message: final.message ?? "처리하지 못했어요")
            }
            let tail = (try? String(contentsOf: log, encoding: .utf8))?.suffix(600) ?? ""
            throw EngineError(code: "crashed", message: "처리 엔진이 비정상 종료했어요 (코드 \(process.terminationStatus)).\n\(tail)")
        } onCancel: {
            box.stop()
        }
    }
}

/// Process and its stdin pipe, shared with the cancellation handler.
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let input = Pipe()
    private let lock = NSLock()
    private var closed = false

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? input.fileHandleForWriting.close()
    }

    func stop() {
        close()
        if process.isRunning { process.terminate() }
    }
}
