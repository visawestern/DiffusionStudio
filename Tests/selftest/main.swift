import AppKit
import Foundation

var failures = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        print("  ok   \(name)")
    } else {
        print("  FAIL \(name) \(detail)")
        failures += 1
    }
}

print("=== 1. Тело запроса к sd-server ===")

var s = GenerationSettings()
s.rootPath = "/tmp/root"
s.prompt = "test prompt"
s.negativePrompt = ""
s.aspect = .square
s.steps = 8
s.cfgScale = 2.5
s.flowShift = 3.0
s.sampler = .euler
s.randomSeed = false
s.seed = 42
s.batchCount = 1
s.threads = 8
s.backend = .cpu
s.maxVRAM = 0
s.diffusionFA = false
s.vaeTiling = false
s.outputName = "argcheck"
s.verbose = false

let body = try EngineServer.requestBody(s)
let json = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
print("  " + json)

let size = s.resolvedSize
check("размер в теле запроса", (body["width"] as? Int) == size.width && (body["height"] as? Int) == size.height)
check("промпт передан", body["prompt"] as? String == "test prompt")
check("пустой negative prompt передан пустым", (body["negative_prompt"] as? String)?.isEmpty == true)
check("seed положительный", (body["seed"] as? Int) == 42)

guard let params = body["sample_params"] as? [String: Any] else {
    check("sample_params есть", false)
    exit(1)
}
check("steps передан", (params["sample_steps"] as? Int) == 8)
check("сэмплер передан", (params["sample_method"] as? String) == "euler")
check("flow shift передан", (params["flow_shift"] as? Double) == 3.0)
guard let guidance = params["guidance"] as? [String: Any] else {
    check("guidance есть", false)
    exit(1)
}
check("cfg = txt_cfg", (guidance["txt_cfg"] as? Double) == 2.5)
guard let tiling = body["vae_tiling_params"] as? [String: Any] else {
    check("vae_tiling_params есть", false)
    exit(1)
}
check("тайлинг выключен флагом", (tiling["enabled"] as? Bool) == false)
check("формат png", body["output_format"] as? String == "png")
check("в теле запроса нет лишних ключей", body.count == 9, "ключей: \(body.count)")

s.randomSeed = true
s.negativePrompt = "blurry"
s.cfgScale = 7.0
s.sampler = .dpmPP2m
s.vaeTiling = true
s.aspect = .landscape169
let body2 = try EngineServer.requestBody(s)
print("  " + (String(data: try JSONSerialization.data(withJSONObject: body2), encoding: .utf8) ?? ""))
check("random seed = -1", (body2["seed"] as? Int) == -1)
check("negative prompt передан", body2["negative_prompt"] as? String == "blurry")
check("смена сэмплера", (body2["sample_params"] as? [String: Any])?["sample_method"] as? String == "dpm++2m")
check("16:9 даёт 1344x768", (body2["width"] as? Int) == 1344 && (body2["height"] as? Int) == 768)
check("тайлинг включён флагом", ((body2["vae_tiling_params"] as? [String: Any])?["enabled"] as? Bool) == true)
check("txt2img не шлёт init_image и strength",
      body["init_image"] == nil && body["strength"] == nil && body["mask_image"] == nil)

print("=== 1b. Режимы редактирования ===")

let editDir = FileManager.default.temporaryDirectory.appendingPathComponent("ds_edittest")
try? FileManager.default.removeItem(at: editDir)
let editSetup: Bool = {
    guard (try? FileManager.default.createDirectory(at: editDir, withIntermediateDirectories: true)) != nil,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                     bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 12, bitsPerPixel: 24),
          let png = rep.representation(using: .png, properties: [:]) else { return false }
    let a = (try? png.write(to: editDir.appendingPathComponent("input.png"), options: [])) != nil
    let b = (try? png.write(to: editDir.appendingPathComponent("mask.png"), options: [])) != nil
    return a && b
}()
check("тестовые картинки созданы", editSetup)
let inputBytes = try Data(contentsOf: editDir.appendingPathComponent("input.png"))

var m = GenerationSettings()
m.prompt = "перерисуй"
m.mode = .imageToImage
m.inputImagePath = editDir.appendingPathComponent("input.png").path
m.strength = 0.6
let bodyEdit = try EngineServer.requestBody(m)
check("img2img кладёт init_image base64",
      (Data(base64Encoded: bodyEdit["init_image"] as? String ?? "") ?? Data()) == inputBytes)
check("img2img кладёт strength", (bodyEdit["strength"] as? Double) == 0.6)
check("img2img без маски не шлёт mask_image", bodyEdit["mask_image"] == nil)

