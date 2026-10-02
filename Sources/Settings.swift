import AppKit
import Foundation

enum AppConstants {
    /// Папка stable-diffusion.cpp. В интерфейсе она не меняется: движок лежит
    /// в фиксированном месте, и трогать его не нужно.
    ///
    /// Порядок поиска: переменная окружения `DIFFUSION_STUDIO_ROOT`, затем
    /// локальная сборка, затем типовые места установки.
    static let defaultRoot: String = resolveRoot()

    /// Локальная сборка движка. Если stable-diffusion.cpp переехал, проще
    /// задать DIFFUSION_STUDIO_ROOT, чем добавлять новый путь сюда.
    static let localBuild = "/var/folders/cn/mx7g770j6j17g7kvkb6wlfhw0000gp/T/opencode/stable-diffusion.cpp"

    private static func resolveRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["DIFFUSION_STUDIO_ROOT"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        let home = NSHomeDirectory()
        let candidates = [
            localBuild,
            home + "/stable-diffusion.cpp",
            home + "/Developer/stable-diffusion.cpp",
            home + "/src/stable-diffusion.cpp",
            home + "/Documents/stable-diffusion.cpp",
            home + "/Downloads/stable-diffusion.cpp",
            "/Applications/stable-diffusion.cpp",
            "/opt/homebrew/Cellar/stable-diffusion.cpp",
            "/usr/local/stable-diffusion.cpp",
        ]
        let fm = FileManager.default
        return candidates.first { fm.fileExists(atPath: $0 + "/build/bin/sd-cli") }
            ?? candidates.first { fm.fileExists(atPath: $0) }
            ?? localBuild
    }

    /// Имя бинарника `sd-cli` относительно корня движка.
    static func executablePath(root: String) -> String {
        root + "/build/bin/sd-cli"
    }
}

enum BackendChoice: String, CaseIterable, Identifiable, Codable {
    case cpu = "CPU — рекомендуется"
    case auto = "Auto-fit (GPU)"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .cpu: "Единственный рабочий вариант на этом Mac. Метал не вмещает модель."
        case .auto: "Только если в VRAM реально свободно больше 7 ГБ."
        }
    }
}

enum ModelSet: String, CaseIterable, Identifiable, Codable {
    case qwenImage21Q6 = "Qwen-Image 2.1 Q6_K"
    case custom = "Ручной выбор"

    var id: String { rawValue }

    var diffusion: String { "qwen-image-2.1-UC-Q6_K.gguf" }
    var encoder: String { "qwen3vl_8b_int8_convrot.safetensors" }
    var vae: String { "qwen_image_2.1_vae_bf16.safetensors" }

    var expectedDiffusionBytes: Int64 { 5_876_556_576 }
    var expectedEncoderBytes: Int64 { 9_350_798_360 }
    var expectedVAEBytes: Int64 { 675_509_688 }

    var memoryNote: String { "веса 14.6 ГБ, энкодер требует ~8 ГБ ОЗУ" }
}

enum ResolutionScale: String, CaseIterable, Identifiable, Codable {
    case mini = "Мини"
    case half = "50%"
    case threeQuarters = "75%"
    case full = "100%"

    var id: String { rawValue }

    func size(for base: (width: Int, height: Int)) -> (width: Int, height: Int) {
        // «Мини» всегда доводит короткую сторону до 192 px. Для прямоугольных
        // пропорций это ровно четверть базового кадра; квадрат тоже остаётся
        // квадратом 192×192. Остальные варианты масштабируют обе стороны
        // одинаковым множителем и сохраняют пропорцию точно.
        if self == .mini {
            guard base.width != base.height else { return (192, 192) }
            let shortSide = 192.0
            if base.width > base.height {
                return (Int((Double(base.width) * shortSide / Double(base.height)).rounded()), 192)
            }
            return (192, Int((Double(base.height) * shortSide / Double(base.width)).rounded()))
        }

        let factor: Double = switch self {
        case .half: 0.5
        case .threeQuarters: 0.75
        case .full, .mini: 1.0
        }
        return (
            Int((Double(base.width) * factor).rounded()),
            Int((Double(base.height) * factor).rounded())
        )
    }

    func label(for base: (width: Int, height: Int)) -> String {
        let scaled = size(for: base)
        return "\(rawValue) · \(scaled.width)×\(scaled.height)"
    }
}

enum AspectPreset: String, CaseIterable, Identifiable, Codable {
    case square = "1:1"
    case landscape43 = "4:3"
    case portrait34 = "3:4"
    case landscape169 = "16:9"
    case portrait916 = "9:16"

    var id: String { rawValue }

