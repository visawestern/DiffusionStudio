import Foundation

enum AppConstants {
    /// Папка stable-diffusion.cpp, если она не задана явно.
    ///
    /// Порядок: переменная окружения `DIFFUSION_STUDIO_ROOT`, затем несколько
    /// типовых мест установки, иначе пустая строка — тогда пользователь должен
    /// выбрать папку кнопкой в интерфейсе. Выбранный путь сохраняется в
    /// UserDefaults, поэтому достаточно указать его один раз.
    static let defaultRoot: String = resolveRoot()

    private static func resolveRoot() -> String {
        if let env = ProcessInfo.processInfo.environment["DIFFUSION_STUDIO_ROOT"],
           !env.trimmingCharacters(in: .whitespaces).isEmpty {
            return env
        }
        let home = NSHomeDirectory()
        let candidates = [
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
            ?? ""
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

enum PreviewChoice: String, CaseIterable, Identifiable, Codable {
    case none = "Выкл"
    case proj = "proj"
    case tae = "tae"
    case vae = "vae"

    var id: String { rawValue }
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
    case portrait34 = "3:4"
    case landscape43 = "4:3"
    case portrait916 = "9:16"
    case landscape169 = "16:9"
    case a4 = "A4"

    var id: String { rawValue }

    var ratio: Double {
        switch self {
        case .square: return 1.0
        case .portrait34: return 3.0 / 4.0
        case .landscape43: return 4.0 / 3.0
        case .portrait916: return 9.0 / 16.0
        case .landscape169: return 16.0 / 9.0
        case .a4: return 1.0 / 1.4142
        }
    }

    var label: String {
        switch self {
        case .a4: return "A4"
        default: return rawValue
        }
    }

    func size(for longEdge: Int) -> (Int, Int) {
        let raw: (Int, Int)
        if self == .a4 {
            raw = (longEdge, Int((Double(longEdge) * 1.4142).rounded()))
        } else if ratio >= 1.0 {
            raw = (longEdge, Int((Double(longEdge) / ratio).rounded()))
        } else {
            raw = (Int((Double(longEdge) * ratio).rounded()), longEdge)
        }
        return (snap(raw.0), snap(raw.1))
    }

    private func snap(_ v: Int) -> Int { max(64, ((v / 64) * 64)) }
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

struct GenerationSettings: Codable, Equatable {
    var rootPath: String = AppConstants.defaultRoot
    var modelSet: ModelSet = .qwenImage21Q6

    var diffusionModel: String = ModelSet.qwenImage21Q6.diffusion
    var encoderModel: String = ModelSet.qwenImage21Q6.encoder
    var vaeModel: String = ModelSet.qwenImage21Q6.vae

    var prompt: String = ""
    var negativePrompt: String = Defaults.negative

    var aspect: AspectPreset = .portrait34
    var longEdge: Int = 1024
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

    var preview: PreviewChoice = .proj
    var previewInterval: Int = 1
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

    var resolvedSize: (width: Int, height: Int) {
        let s = aspect.size(for: longEdge)
        return (s.0, s.1)
    }

    var outputURL: URL {
        URL(fileURLWithPath: resolvedOutputDirectory)
            .appendingPathComponent(outputName.hasSuffix(".png") ? outputName : outputName + ".png")
    }

    var previewURL: URL {
        URL(fileURLWithPath: resolvedOutputDirectory).appendingPathComponent("preview.png")
    }

    var binaryURL: URL {
        URL(fileURLWithPath: rootPath).appendingPathComponent("build/bin/sd-cli")
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
            out.append("Не найден исполняемый файл: \(binaryURL.path)")
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
        let px = Double(width * height)
        let ratio = px / (768.0 * 1024.0)
        let perStep = 1085.0 * ratio
        let sampling = perStep * Double(steps)
        let encoding = promptEncodingSeconds
        let decoding = 637.0 * ratio
        return (perStep, sampling, encoding + decoding + sampling)
    }

    private var promptEncodingSeconds: Double {
        let length = Double((prompt as NSString).length)
        return length > 300 ? 496.0 : 130.0
    }

    var estimatedCostText: String {
        let e = estimatedCost
        return String(
            format: "≈ %@ суммарно · сэмплирование ≈ %@ (%@/шаг) · кодирование промпта ≈ %@ · декод ≈ %@",
            Self.human(e.total),
            Self.human(e.sampling),
            Self.human(e.perStep),
            Self.human(promptEncodingSeconds),
            Self.human(637.0 * (Double(width * height) / (768.0 * 1024.0)))
        )
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

    func buildArguments() -> [String] {
        var a: [String] = []
        let resolved = resolvedSize

        a += ["--diffusion-model", "models/\(diffusionModel)"]
        a += ["--llm", "models/\(encoderModel)"]
        a += ["--vae", "models/\(vaeModel)"]

        a += ["-p", prompt]
        if !negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            a += ["-n", negativePrompt]
        }

        a += ["-W", String(resolved.width)]
        a += ["-H", String(resolved.height)]
        a += ["--steps", String(steps)]
        a += ["--cfg-scale", String(format: "%.2f", cfgScale)]
        a += ["--flow-shift", String(format: "%.2f", flowShift)]
        a += ["--sampling-method", sampler.rawValue]
        a += ["-s", String(randomSeed ? -1 : seed)]
        if batchCount > 1 { a += ["-b", String(batchCount)] }
        if threads > 0 { a += ["-t", String(threads)] }

        switch backend {
        case .cpu: a += ["--backend", "cpu"]
        case .auto: a += ["--auto-fit"]
        }
        if maxVRAM > 0 { a += ["--max-vram", String(format: "mtl0=%.1f", maxVRAM)] }

        if preview != .none {
            a += ["--preview", preview.rawValue]
            a += ["--preview-interval", String(max(1, previewInterval))]
            a += ["--preview-path", previewURL.path]
        }

        if diffusionFA { a += ["--diffusion-fa"] }
        if vaeTiling { a += ["--vae-tiling"] }
        if offloadToCPU { a += ["--offload-to-cpu"] }
        if disableSegmentedCompute { a += ["--disable-segmented-compute"] }
        if eagerLoad { a += ["--eager-load"] }

        a += ["-o", outputURL.path]
        if verbose { a += ["-v"] }
        return a
    }

    func estimatedMemoryText() -> String {
        if backend == .cpu {
            return "RAM: нужно ~22 ГБ свободных при 32 ГБ всего. Закрой браузер и мессенджеры — иначе уйдёт в своп и станет в разы медленнее."
        }
        return "VRAM: 8 ГБ всего, десктоп съедает почти всё. Режим GPU падал дважды."
    }
}