m.mode = .inpaint
m.maskImagePath = editDir.appendingPathComponent("mask.png").path
let bodyMask = try EngineServer.requestBody(m)
check("inpaint добавляет mask_image", (bodyMask["mask_image"] as? String)?.isEmpty == false)

var mBad = GenerationSettings()
mBad.prompt = "x"
mBad.mode = .imageToImage
check("img2img без картинки ловится", mBad.problems.contains { $0.contains("исходная картинка") })
mBad.inputImagePath = "/нет/такого/файла.png"
check("img2img с битым путём ловится", mBad.problems.contains { $0.contains("не найдена") })
mBad.mode = .inpaint
mBad.inputImagePath = editDir.appendingPathComponent("input.png").path
check("inpaint без маски ловится", mBad.problems.contains { $0.contains("маска") })
try? FileManager.default.removeItem(at: editDir)

print("=== 1b. Отпечаток запуска движка ===")
let fpA = EngineServer.launchFingerprint(s)
var s2 = s
s2.prompt = "другой промпт"
s2.steps = 3
check("промпт не меняет отпечаток", EngineServer.launchFingerprint(s2) == fpA)
var s3 = s
s3.diffusionModel = "другая.gguf"
check("смена модели меняет отпечаток", EngineServer.launchFingerprint(s3) != fpA)
var s4 = s
s4.threads = 4
check("смена потоков меняет отпечаток", EngineServer.launchFingerprint(s4) != fpA)
var s5 = s
s5.vaeTiling = !s.vaeTiling
check("смена тайлинга меняет отпечаток", EngineServer.launchFingerprint(s5) != fpA)

print("=== 2. Размеры: только те, на которых модель обучалась ===")
let trained: [AspectPreset: (Int, Int)] = [
    .square: (1024, 1024),
    .landscape43: (1024, 768),
    .portrait34: (768, 1024),
    .landscape169: (1344, 768),
    .portrait916: (768, 1344),
]

check("набор размеров совпадает с обучающими", Set(AspectPreset.allCases) == Set(trained.keys))

for preset in AspectPreset.allCases {
    let size = preset.size
    let expected = trained[preset]!
    print(String(format: "  %@ → %d x %d", preset.rawValue, size.width, size.height))
    check("\(preset.rawValue) ровно обучающий размер",
          size.width == expected.0 && size.height == expected.1)
    check("\(preset.rawValue) кратен 64 по обеим сторонам",
          size.width % 64 == 0 && size.height % 64 == 0)
    check("\(preset.rawValue) помещается в 8 ГБ VRAM как минимум по площади",
          size.width * size.height <= 1344 * 1024)
}

// Размер приходит из пресета, а не из отдельного поля: произвольного выбора нет.
var sized = GenerationSettings()
for preset in AspectPreset.allCases {
    sized.aspect = preset
    sized.applySize()
    check("resolve(\(preset.rawValue)) даёт обучающий размер",
          sized.width == preset.size.width && sized.height == preset.size.height)
}

// Масштаб уменьшает обе стороны одинаково: пропорция сохраняется, а самый
// маленький вариант начинается с короткой стороны 192 px.
let scaledSizes: [AspectPreset: [ResolutionScale: (Int, Int)]] = [
    .square: [.mini: (192, 192), .half: (512, 512), .threeQuarters: (768, 768), .full: (1024, 1024)],
    .landscape43: [.mini: (256, 192), .half: (512, 384), .threeQuarters: (768, 576), .full: (1024, 768)],
    .portrait34: [.mini: (192, 256), .half: (384, 512), .threeQuarters: (576, 768), .full: (768, 1024)],
    .landscape169: [.mini: (336, 192), .half: (672, 384), .threeQuarters: (1008, 576), .full: (1344, 768)],
    .portrait916: [.mini: (192, 336), .half: (384, 672), .threeQuarters: (576, 1008), .full: (768, 1344)],
]

check("пять пропорций на четыре масштаба дают 20 размеров",
      AspectPreset.allCases.count * ResolutionScale.allCases.count == 20)

for preset in AspectPreset.allCases {
    let base = preset.size
    for scale in ResolutionScale.allCases {
        let actual = scale.size(for: base)
        let expected = scaledSizes[preset]![scale]!
        check("\(preset.rawValue) \(scale.rawValue) даёт точный пропорциональный размер",
              actual.width == expected.0 && actual.height == expected.1,
              "\(actual.width)x\(actual.height)")
        check("\(preset.rawValue) \(scale.rawValue) сохраняет пропорцию",
              actual.width * base.height == actual.height * base.width)
    }
    let mini = ResolutionScale.mini.size(for: base)
    check("\(preset.rawValue) в масштабе «Мини» начинается с короткой стороны 192",
          min(mini.width, mini.height) == 192)
}