    /// Базовые пропорции и полные размеры, от которых строятся все варианты.
    /// Масштаб уменьшает обе стороны одинаково, поэтому пропорция сохраняется,
    /// а картинка становится меньше и считается быстрее.
    var size: (width: Int, height: Int) {
        switch self {
        case .square: return (1024, 1024)
        case .landscape43: return (1024, 768)
        case .portrait34: return (768, 1024)
        case .landscape169: return (1344, 768)
        case .portrait916: return (768, 1344)
        }
    }

    var label: String { rawValue }
}

enum Sampler: String, CaseIterable, Identifiable, Codable {
    case euler, euler_a, heun, dpm2, dpmPP2sA = "dpm++2s_a", dpmPP2m = "dpm++2m"
    case dpmPP2mv2 = "dpm++2mv2", ipndm, lcm, ddimTrailing = "ddim_trailing", tcd
    case resMultistep = "res_multistep", res2s = "res_2s", erSde = "er_sde"
    case eulerCfgPP = "euler_cfg_pp", eulerACfgPP = "euler_a_cfg_pp", lms

    var id: String { rawValue }
}

enum Defaults {
    static let negative = """
blurry, lowres, low quality, worst quality, normal quality, jpeg artifacts, \
compression artifacts, noise, film grain, banding, over-smoothed, plastic skin, \
waxy skin, airbrushed, doll-like, overexposed, blown highlights, crushed blacks, \
oversaturated, oversharpened, chromatic aberration, color fringing, halos, \
watermark, signature, caption, text, logo, letters, stamp, banner, frame, border, \
cropped, out of frame, duplicate, tiled, repeating pattern, deformed hands, \
extra fingers, fused fingers, mutated anatomy, disfigured, poorly drawn face, \
bad proportions, extra limbs, missing limbs, floating limbs, asymmetric eyes, \
cartoony, anime, 3d render, cgi, painting, sketch, illustration, artificial skin texture
"""
}

enum FolderPicker {
    static func pick(title: String, start: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = title
        if FileManager.default.fileExists(atPath: start) {
            panel.directoryURL = URL(fileURLWithPath: start)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var s: GenerationSettings

    private let key = "DiffusionStudio.settings.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode(GenerationSettings.self, from: data) {
            s = decoded
        } else {
            s = GenerationSettings()
        }
        normalize()
        migrateIfNeeded()
    }

