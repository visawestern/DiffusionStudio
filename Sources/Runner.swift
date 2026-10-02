import AppKit
import Foundation

enum RunStage: String, CaseIterable {
    case idle = "Не запущено"
    case loading = "Загрузка моделей"
    case encoding = "Кодирование промпта"
    case sampling = "Сэмплирование"
    case decoding = "Декодирование (VAE)"
    case saving = "Сохранение"
    case done = "Готово"
    case failed = "Ошибка"
    case cancelled = "Отменено"

    /// Стадии, которые реально проходит пайплайн, в порядке выполнения.
    /// `idle/done/failed/cancelled` — терминальные состояния, в бюджет не входят.
    static let pipeline: [RunStage] = [.loading, .encoding, .sampling, .decoding, .saving]

    var isPipelineStage: Bool { RunStage.pipeline.contains(self) }

    /// Порядковый номер стадии в пайплайне; -1 для терминальных.
    var pipelineIndex: Int { RunStage.pipeline.firstIndex(of: self) ?? -1 }
}

private let barStep = try? NSRegularExpression(pattern: "(\\d+)/(\\d+)\\s*-\\s*([0-9]+(?:\\.[0-9]+)?)(s/it|it/s)")
private let tokenCountRE = try? NSRegularExpression(pattern: "to\\s+(\\d+)\\s+tokens")
private let tookSecondsRE = try? NSRegularExpression(pattern: "taking\\s+([0-9]+(?:\\.[0-9]+)?)s")

@MainActor
final class GenerationRunner: ObservableObject {
    static let defaultRoot = AppConstants.defaultRoot

    @Published var stage: RunStage = .idle
    @Published var logLines: [String] = []
    @Published var stepsDone: Int = 0
    @Published var stepsTotal: Int = 0
    @Published var secondsPerStep: Double = 0
    @Published var isRunning = false
    @Published var resultImage: NSImage?
    @Published var exitMessage: String = ""
    @Published var lastRunSeconds: Double = 0

    /// Бюджет времени по стадиям для текущего запуска. Пересобирается, как
    /// только появляются фактические замеры из лога.
    @Published private(set) var budget: StageBudget?

    /// Сколько секунд прошло внутри текущей стадии — им меряется прогресс
    /// стадий, для которых `sd-cli` не даёт точного счётчика.
    @Published private(set) var stageElapsed: Double = 0

    /// Итоговая доля выполненной работы, 0...1. Никогда не уменьшается.
    @Published private(set) var fraction: Double = 0

    /// Метка точности: точно (счётчик шагов), по оценке (время) или финал.
    var progressIsExact: Bool { stage == .sampling || stage == .done }

    private var highestFraction: Double = 0
    private var stageStartedAt: Date?

    // Калибровка бюджета фактическими замерами из лога. Видна наружу, чтобы
    // selftest мог проверить, что парсер действительно подхватил значения.
    private(set) var promptTokens: Int?
    private(set) var measuredLoading: Double?
    private(set) var measuredEncoding: Double?
    private(set) var measuredDecoding: Double?
    private var completedStages: Set<RunStage> = []

    /// Общий прогресс работы над картинкой: веса пройденных стадий плюс
    /// прогресс внутри текущей.
    var progressFraction: Double {
        guard let budget, stage.isPipelineStage else {
            return stage == .done ? 1.0 : fraction
        }
        let weight = budget.weight(of: stage)
        let within = stageFraction
        let raw = budget.offset(of: stage) + weight * within
        return min(1, max(highestFraction, raw))
    }

    /// Доля выполнения внутри текущей стадии, 0...1.
    var stageFraction: Double {
        switch stage {
        case .sampling:
            return stepsTotal > 0 ? min(1, Double(stepsDone) / Double(stepsTotal)) : 0
        case .loading, .encoding, .decoding, .saving:
            guard let budget else { return 0 }
            let planned = budget.seconds(for: stage)
            guard planned > 0 else { return 0 }
            return min(1, stageElapsed / planned)
        case .idle, .done, .failed, .cancelled:
            return stage == .done ? 1 : 0
        }
    }

    /// Сколько примерно осталось до конца генерации.
    var etaSeconds: Double? {
        guard isRunning, let budget, stage.isPipelineStage else { return nil }
        var remaining = 0.0
        for candidate in RunStage.pipeline {
            if completedStages.contains(candidate) { continue }
            let planned = budget.seconds(for: candidate)
            if candidate == stage {
                remaining += planned * (1 - stageFraction)
            } else if candidate.pipelineIndex > stage.pipelineIndex {
                remaining += planned
            }
        }
        return remaining > 0 ? remaining : nil
    }

    var percentText: String {
        String(format: "%.1f%%", progressFraction * 100)
    }

