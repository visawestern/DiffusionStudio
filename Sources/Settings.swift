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

enum AspectPreset: String, CaseIterable, Identifiable, Codable {
    case square = "1:1"
    case landscape43 = "4:3"
    case portrait34 = "3:4"
    case landscape169 = "16:9"
    case portrait916 = "9:16"

    var id: String { rawValue }

    /// Размеры, на которых модель обучалась. Только эти: промежуточный размер
    /// модель рисует криво — пропорции плывут, а мелкие детали рассыпаются.
    /// Всё остальное проще доделать в редакторе, чем ждать искажённый результат.
    var size: (width: Int, height: Int) {
        switch self {
        case .square: return (1024, 1024)
        case .landscape43: return (1024, 768)
        case .portrait34: return (768, 1024)
        case .landscape169: return (1344, 768)
        case .portrait916: return (768, 1344)
        }
    }

    var label: String {
        let s = size
        return "\(rawValue) · \(s.width)×\(s.height)"
    }
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
        s.applyAspect()
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
    var rootPath: String = AppConstants.defaultRoot
    var modelSet: ModelSet = .qwenImage21Q6

    var diffusionModel: String = ModelSet.qwenImage21Q6.diffusion
    var encoderModel: String = ModelSet.qwenImage21Q6.encoder
    var vaeModel: String = ModelSet.qwenImage21Q6.vae

    var prompt: String = ""
    var negativePrompt: String = Defaults.negative

    var aspect: AspectPreset = .portrait34
    var width: Int = 768
    var height: Int = 1024

    var steps: Int = 20
    var cfgScale: Double = 4.0
    var flowShift: Double = 3.0
    var sampler: Sampler = .euler
    var seed: Int = 42
    var randomSeed: Bool = false
    var batchCount: Int = 1

    var threads: Int = 8
    var backend: BackendChoice = .cpu
    var maxVRAM: Double = 0

    var diffusionFA: Bool = true
    var vaeTiling: Bool = true
    var offloadToCPU: Bool = false
    var disableSegmentedCompute: Bool = false
    var eagerLoad: Bool = false

    var outputDirectory: String = ""
    var outputName: String = "output"
    var verbose: Bool = true

    var resolvedOutputDirectory: String {
        outputDirectory.isEmpty
            ? URL(fileURLWithPath: rootPath).appendingPathComponent("outputs").path
            : outputDirectory
    }

    var resolvedSize: (width: Int, height: Int) { aspect.size }

    /// Размер всегда берётся из пресета пропорций: произвольных значений нет.
    mutating func applyAspect() {
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