    private func migrateIfNeeded() {
        if s.outputDirectory.isEmpty {
            s.outputDirectory = URL(fileURLWithPath: s.rootPath).appendingPathComponent("outputs").path
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func normalize() {
        s.applyModelSet()
        s.applySize()
        if s.outputDirectory.isEmpty {
            s.outputDirectory = URL(fileURLWithPath: s.rootPath).appendingPathComponent("outputs").path
        }
        if s.threads <= 0 { s.threads = ProcessInfo.processInfo.activeProcessorCount / 2 }
    }

    func resetToDefaults() {
        let keepDir = s.outputDirectory
        s = GenerationSettings()
        s.outputDirectory = keepDir
        normalize()
        persist()
    }

    func chooseOutputDirectory() {
        if let url = FolderPicker.pick(title: "Куда сохранять картинки", start: s.resolvedOutputDirectory) {
            s.outputDirectory = url.path
        }
    }

    func ensureOutputDirectory() {
        let url = URL(fileURLWithPath: s.resolvedOutputDirectory)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct GenerationSettings: Codable, Equatable {
    init() {
        rootPath = AppConstants.defaultRoot
        modelSet = .qwenImage21Q6
        diffusionModel = ModelSet.qwenImage21Q6.diffusion
        encoderModel = ModelSet.qwenImage21Q6.encoder
        vaeModel = ModelSet.qwenImage21Q6.vae
        prompt = ""
        negativePrompt = Defaults.negative
        aspect = .portrait34
        scale = .full
        width = 768
        height = 1024
        steps = 20
        cfgScale = 4.0
        flowShift = 3.0
        sampler = .euler
        seed = 42
        randomSeed = false
        batchCount = 1
        threads = 8
        backend = .cpu
        maxVRAM = 0
        diffusionFA = true
        vaeTiling = true
        offloadToCPU = false
        disableSegmentedCompute = false
        eagerLoad = false
        outputDirectory = ""
        outputName = "output"
        verbose = true
    }

    /// Старые сохранённые настройки могут не содержать полей, добавленных
    /// позже. Поэтому отсутствующие значения заменяются текущими значениями
    /// по умолчанию, а не роняют весь файл настроек.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()

        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath) ?? defaults.rootPath
        modelSet = try container.decodeIfPresent(ModelSet.self, forKey: .modelSet) ?? defaults.modelSet
        diffusionModel = try container.decodeIfPresent(String.self, forKey: .diffusionModel) ?? defaults.diffusionModel
        encoderModel = try container.decodeIfPresent(String.self, forKey: .encoderModel) ?? defaults.encoderModel
        vaeModel = try container.decodeIfPresent(String.self, forKey: .vaeModel) ?? defaults.vaeModel
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? defaults.prompt
        negativePrompt = try container.decodeIfPresent(String.self, forKey: .negativePrompt) ?? defaults.negativePrompt
        aspect = try container.decodeIfPresent(AspectPreset.self, forKey: .aspect) ?? defaults.aspect
        scale = try container.decodeIfPresent(ResolutionScale.self, forKey: .scale) ?? defaults.scale
        width = try container.decodeIfPresent(Int.self, forKey: .width) ?? defaults.width
        height = try container.decodeIfPresent(Int.self, forKey: .height) ?? defaults.height
        steps = try container.decodeIfPresent(Int.self, forKey: .steps) ?? defaults.steps
        cfgScale = try container.decodeIfPresent(Double.self, forKey: .cfgScale) ?? defaults.cfgScale
        flowShift = try container.decodeIfPresent(Double.self, forKey: .flowShift) ?? defaults.flowShift
        sampler = try container.decodeIfPresent(Sampler.self, forKey: .sampler) ?? defaults.sampler
        seed = try container.decodeIfPresent(Int.self, forKey: .seed) ?? defaults.seed
        randomSeed = try container.decodeIfPresent(Bool.self, forKey: .randomSeed) ?? defaults.randomSeed
        batchCount = try container.decodeIfPresent(Int.self, forKey: .batchCount) ?? defaults.batchCount
        threads = try container.decodeIfPresent(Int.self, forKey: .threads) ?? defaults.threads
        backend = try container.decodeIfPresent(BackendChoice.self, forKey: .backend) ?? defaults.backend
        maxVRAM = try container.decodeIfPresent(Double.self, forKey: .maxVRAM) ?? defaults.maxVRAM
        diffusionFA = try container.decodeIfPresent(Bool.self, forKey: .diffusionFA) ?? defaults.diffusionFA
        vaeTiling = try container.decodeIfPresent(Bool.self, forKey: .vaeTiling) ?? defaults.vaeTiling
        offloadToCPU = try container.decodeIfPresent(Bool.self, forKey: .offloadToCPU) ?? defaults.offloadToCPU
        disableSegmentedCompute = try container.decodeIfPresent(Bool.self, forKey: .disableSegmentedCompute) ?? defaults.disableSegmentedCompute
        eagerLoad = try container.decodeIfPresent(Bool.self, forKey: .eagerLoad) ?? defaults.eagerLoad
        outputDirectory = try container.decodeIfPresent(String.self, forKey: .outputDirectory) ?? defaults.outputDirectory
        outputName = try container.decodeIfPresent(String.self, forKey: .outputName) ?? defaults.outputName
        verbose = try container.decodeIfPresent(Bool.self, forKey: .verbose) ?? defaults.verbose
    }

    var rootPath: String
    var modelSet: ModelSet

    var diffusionModel: String
    var encoderModel: String
    var vaeModel: String

    var prompt: String
    var negativePrompt: String

    var aspect: AspectPreset
    var scale: ResolutionScale
    var width: Int
    var height: Int

    var steps: Int
    var cfgScale: Double
    var flowShift: Double
    var sampler: Sampler
    var seed: Int
    var randomSeed: Bool
    var batchCount: Int

    var threads: Int
    var backend: BackendChoice
    var maxVRAM: Double

    var diffusionFA: Bool
    var vaeTiling: Bool
    var offloadToCPU: Bool
    var disableSegmentedCompute: Bool
    var eagerLoad: Bool

    var outputDirectory: String
    var outputName: String
    var verbose: Bool

    var resolvedOutputDirectory: String {
        outputDirectory.isEmpty
            ? URL(fileURLWithPath: rootPath).appendingPathComponent("outputs").path
            : outputDirectory
    }

    var resolvedSize: (width: Int, height: Int) { scale.size(for: aspect.size) }

    /// Размер всегда собирается из пропорции и масштаба: произвольных значений нет.
    mutating func applySize() {
        let r = resolvedSize
        width = r.width
        height = r.height
    }

    var outputURL: URL {
        URL(fileURLWithPath: resolvedOutputDirectory)
            .appendingPathComponent(outputName.hasSuffix(".png") ? outputName : outputName + ".png")
    }

    /// Бинарь движка. Генерацию выполняет `sd-server`: он держит веса в памяти
    /// между запусками, поэтому вторая картинка не читает модель заново.
    var binaryURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent("build/bin/sd-server")
    }

    mutating func applyModelSet() {
        guard modelSet != .custom else { return }
        diffusionModel = modelSet.diffusion
        encoderModel = modelSet.encoder
        vaeModel = modelSet.vae
    }

    var problems: [String] {
        var out: [String] = []
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Промпт пустой.")
        }
        if !FileManager.default.isExecutableFile(atPath: binaryURL.path) {
            out.append("Нет бинаря sd-server: \(binaryURL.path). Соберите его: cmake --build build --target sd-server")
        }
        for (label, name) in [("диффузии", diffusionModel), ("энкодера", encoderModel), ("VAE", vaeModel)] {
            if name.isEmpty {
                out.append("Файл модели \(label) не выбран.")
                continue
            }
            let url = URL(fileURLWithPath: rootPath).appendingPathComponent("models").appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                out.append("Файл модели \(label) не найден: models/\(name)")
            } else if modelSet != .custom {
                let expected = modelSet == .qwenImage21Q6
                    ? (name == modelSet.diffusion ? modelSet.expectedDiffusionBytes
                        : name == modelSet.encoder ? modelSet.expectedEncoderBytes
                        : modelSet.expectedVAEBytes)
                    : nil
                if let expected, expected > 0 {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let actual = (attrs?[.size] as? Int64) ?? 0
                    if abs(actual - expected) > 1024 {
                        out.append("Файл модели \(label) недокачан: \(ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)) вместо \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))")
                    }
                }
            }
        }
        if backend == .auto {
            out.append("Auto-fit на этой машине падал: в VRAM свободно ~700 МБ из 8176. Если упадёт — переключи на CPU.")
        }
        if maxVRAM > 0 && maxVRAM > 8 {
            out.append("VRAM у Radeon Pro 5500M всего 8 ГБ, бюджет больше 7 задавать бессмысленно.")
        }
        if steps < 1 { out.append("Шагов должно быть хотя бы 1.") }
        if width < 64 || height < 64 { out.append("Размер меньше 64 пикселей бессмысленен.") }