    /// Сколько секунд идёт генерация целиком.
    var lastElapsedSeconds: Double {
        guard let startedAt = startedAt else { return lastRunSeconds }
        return isRunning ? Date().timeIntervalSince(startedAt) : lastRunSeconds
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

    /// Разбивка по стадиям для панели прогресса: вес, доля и текст времени.
    var stageBreakdown: [StageRow] {
        guard let budget else { return [] }
        let index = stage.pipelineIndex
        return RunStage.pipeline.map { s in
            let weight = budget.weight(of: s)
            let progress: Double
            if completedStages.contains(s) {
                progress = 1
            } else if s == stage {
                progress = stageFraction
            } else if index >= 0, s.pipelineIndex < index {
                progress = 1
            } else {
                progress = 0
            }
            return StageRow(
                stage: s,
                weight: weight,
                progress: progress,
                seconds: budget.seconds(for: s),
                state: completedStages.contains(s) ? .finished
                    : (s == stage ? .running : .pending)
            )
        }
    }

    /// Долгоживущий локальный движок: держит веса модели в памяти между
    /// генерациями, поэтому вторая картинка не читает 14.6 ГБ заново.
    let engine = EngineServer()

    private var generationTask: Task<Void, Never>?
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

    /// Сброс состояния отслеживания прогресса перед стартом.
    func beginTracking(_ settings: GenerationSettings) {
        stage = .loading
        currentSettings = settings
        stepsDone = 0
        stepsTotal = settings.steps
        secondsPerStep = 0
        resultImage = nil
        exitMessage = ""
        startedAt = Date()
        lastRunSeconds = 0
        promptTokens = nil
        measuredLoading = nil
        measuredEncoding = nil
        measuredDecoding = nil
        completedStages = []
        stageStartedAt = Date()
        highestFraction = 0
        fraction = 0
        stageElapsed = 0
        budget = StageBudget.projected(settings: settings)
    }

    func run(_ settings: GenerationSettings) {
        guard !isRunning else { return }
        let problems = settings.problems
        if !problems.isEmpty {
            stage = .failed
            exitMessage = problems.joined(separator: "\n")
            problems.forEach { append("! " + $0) }
            return
        }

        lastKnownOutput = settings.outputURL
        logLines.removeAll()
        append("$ " + requestDescription(settings))

        isRunning = true
        beginTracking(settings)

        engine.onLine = { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }

        generationTask = Task { @MainActor [weak self] in
            await self?.performRun(settings)
        }
    }

    private func requestDescription(_ s: GenerationSettings) -> String {
        let size = s.resolvedSize
        return "sd-server POST /sdcpp/v1/img_gen "
            + "\(size.width)x\(size.height) · \(s.steps) \(GenerationSettings.stepsWord(s.steps)) · "
            + "\(s.sampler.rawValue) · seed \(s.randomSeed ? -1 : s.seed)"
    }

    private func performRun(_ settings: GenerationSettings) async {
        do {
            let wasWarm = engine.isWarm
            try await engine.ensureReady(settings)
            if wasWarm {
                // Ключевая экономия: веса уже в памяти, повторного чтения
                // 14.6 ГБ не будет — стадия загрузки вырождается в ноль.
                measuredLoading = 0
                recomputeBudget()
            } else {
                append("— первый запуск: веса читаются с диска, дальше останутся в памяти —")
            }

            let images = try await engine.generate(settings) { [weak self] message in
                self?.append("  " + message)
            }

            try write(images: images, settings: settings)
            finishAllStages()
            isRunning = false
            stopPolling()
        } catch is CancellationError {
            isRunning = false
            stage = .cancelled
            append("— генерация отменена —")
        } catch {
            isRunning = false
            stage = .failed
            exitMessage = error.localizedDescription
            append("! " + error.localizedDescription)
        }
    }

    /// `sd-server` возвращает готовые PNG внутри ответа и файлы не пишет —
    /// сохраняет их приложение.
    private func write(images: [GeneratedImage], settings: GenerationSettings) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: URL(fileURLWithPath: settings.resolvedOutputDirectory),
            withIntermediateDirectories: true
        )
        let single = images.count == 1
        for image in images {
            let target = single ? settings.outputURL : batchURL(settings, image.index)
            try image.data.write(to: target, options: .atomic)
            append("— сохранено: " + target.path)
        }
        lastKnownOutput = images.count == 1 ? settings.outputURL : batchURL(settings, 0)
        if let img = NSImage(data: images[0].data) {
            resultImage = img
        }
    }

    private func batchURL(_ settings: GenerationSettings, _ index: Int) -> URL {
        URL(fileURLWithPath: settings.resolvedOutputDirectory)
            .appendingPathComponent("\(settings.outputName)-\(index).png")
    }

    func cancel() {
        guard isRunning else { return }
        append("— отмена по запросу —")
        generationTask?.cancel()
        Task { @MainActor in
            await engine.cancel()
        }
        stage = .cancelled
    }

    /// Останавливает движок и выгружает веса из памяти.
    func shutdownEngine() {
        engine.stop()
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

    /// Разбор одной строки вывода. Внутренний, чтобы его можно было прогнать
    /// в selftest на реальных строках лога.
    func consume(_ raw: String) {
        append(raw)

        let lower = raw.lowercased()

        if lower.contains("[error") {
            exitMessage = raw.trimmingCharacters(in: .whitespaces)
        }

        parseMeasurements(from: raw)
        advanceStage(from: raw)
        applyProgress(from: raw)
    }

    /// Вытаскивает из лога то, что можно использовать как калибровку бюджета:
    /// число токенов промпта и фактическое время завершившихся стадий.
    private func parseMeasurements(from line: String) {
        let range = NSRange(line.startIndex..., in: line)

        if let m = tokenCountRE?.firstMatch(in: line, range: range),
           let text = capture(m, at: 1, in: line),
           let tokens = Int(text), promptTokens == nil {
            promptTokens = tokens
            recomputeBudget()
        }

        let took = tookSecondsRE?.firstMatch(in: line, range: range)
            .flatMap { capture($0, at: 1, in: line) }
            .flatMap { Double($0) }

        // `loading tensors completed` приходит трижды: энкодер, диффузия, VAE.
        if normalized(line).contains("loading tensors completed"), let took {
            measuredLoading = (measuredLoading ?? 0) + took
            if stage == .decoding || stage == .saving { recomputeBudget() }
        }
        if normalized(line).contains("get_learned_condition completed"), let took {
            measuredEncoding = took
            recomputeBudget()
        }
        if normalized(line).contains("decoded, taking") && !normalized(line).contains("get_learned"), let took {
            measuredDecoding = took
            recomputeBudget()
        }
    }

    /// Переходы между стадиями строго по порядку пайплайна: назад полоса не
    /// откатывается даже если строки в логе перемешались.
    private func advanceStage(from line: String) {
        let lower = normalized(line)
        let target: RunStage?

        if lower.contains("images saved") || lower.contains("generate_image completed") {
            target = .done
        } else if lower.contains("generate_image ") || lower.contains("llm_encode") || lower.contains("clip_encode") {
            target = .encoding
        } else if lower.contains("get_learned_condition completed") || lower.contains("sampling using ") {
            target = .sampling
        } else if lower.contains("sampling completed") || lower.contains("decoding vae") || lower.contains("vae decode graph") {
            target = .decoding
        } else if lower.contains("save result image") {
            target = .saving
        } else {
            target = nil
        }

        guard let target else { return }
        if target == .done {
            finishAllStages()
            return
        }
        guard target.pipelineIndex > stage.pipelineIndex || (target == stage) else { return }
        enterStage(target)
    }

    private func normalized(_ line: String) -> String { line.lowercased() }

    private func enterStage(_ next: RunStage) {
        if stage.isPipelineStage, !completedStages.contains(stage) {
            let spent = Date().timeIntervalSince(stageStartedAt ?? Date())
            recordActual(stage, seconds: spent)
        }
        stage = next
        stageStartedAt = Date()
        stageElapsed = 0
    }

    /// После завершения стадии подставляем её реальную длительность в бюджет,
    /// чтобы последующие стадии оценивались по факту, а не по модели.
    private func recordActual(_ s: RunStage, seconds: Double) {
        completedStages.insert(s)
        switch s {
        case .loading: if measuredLoading == nil { measuredLoading = seconds }
        case .encoding: if measuredEncoding == nil { measuredEncoding = seconds }
        case .decoding: if measuredDecoding == nil { measuredDecoding = seconds }
        default: break
        }
        recomputeBudget()
        updateFraction()
    }

    private func finishAllStages() {
        if stage.isPipelineStage, !completedStages.contains(stage) {
            let spent = Date().timeIntervalSince(stageStartedAt ?? Date())
            recordActual(stage, seconds: spent)
        }
        for s in RunStage.pipeline { completedStages.insert(s) }
        stage = .done
        stageStartedAt = nil
        stageElapsed = 0
        highestFraction = 1
        fraction = 1
    }

    private func recomputeBudget() {
        guard let settings = currentSettings else { return }
        budget = StageBudget.projected(
            settings: settings,
            promptTokens: promptTokens,
            measuredStepSeconds: secondsPerStep > 0 ? secondsPerStep : nil,
            measuredLoading: measuredLoading,
            measuredEncoding: measuredEncoding,
            measuredDecoding: measuredDecoding
        )
    }

    private func updateFraction() {
        guard let budget, stage.isPipelineStage else { return }
        let raw = budget.offset(of: stage) + budget.weight(of: stage) * stageFraction
        highestFraction = max(highestFraction, min(1, raw))
        fraction = highestFraction
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isRunning else { return }
        if let stageStartedAt = stageStartedAt {
            stageElapsed = Date().timeIntervalSince(stageStartedAt)
        }
        updateFraction()
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
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