var scaled = GenerationSettings()
scaled.aspect = .landscape169
scaled.scale = .mini
scaled.applySize()
check("настройки применяют выбранный масштаб", scaled.width == 336 && scaled.height == 192)
check("по умолчанию используется полный размер",
      GenerationSettings().scale == .full && GenerationSettings().resolvedSize.width == 768)

// Старые сохранённые настройки без поля масштаба должны открываться как 100%.
let legacySettings = try JSONDecoder().decode(
    GenerationSettings.self,
    from: Data(#"{"aspect":"3:4"}"#.utf8)
)
check("старые настройки получают полный масштаб по умолчанию",
      legacySettings.scale == .full && legacySettings.resolvedSize.width == 768)

print("=== 3. Валидация ===")
var bad = GenerationSettings()
bad.prompt = "   "
check("пустой промпт ловится", !bad.problems.isEmpty)
var noModels = GenerationSettings()
noModels.prompt = "x"
noModels.rootPath = "/nonexistent/path"
check("отсутствие sd-server ловится", noModels.problems.contains { $0.contains("Нет бинаря sd-server") })
var autoMode = GenerationSettings()
autoMode.prompt = "x"
autoMode.backend = .auto
check("предупреждение про auto-fit есть", autoMode.problems.contains { $0.contains("Auto-fit") })

print("=== 4. Парсер прогресса на реальных строках ===")

let realLines = [
    "  |======>                                           | 3/24 - 2448.47s/it",
    "========================================| 35/35 - 18.63s/it",
    "  |###                                               | 7/8 - 19.24s/it",
    "  |==                                                | 12/24 - 24.5s/it",
    "[INFO   ] image.cpp:899  - sampling completed, taking 26040.83s",
    "[INFO   ] image.cpp:1050 - generate_image completed in 27174.79s",
    "[INFO   ] main.cpp:497  - save result image 0 to 'outputs/diploma_scan.png' (success)",
]

final class Sink {
    var lines: [String] = []
    func feed(_ d: Data) {
        let c = LineCollector { line in self.lines.append(line) }
        c.feed(d)
    }
}

var parsed: [(Int, Int, Double)] = []
let regex = try NSRegularExpression(pattern: "(\\d+)/(\\d+)\\s*-\\s*([0-9]+(?:\\.[0-9]+)?)(s/it|it/s)")

for line in realLines {
    let r = NSRange(line.startIndex..., in: line)
    if let m = regex.firstMatch(in: line, range: r) {
        func cap(_ i: Int) -> String {
            guard let rr = Range(m.range(at: i), in: line) else { return "" }
            return String(line[rr])
        }
        let done = Double(cap(1)) ?? -1
        let total = Double(cap(2)) ?? -1
        let rate = Double(cap(3)) ?? -1
        parsed.append((Int(done), Int(total), rate))
        print("  разобрано: \(Int(done))/\(Int(total)) @ \(rate)s")
    }
}

check("нашлось 4 прогресс-строки", parsed.count == 4, "получено \(parsed.count)")
check("3/24 @ 2448.47", parsed.first.map { $0 == (3, 24, 2448.47) } ?? false)
check("35/35 @ 18.63 (VAE)", parsed.count > 1 && parsed[1] == (35, 35, 18.63))
check("лог-строки не ломают парсер", parsed.count == 4)

print("=== 5. Разбор потока по \\r и \\n ===")
var collected: [String] = []
let collector = LineCollector { collected.append($0) }
collector.feed(Data("первая\rвторая\nтретья".utf8))
print("  выдано сразу: \(collected)")
check("\\r и \\n разделяют строки", collected == ["первая", "вторая"])
check("незавершённая строка ждёт продолжения", collected.count == 2)

var tail: [String] = []
let collector2 = LineCollector { tail.append($0) }
collector2.feed(Data("начало без конца".utf8))
check("фрагмент не выдаётся преждевременно", tail.isEmpty)
collector2.feed(Data(" и продолжение\n".utf8))
print("  склейка фрагментов: \(tail)")
check("фрагменты склеиваются", tail == ["начало без конца и продолжение"])

print("=== 6. Модель бюджета стадий ===")

var big = GenerationSettings()
big.prompt = String(repeating: "document page with a table and a signature, ", count: 12)
big.aspect = .portrait34
big.steps = 24
let bigBudget = StageBudget.projected(settings: big)

let weights = RunStage.pipeline.map { bigBudget.weight(of: $0) }
let weightSum = weights.reduce(0, +)
print(String(format: "  суммарно ≈ %@", GenerationSettings.human(bigBudget.total)))
for (i, stage) in RunStage.pipeline.enumerated() {
    print(String(format: "    %@: %@ (%.2f%%)", stage.rawValue,
                 GenerationSettings.human(bigBudget.seconds(for: stage)), weights[i] * 100))
}

check("все стадии имеют положительный вес", weights.allSatisfy { $0 > 0 })
check("веса в сумме дают 100%", abs(weightSum - 1.0) < 1e-9, "\(weightSum)")
check("сэмплирование — самая тяжёлая стадия", bigBudget.sampling == bigBudget.seconds(for: .sampling))
let summed = RunStage.pipeline.reduce(0.0) { $0 + bigBudget.seconds(for: $1) }
check("бюджет совпадает с суммой стадий", abs(bigBudget.total - summed) < 1e-6)

var offsets: [Double] = []
for stage in RunStage.pipeline {
    offsets.append(bigBudget.offset(of: stage))
}
check("смещения стадий возрастают", zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 })
check("смещение первой стадии = 0", abs(offsets[0]) < 1e-12)
check("после последней стадии остаётся её вес", abs((offsets[4] + weights[4]) - 1.0) < 1e-9)

