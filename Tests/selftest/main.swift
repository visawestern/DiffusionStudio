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

print("=== 1. Генератор аргументов ===")

var s = GenerationSettings()
s.rootPath = "/tmp/root"
s.prompt = "test prompt"
s.negativePrompt = ""
s.aspect = .square
s.longEdge = 512
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
s.preview = .none
s.diffusionFA = false
s.vaeTiling = false
s.outputName = "argcheck"
s.verbose = false

let args = s.buildArguments()
print("  " + args.joined(separator: " "))

check("есть --diffusion-model", args.contains("--diffusion-model"))
check("путь к модели относительный", args.firstIndex(of: "--diffusion-model").map { args[$0 + 1].hasPrefix("models/") } ?? false)
check("размер 512x512", args.contains("512"))
check("steps передан", args.contains("--steps") && args.contains("8"))
check("backend=cpu", args.contains("cpu"))
check("vf не включён без флага", !args.contains("-v"))
check("negative prompt не передаётся при пустом", !args.contains("-n"))
check("seed положительный", (args.firstIndex(of: "-s").map { args[$0 + 1] } == "42"))
check("нет пустых аргументов", !args.contains(""))
check("выход в outputs/", args.contains { $0.hasSuffix("/outputs/argcheck.png") })

s.negativePrompt = "blurry"
s.randomSeed = true
s.verbose = true
s.preview = .proj
s.previewInterval = 1
s.diffusionFA = true
s.vaeTiling = true
s.backend = .auto
s.maxVRAM = 6
s.aspect = .a4
s.longEdge = 1024
let args2 = s.buildArguments()
print("  " + args2.joined(separator: " "))

check("negative prompt передан", args2.contains("-n") && args2.contains("blurry"))
check("random seed = -1", (args2.firstIndex(of: "-s").map { args2[$0 + 1] } == "-1"))
check("auto-fit вместо backend", args2.contains("--auto-fit"))
check("max-vram передан", args2.contains("mtl0=6.0"))
check("preview + path", args2.contains("--preview") && args2.contains("proj") && args2.contains("--preview-path"))
check("флаги оптимизации", args2.contains("--diffusion-fa") && args2.contains("--vae-tiling"))
check("A4 даёт 1024x1408", args2.contains("1024") && args2.contains("1408"))

print("=== 2. Размеры по пресетам ===")
for preset in AspectPreset.allCases {
    let size = preset.size(for: 512)
    print(String(format: "  %@ → %d x %d", preset.label, size.0, size.1))
    check("\(preset.label) кратен 64", size.0 % 64 == 0 && size.1 % 64 == 0)
}

print("=== 3. Валидация ===")
var bad = GenerationSettings()
bad.prompt = "   "
check("пустой промпт ловится", !bad.problems.isEmpty)
var noModels = GenerationSettings()
noModels.prompt = "x"
noModels.rootPath = "/nonexistent/path"
check("отсутствие бинаря ловится", noModels.problems.contains { $0.contains("Не найден исполняемый") })
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

print("")
if failures == 0 {
    print("ИТОГ: все проверки пройдены")
} else {
    print("ИТОГ: провалено \(failures)")
}
exit(failures == 0 ? 0 : 1)