        let dir = URL(fileURLWithPath: resolvedOutputDirectory)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            if !fm.isWritableFile(atPath: dir.path) {
                out.append("В папку нельзя записывать: \(dir.path)")
            }
        } else {
            var deepest = dir
            while !fm.fileExists(atPath: deepest.path), deepest.path != "/" {
                deepest = deepest.deletingLastPathComponent()
            }
            if !fm.isWritableFile(atPath: deepest.path) {
                out.append("Не удастся создать \(dir.path): нет прав на папку \(deepest.path). Выбери другую папку.")
            }
        }
        return out
    }

    var estimatedCost: (perStep: Double, sampling: Double, total: Double) {
        let budget = StageBudget.projected(settings: self)
        let perStep = budget.sampling / Double(max(1, steps * batchCount))
        return (perStep, budget.sampling, budget.total)
    }

    var estimatedCostText: String {
        let b = StageBudget.projected(settings: self)
        return String(
            format: "всего ≈ %@ · сэмплирование ≈ %@ (%@/шаг) · загрузка ≈ %@ · кодирование ≈ %@ · декод ≈ %@ · запись ≈ %@",
            GenerationSettings.human(b.total),
            GenerationSettings.human(b.sampling),
            GenerationSettings.human(b.sampling / Double(max(1, steps * batchCount))),
            GenerationSettings.human(b.loading),
            GenerationSettings.human(b.encoding),
            GenerationSettings.human(b.decoding),
            GenerationSettings.human(b.saving)
        )
    }

    /// Доли стадий в общем времени — те же коэффициенты, что использует
    /// прогрессбар, чтобы оценка и полоса считались по одной модели.
    var stageWeights: [(stage: RunStage, weight: Double, seconds: Double)] {
        let b = StageBudget.projected(settings: self)
        return RunStage.pipeline.map { ($0, b.weight(of: $0), b.seconds(for: $0)) }
    }

    /// Множественное число для «шаг / шага / шагов».
    static func stepsWord(_ n: Int) -> String {
        let m100 = n % 100
        let m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "шагов" }
        if m10 == 1 { return "шаг" }
        if m10 >= 2 && m10 <= 4 { return "шага" }
        return "шагов"
    }

    static func human(_ seconds: Double) -> String {
        if seconds < 60 { return String(format: "%.0f с", seconds) }
        if seconds < 3600 { return String(format: "%.0f мин", seconds / 60) }
        return String(format: "%.1f ч", seconds / 3600)
    }

    func estimatedMemoryText() -> String {
        if backend == .cpu {
            return "RAM: нужно ~22 ГБ свободных при 32 ГБ всего. Закрой браузер и мессенджеры — иначе уйдёт в своп и станет в разы медленнее."
        }
        return "VRAM: 8 ГБ всего, десктоп съедает почти всё. Режим GPU падал дважды."
    }
}