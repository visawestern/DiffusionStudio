import AppKit
import Foundation

/// Реестр живых процессов движка.
///
/// `sd-server` держит 14.6 ГБ весов в памяти между генерациями, поэтому живёт
/// дольше окна приложения. Без явной остановки при выходе процесс остался бы
/// висеть и держать память после закрытия программы.
@MainActor
final class EngineRegistry {
    static let shared = EngineRegistry()

    private var engines: [EngineServer] = []

    func register(_ engine: EngineServer) {
        engines.removeAll { $0 === engine }
        engines.append(engine)
    }

    func shutdown() {
        for engine in engines {
            engine.stop()
        }
        engines.removeAll()
    }
}

/// Состояние локального движка.
enum EngineState: Equatable {
    case stopped
    case starting
    case ready
    case failed(String)

    var isBusy: Bool { self == .starting }

    var title: String {
        switch self {
        case .stopped: return "Остановлен"
        case .starting: return "Загружается"
        case .ready: return "Работает"
        case .failed: return "Ошибка"
        }
    }
}

/// Ответ сервера на одну задачу генерации.
struct GeneratedImage {
    let data: Data
    let index: Int
}

/// Долгоживущий процесс `sd-server`.
///
/// Зачем он вместо `sd-cli`: `sd-cli` одноразовый — загрузил 14.6 ГБ весов,
/// отсёкся, выгрузил память. Каждая следующая картинка начиналась заново с
/// чтения 14.6 ГБ с диска. `sd-server` держит веса в памяти между запросами:
/// первый запуск платит за загрузку один раз, дальше она не повторяется.
@MainActor
final class EngineServer: ObservableObject {
    @Published private(set) var state: EngineState = .stopped
    @Published private(set) var isWarm = false

    /// PID процесса сервера, `nil` если он не запущен.
    var serverPid: pid_t? { process?.processIdentifier }
    @Published private(set) var residentMegabytes: Double = 0

    /// Строки из stdout сервера — тот же формат, что у `sd-cli`.
    var onLine: ((String) -> Void)?