// Замеры из логов должны воспроизводиться моделью в опорных точках.
let refSampling = PowerCurve.value(x: 786_432, anchors: Measured.samplingAnchors)
let ref512Sampling = PowerCurve.value(x: 262_144, anchors: Measured.samplingAnchors)
let refDecoding = PowerCurve.value(x: 786_432, anchors: Measured.decodingAnchors)
print(String(format: "  сэмплирование: %.1f с/шаг при 768x1024, %.1f при 512x512",
             refSampling, ref512Sampling))
print(String(format: "  декодирование: %.1f с при 768x1024", refDecoding))
check("опорная точка сэмплирования 768x1024", abs(refSampling - 1085.03) < 0.5, "\(refSampling)")
check("опорная точка сэмплирования 512x512", abs(ref512Sampling - 818.97) < 0.5, "\(ref512Sampling)")
check("опорная точка декодирования", abs(refDecoding - 637.79) < 0.5, "\(refDecoding)")
check("кривая монотонна", PowerCurve.value(x: 100_000, anchors: Measured.samplingAnchors)
        < PowerCurve.value(x: 700_000, anchors: Measured.samplingAnchors))

// Фактические замеры из лога важнее модели.
let calibrated = StageBudget.projected(
    settings: big,
    promptTokens: 276,
    measuredStepSeconds: 2448.47
)
check("замер скорости шага переопределяет модель",
      abs(calibrated.sampling - 2448.47 * 24) < 0.001, "\(calibrated.sampling)")
let calibratedLoad = StageBudget.projected(settings: big, measuredLoading: 146.84)
check("замер загрузки переопределяет модель", abs(calibratedLoad.loading - 146.84) < 0.001)

