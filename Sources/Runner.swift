import AppKit
import Foundation

enum RunStage: String {
    case idle = "Не запущено"
    case loading = "Загрузка моделей"
    case encoding = "Кодирование промпта"
    case sampling = "Сэмплирование"
    case decoding = "Декодирование (VAE)"
    case done = "Готово"
    case failed = "Ошибка"
    case cancelled = "Отменено"
}

private let barStep = try? NSRegularExpression(pattern: "(\\d+)/(\\d+)\\s*-\\s*([0-9]+(?:\\.[0-9]+)?)(s/it|it/s)")

@MainActor
final class GenerationRunner: ObservableObject {
    static let defaultRoot = AppConstants.defaultRoot

    @Published var stage: RunStage = .idle
    @Published var logLines: [String] = []
    @Published var stepsDone: Int = 0
    @Published var stepsTotal: Int = 0
    @Published var secondsPerStep: Double = 0
    @Published var isRunning = false
    @Published var previewImage: NSImage?
    @Published var resultImage: NSImage?
    @Published var exitMessage: String = ""
    @Published var lastRunSeconds: Double = 0

    var progressFraction: Double? {
        if stage == .sampling, stepsTotal > 0 {
            return Double(stepsDone) / Double(stepsTotal)
        }
        if stage == .loading || stage == .encoding || stage == .decoding { return nil }
        if stage == .done { return 1.0 }
        return nil
    }

    var etaSeconds: Double? {
        guard stage == .sampling, stepsTotal > 0, secondsPerStep > 0 else { return nil }
        let remaining = max(0, stepsTotal - stepsDone)
        guard remaining > 0 else { return nil }
        return Double(remaining) * secondsPerStep
    }

    var stepSummary: String {
        guard stepsTotal > 0 else { return "" }
        let rate = secondsPerStep > 0
            ? String(format: "%.1f с/шаг", secondsPerStep)
            : "—"
        return "\(stepsDone)/\(stepsTotal) · \(rate)"
    }

    var logVisibleHint: String {
        guard let eta = etaSeconds else { return "" }
        return "осталось ≈ " + GenerationSettings.human(eta)
    }

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var pollTimer: Timer?
    private var startedAt: Date?