    private var process: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private var port = 0
    private var fingerprint = ""
    private var activeJobId: String?
    private var lastResidentSample = Date.distantPast

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    var binaryURL: URL {
        URL(fileURLWithPath: AppConstants.defaultRoot)
            .appendingPathComponent("build/bin/sd-server")
    }

    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryURL.path)
    }

    /// Параметры, при которых сервер надо перезапустить: они задаются при старте
    /// процесса, а не в запросе генерации.
    static func launchFingerprint(_ s: GenerationSettings) -> String {
        [
            s.diffusionModel, s.encoderModel, s.vaeModel, s.backend.rawValue,
            String(s.threads), String(s.maxVRAM), String(s.diffusionFA),
            String(s.vaeTiling), String(s.offloadToCPU),
            String(s.disableSegmentedCompute), String(s.eagerLoad),
        ].joined(separator: "|")
    }

    // MARK: Жизненный цикл процесса

    func start(_ settings: GenerationSettings) {
        guard process == nil else { return }
        guard isInstalled else {
            state = .failed("Нет бинаря sd-server: \(binaryURL.path)")
            append("! Не собран sd-server. Соберите его: cmake --build build --target sd-server")
            return
        }

        state = .starting
        port = Self.freePort()
        fingerprint = Self.launchFingerprint(settings)
        isWarm = false
        residentMegabytes = 0

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = Self.launchArguments(settings, port: port)
        proc.currentDirectoryURL = URL(fileURLWithPath: settings.rootPath)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        // У stdout и stderr свой накопитель строк: обработчики читателей работают
        // в разных очередях, а общий буфер оборачивался бы гонкой и терял строки.
        let outLines = LineCollector { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }
        let errLines = LineCollector { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { outLines.feed($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { errLines.feed($0.availableData) }

        do {
            try proc.run()
        } catch {
            state = .failed(error.localizedDescription)
            append("! Не удалось запустить sd-server: \(error.localizedDescription)")
            return
        }

        process = proc
        self.outPipe = outPipe
        self.errPipe = errPipe
        EngineRegistry.shared.register(self)
        append("— sd-server запущен, порт \(port), PID \(proc.processIdentifier) —")

        // Модели описываются при старте, порт открывается после этого — ждать
        // приходится несколько минут, поэтому проверка идёт отдельной задачей.
        monitorExit(proc)
    }

    func stop() {
        guard let proc = process else {
            state = .stopped
            return
        }
        if proc.isRunning {
            proc.terminate()
            // Ждём реального выхода: иначе процесс успеет остаться в памяти
            // после закрытия приложения и следующий запуск поднимет второй.
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        process = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        errPipe = nil
        state = .stopped
        isWarm = false
        residentMegabytes = 0
        append("— sd-server остановлен, веса выгружены —")
    }

    /// Перезапуск, если изменился набор моделей или режим вычислений.
    func restartIfNeeded(_ settings: GenerationSettings) {
        guard process != nil else {
            start(settings)
            return
        }
        guard Self.launchFingerprint(settings) != fingerprint else { return }
        append("— параметры движка изменились, перезапуск sd-server —")
        stop()
        start(settings)
    }

    /// Доводит движок до готового состояния: поднимает процесс, если его нет,
    /// и перезапускает, если изменились модель или режим вычислений.
    func ensureReady(_ settings: GenerationSettings) async throws {
        try Task.checkCancellation()
        if process == nil {
            append("— запуск sd-server, чтение 14.6 ГБ весов —")
            start(settings)
        } else if Self.launchFingerprint(settings) != fingerprint {
            append("— параметры движка изменились, перезапуск sd-server —")
            stop()
            start(settings)
        }
        try await waitUntilReady()
    }

    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process != nil else { throw EngineError.badResponse("sd-server не запущен") }
            if let code = await healthCode(), code == 200 {
                state = .ready
                append("— sd-server готов —")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state = .failed("Сервер не ответил за 15 минут")
        append("! sd-server не ответил за 15 минут")
        throw EngineError.notReady("сервер не ответил за 15 минут")
    }

    private func healthCode() async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("sdcpp/v1/capabilities"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return http.statusCode
    }

    private func monitorExit(_ proc: Process) {
        Thread.detachNewThread { [weak self] in
            proc.waitUntilExit()
            Task { @MainActor in
                guard let self else { return }
                let code = proc.terminationStatus
                self.outPipe?.fileHandleForReading.readabilityHandler = nil
                self.errPipe?.fileHandleForReading.readabilityHandler = nil
                self.outPipe = nil
                self.errPipe = nil
                self.process = nil
                self.isWarm = false
                self.activeJobId = nil
                if self.state != .stopped {
                    self.state = .failed("sd-server завершился с кодом \(code)")
                }
                self.append("— sd-server завершился, код \(code) —")
            }
        }
    }

    /// Размер резидентной памяти процесса — по нему видно, что веса реально
    /// остались в памяти, а не выгрузились после генерации.
    private func sampleResidentMemory() {
        guard Date().timeIntervalSince(lastResidentSample) > 5 else { return }
        guard let pid = process?.processIdentifier else { return }
        lastResidentSample = Date()

        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-o", "rss=", "-p", String(pid)]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let kilobytes = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        residentMegabytes = kilobytes / 1024
    }

    // MARK: Генерация

    /// Отправляет задачу и ждёт результат. Картинки приходят готовыми PNG
    /// внутри ответа — сервер файлы не пишет, сохраняет приложение.
    func generate(_ settings: GenerationSettings, progress: @escaping @MainActor (String) -> Void) async throws -> [GeneratedImage] {
        guard state == .ready else {
            throw EngineError.notReady(state.title)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("sdcpp/v1/img_gen"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.requestBody(settings))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EngineError.badResponse("Ответ без HTTP-кода")
        }
        guard http.statusCode == 202 || http.statusCode == 200 else {
            throw EngineError.badResponse(Self.describe(http: http, data: data))
        }

        let job = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let jobId = job?["id"] as? String else {
            throw EngineError.badResponse("В ответе нет id задачи")
        }
        activeJobId = jobId
        append("— задача \(jobId) принята —")

        return try await waitForJob(jobId, progress: progress)
    }

    private func waitForJob(_ jobId: String, progress: @escaping @MainActor (String) -> Void) async throws -> [GeneratedImage] {
        let pollURL = baseURL.appendingPathComponent("sdcpp/v1/jobs/\(jobId)")
        let deadline = Date().addingTimeInterval(6 * 60 * 60)

        while Date() < deadline {
            if Task.isCancelled {
                await cancel(jobId: jobId)
                throw CancellationError()
            }
            var request = URLRequest(url: pollURL)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw EngineError.badResponse("Опрос задачи вернул \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EngineError.badResponse("Ответ опроса не разобран")
            }
            sampleResidentMemory()

            switch payload["status"] as? String {
            case "completed":
                activeJobId = nil
                isWarm = true
                return try Self.extractImages(payload)

            case "failed", "cancelled":
                activeJobId = nil
                throw EngineError.jobFailed(Self.describeError(payload))

            default:
                let position = payload["queue_position"] as? Int ?? 0
                if position > 0 {
                    progress("задача в очереди, позиция \(position)")
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        activeJobId = nil
        throw EngineError.jobFailed("Таймаут ожидания задачи")
    }

    func cancel(jobId: String? = nil) async {
        guard let id = jobId ?? activeJobId else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("sdcpp/v1/jobs/\(id)/cancel"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: request)
        activeJobId = nil
        append("— отмена задачи \(id) —")
    }

    private static func extractImages(_ payload: [String: Any]) throws -> [GeneratedImage] {
        guard let result = payload["result"] as? [String: Any],
              let list = result["images"] as? [[String: Any]] else {
            throw EngineError.badResponse("В результате нет картинок")
        }
        var out: [GeneratedImage] = []
        for item in list {
            guard let encoded = item["b64_json"] as? String,
                  let data = Data(base64Encoded: encoded) else { continue }
            out.append(GeneratedImage(data: data, index: item["index"] as? Int ?? out.count))
        }
        guard !out.isEmpty else {
            throw EngineError.badResponse("Картинки не декодировались")
        }
        return out.sorted { $0.index < $1.index }
    }

    private static func describeError(_ payload: [String: Any]) -> String {
        guard let error = payload["error"] as? [String: Any] else { return "задача завершилась ошибкой" }
        for key in ["message", "what", "error", "detail"] {
            if let text = error[key] as? String, !text.isEmpty { return text }
        }
        return error.description
    }

    private static func describe(http: HTTPURLResponse, data: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = payload["error"] as? [String: Any],
           let text = error["message"] as? String {
            return "HTTP \(http.statusCode): \(text)"
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return "HTTP \(http.statusCode): \(body.prefix(200))"
    }

    // MARK: Тело запроса

    static func requestBody(_ s: GenerationSettings) -> [String: Any] {
        let size = s.resolvedSize
        let body: [String: Any] = [
            "prompt": s.prompt,
            "negative_prompt": s.negativePrompt,
            "width": size.width,
            "height": size.height,
            "seed": s.randomSeed ? -1 : s.seed,
            "batch_count": max(1, s.batchCount),
            "sample_params": [
                "scheduler": "discrete",
                "sample_method": s.sampler.rawValue,
                "sample_steps": max(1, s.steps),
                "flow_shift": s.flowShift,
                "guidance": [
                    "txt_cfg": s.cfgScale,
                    "img_cfg": 1.0,
                ],
            ],
            "vae_tiling_params": [
                "enabled": s.vaeTiling,
                "target_overlap": 0.5,
            ],
            "output_format": "png",
        ]
        return body
    }

    private static func launchArguments(_ s: GenerationSettings, port: Int) -> [String] {
        var args = [
            "--diffusion-model", "models/\(s.diffusionModel)",
            "--llm", "models/\(s.encoderModel)",
            "--vae", "models/\(s.vaeModel)",
            "--listen-ip", "127.0.0.1",
            "--listen-port", String(port),
            "--log-level", "verbose",
        ]
        if s.backend == .cpu {
            args += ["--backend", "cpu", "--auto-fit", "off"]
        } else {
            args += ["--auto-fit", "on"]
        }
        if s.threads > 0 { args += ["-t", String(s.threads)] }
        if s.maxVRAM > 0 { args += ["--max-vram", String(format: "%.1f", s.maxVRAM)] }
        if s.diffusionFA { args += ["--diffusion-fa"] }
        if s.offloadToCPU { args += ["--offload-to-cpu"] }
        if s.disableSegmentedCompute { args += ["--disable-segmented-compute"] }
        if s.eagerLoad { args += ["--eager-load"] }
        return args
    }

    // MARK: Вывод процесса

    private func consume(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !isWarm, line.contains("loading tensors completed") {
            isWarm = true
            sampleResidentMemory()
            append("— веса модели в памяти, повторные генерации их не перечитывают —")
        }
        onLine?(line)
    }

    private func append(_ line: String) {
        onLine?(line)
    }

    /// Свободный порт: поднимаем слушающий сокет на порту 0, спрашиваем у
    /// системы выданный порт и закрываем сокет. Гонка с другим процессом
    /// возможна, но на локальной машине её не бывает.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 18_234 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 18_234 }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return 18_234 }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}

enum EngineError: LocalizedError {
    case notReady(String)
    case badResponse(String)
    case jobFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady(let s): return "Движок не готов: \(s)"
        case .badResponse(let s): return "Некорректный ответ sd-server: \(s)"
        case .jobFailed(let s): return "Задача провалилась: \(s)"
        }
    }
}