@MainActor
func checkRunnerReplay() async {
    print("=== 7. Прогресс по стадиям на реальном логе ===")

    let replay = GenerationRunner()
    replay.currentSettings = big
    replay.beginTracking(big)

    func replayLine(_ line: String) {
        replay.consume(line)
    }

    replayLine("[INFO   ] llm.cpp:1  - split prompt \" \" to 276 tokens")
    replayLine("[INFO   ] main.cpp:400 - generate_image 768x1024")
    replayLine("[INFO   ] llm.cpp:900 - get_learned_condition completed, taking 495.86s")
    check("кольцо знает общее число шагов до первой строки", replay.samplingStepsTotal == 24 && replay.samplingStepsDone == 0)
    check("остаток до первого шага считается из прогноза", (replay.samplingRemainingSeconds ?? -1) > 0)
    replayLine("  |======>                                           | 3/24 - 2448.47s/it")
    check("кольцо показывает текущий шаг", replay.samplingStepText == "Шаг 3 из 24", replay.samplingStepText)
    check("после третьего шага остался 21 шаг", replay.samplingRemainingText.hasPrefix("Осталось 21 шаг"), replay.samplingRemainingText)
    if let remaining = replay.samplingRemainingSeconds {
        check("остаток сэмплирования считается по замеру шага", abs(remaining - 21 * 2448.47) < 2.0, "\(remaining)")
    } else {
        check("остаток сэмплирования считается по замеру шага", false)
    }
    replayLine("[INFO   ] image.cpp:899  - sampling completed, taking 26040.83s")
    replayLine("[INFO   ] vae.hpp:200 - latent 0 decoded, taking 637.79s")
    replayLine("[INFO   ] main.cpp:497  - save result image 0 to 'outputs/x.png' (success)")
    replayLine("[INFO   ] image.cpp:1050 - generate_image completed in 27174.79s")

    print(String(format: "  стадия: %@, прогресс %.1f%%", replay.stage.rawValue, replay.progressFraction * 100))
    for row in replay.stageBreakdown {
        print(String(format: "    %@ %@ %.0f%%", row.title, row.state == .finished ? "✓" : " ", row.progress * 100))
    }

    check("токены взяты из лога", replay.promptTokens == 276)
    check("стадия дошла до завершения", replay.stage == .done, replay.stage.rawValue)
    check("на завершении ровно 100%", abs(replay.progressFraction - 1.0) < 1e-9, "\(replay.progressFraction)")
    check("прогресс = 100.0%", replay.percentText == "100.0%", replay.percentText)
    check("шаги считаются из строки прогресса", replay.stepsDone == 3 && replay.stepsTotal == 24)
    check("замер кодирования подхвачен", replay.measuredEncoding == 495.86)
    check("замер декодирования подхвачен", replay.measuredDecoding == 637.79)
    check("все стадии закрыты", replay.stageBreakdown.allSatisfy { $0.state == .finished })

    // Стадии не могут идти назад даже при перемешанных строках лога.
    let rewind = GenerationRunner()
    rewind.currentSettings = big
    rewind.beginTracking(big)
    rewind.consume("[INFO   ] image.cpp:899  - sampling completed, taking 26040.83s")
    rewind.consume("[INFO   ] main.cpp:400 - generate_image 768x1024")
    rewind.consume("[INFO   ] llm.cpp:900 - get_learned_condition completed, taking 495.86s")
    check("стадия не откатывается назад", rewind.stage.pipelineIndex >= RunStage.sampling.pipelineIndex, rewind.stage.rawValue)
    check("прогресс не уменьшается", rewind.progressFraction > 0)

    // Порог стадии: сумма весов пройденных стадий.
    var midSettings = big
    midSettings.steps = 10
    let mid = GenerationRunner()
    mid.currentSettings = midSettings
    mid.beginTracking(midSettings)
    mid.consume("[INFO   ] llm.cpp:1  - split prompt \" \" to 276 tokens")
    mid.consume("[INFO   ] main.cpp:400 - generate_image 768x1024")
    mid.consume("[INFO   ] llm.cpp:900 - get_learned_condition completed, taking 495.86s")
    mid.consume("  |======>                                           | 0/10 - 2448.47s/it")
    let midBudget = mid.budget
    if let midBudget {
        let floorExpected = midBudget.offset(of: .sampling)
        print(String(format: "  порог входа в сэмплирование: %.2f%%", floorExpected * 100))
        check("порог входа равен сумме весов первых стадий",
              abs(mid.progressFraction - floorExpected) < 1e-9, "\(mid.progressFraction)")
        check("порог заметно больше нуля", floorExpected > 0.01)
        check("порог заметно меньше ста", floorExpected < 0.25)
    }

    // Превью: файл preview.png рядом с выводом подхватывается посекундным
    // опросом тика и показывается, пока нет финальной картинки.
    check("превью лежит рядом с выводом",
          big.previewURL.lastPathComponent == "preview.png"
            && big.previewURL.deletingLastPathComponent().path == big.resolvedOutputDirectory)

    let previewDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ds_previewtest")
    try? FileManager.default.removeItem(at: previewDir)
    let previewSetup: Bool = {
        guard (try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)) != nil,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                         bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 6, bitsPerPixel: 24),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: previewDir.appendingPathComponent("preview.png"), options: [])) != nil
    }()
    check("тестовый preview.png создан", previewSetup)
    var pvSettings = big
    pvSettings.outputDirectory = previewDir.path
    let pvr = GenerationRunner()
    pvr.currentSettings = pvSettings
    pvr.isRunning = true
    pvr.refreshPreview()
    check("preview.png подхватывается тиком", pvr.previewImage != nil)
    pvr.refreshPreview()
    check("повторный опрос превью стабилен", pvr.previewImage != nil)
    try? FileManager.default.removeItem(at: previewDir)
}


await checkRunnerReplay()

print("")
if failures == 0 {
    print("ИТОГ: все проверки пройдены")
} else {
    print("ИТОГ: провалено \(failures)")
}
exit(failures == 0 ? 0 : 1)