    func clearLog() {
        logLines.removeAll()
    }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 5000 {
            logLines.removeFirst(logLines.count - 5000)
        }
    }

    func isBusy() -> Bool { isRunning }

    func run(_ settings: GenerationSettings) {
        guard !isRunning else { return }
        let problems = settings.problems
        if !problems.isEmpty {
            stage = .failed
            exitMessage = problems.joined(separator: "\n")
            problems.forEach { append("! " + $0) }
            return
        }

        let args = settings.buildArguments()
        currentSettings = settings
        lastKnownOutput = settings.outputURL
        logLines.removeAll()
        append("$ build/bin/sd-cli " + args.joined(separator: " "))

        let proc = Process()
        proc.executableURL = settings.binaryURL
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: settings.rootPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        stage = .loading
        isRunning = true
        stepsDone = 0
        stepsTotal = settings.steps
        secondsPerStep = 0
        previewImage = nil
        resultImage = nil
        exitMessage = ""
        startedAt = Date()
        lastRunSeconds = 0

        let collector = LineCollector { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }

        outPipe.fileHandleForReading.readabilityHandler = { h in
            collector.feed(h.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            collector.feed(h.availableData)
        }

        do {
            try proc.run()
            process = proc
            self.outPipe = outPipe
            self.errPipe = errPipe
            startPolling()
        } catch {
            isRunning = false
            stage = .failed
            exitMessage = "Не удалось запустить: \(error.localizedDescription)"
            append("! " + exitMessage)
        }
    }

    func cancel() {
        guard let proc = process, proc.isRunning else { return }
        append("— отмена по запросу —")
        proc.terminate()
        stage = .cancelled
    }

    func runEnvironmentCheck() {
        let root = currentSettings?.rootPath ?? AppConstants.defaultRoot
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: root).appendingPathComponent("build/bin/sd-cli")
        proc.arguments = ["--list-devices"]
        proc.currentDirectoryURL = URL(fileURLWithPath: root)
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        append("$ sd-cli --list-devices")
        let collector = LineCollector { [weak self] line in
            Task { @MainActor in
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, t.hasPrefix("MTL") || t.hasPrefix("CPU") || t.hasPrefix("BLAS") {
                    self?.append("  " + t)
                }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { h in collector.feed(h.availableData) }
        try? proc.run()
        Thread.detachNewThread { [weak self] in
            proc.waitUntilExit()
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.append("— проверка окружения завершена —")
            }
        }
    }

    func revealOutput() {
        let url = lastKnownOutput
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
        }
    }

    var lastKnownOutput: URL = URL(fileURLWithPath: AppConstants.defaultRoot).appendingPathComponent("outputs")

    private func consume(_ raw: String) {
        append(raw)

        let lower = raw.lowercased()

        if lower.contains("generate_image ") {
            stage = .encoding
        }
        if lower.contains("get_learned_condition completed") {
            stage = .sampling
        }
        if lower.contains("sampling completed") || lower.contains("decoding vae") || lower.contains("vae decode graph") {
            if stage == .sampling || stage == .loading { stage = .decoding }
        }
        if lower.contains("save result image") {
            stage = .done
        }
        if lower.contains("[error") {
            exitMessage = raw.trimmingCharacters(in: .whitespaces)
        }

        applyProgress(from: raw)
    }

    private func applyProgress(from line: String) {
        guard stage == .sampling, let barStep else { return }
        let searchRange = NSRange(line.startIndex..., in: line)
        guard let match = barStep.firstMatch(in: line, range: searchRange) else { return }
        guard let doneText = capture(match, at: 1, in: line),
              let totalText = capture(match, at: 2, in: line),
              let rateText = capture(match, at: 3, in: line),
              let unitText = capture(match, at: 4, in: line) else { return }
        guard let done = Double(doneText), let total = Double(totalText), let rate = Double(rateText) else { return }
        stepsDone = Int(done)
        stepsTotal = Int(total)
        if unitText == "s/it" {
            secondsPerStep = rate
        } else if rate > 0 {
            secondsPerStep = 1.0 / rate
        }
    }

    private func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.detectCompletion()
                self?.refreshImages()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refreshImages() {
        guard let settings = currentSettings else { return }
        lastKnownOutput = settings.outputURL

        let preview = settings.previewURL
        if let img = NSImage(contentsOf: preview) {
            previewImage = img
        }
        if stage == .done || FileManager.default.fileExists(atPath: settings.outputURL.path) {
            if let img = NSImage(contentsOf: settings.outputURL) {
                resultImage = img
                stage = .done
            }
        }
    }

    private func detectCompletion() {
        guard isRunning, let proc = process, !proc.isRunning else { return }
        let status = proc.terminationStatus
        isRunning = false
        process = nil
        if let o = outPipe { o.fileHandleForReading.readabilityHandler = nil }
        if let e = errPipe { e.fileHandleForReading.readabilityHandler = nil }
        outPipe = nil
        errPipe = nil
        stopPolling()
        if let startedAt = startedAt {
            lastRunSeconds = Date().timeIntervalSince(startedAt)
        }
        refreshImages()
        if status != 0 && stage != .done {
            stage = .failed
            exitMessage = "sd-cli завершился с кодом \(status)"
        }
        append("— процесс завершён, код \(status) —")
    }

    var currentSettings: GenerationSettings?
}

final class LineCollector {
    private var buffer = Data()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        var lines: [String] = []
        var current = Data()
        for byte in buffer {
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
        }
        buffer = current
        for l in lines { onLine(l) }
    }
}