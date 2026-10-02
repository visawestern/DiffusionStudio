import AppKit
import Foundation

@MainActor
func runE2E() async -> Int32 {
    var s = GenerationSettings()
    s.rootPath = AppConstants.defaultRoot
    s.prompt = "a plain grey square on white background"
    s.steps = 1
    s.cfgScale = 2.0
    s.aspect = .square
    s.longEdge = 256
    s.threads = 8
    s.backend = .cpu
    s.verbose = false
    s.outputName = "e2e_selftest"
    s.batchCount = 1

    let runner = GenerationRunner()
    print("=== Сквозной тест: 256x256, 1 шаг, два прогона подряд ===")
    print("  цель: " + s.outputURL.path)
    print("  бинарь: " + s.binaryURL.path)

    let problems = s.problems
    if !problems.isEmpty {
        print("  FAIL валидация не прошла:")
        problems.forEach { print("    - " + $0) }
        return 1
    }

    var failures = 0

    // Первый прогон: sd-server поднимается и читает 14.6 ГБ весов.
    let firstSeconds = await drive(runner: runner, settings: s, label: "первый")
    print(String(format: "  первый прогон: %.1f с", firstSeconds))

    if !runner.engine.isWarm {
        print("  FAIL движок не считается прогретым после генерации")
        failures += 1
    } else {
        print("  ok   веса остались в памяти после генерации")
    }

    let firstSize = (try? FileManager.default.attributesOfItem(atPath: s.outputURL.path))?[.size] as? Int ?? 0
    try? FileManager.default.removeItem(at: s.outputURL)

    // Второй прогон: главная проверка. Модель уже в памяти, повторного чтения
    // 14.6 ГБ быть не должно — иначе время почти не сократится.
    let secondSeconds = await drive(runner: runner, settings: s, label: "второй")
    print(String(format: "  второй прогон: %.1f с", secondSeconds))

    if runner.engine.isWarm {
        print("  ok   веса по-прежнему в памяти")
    } else {
        print("  FAIL после второй генерации веса выгрузились")
        failures += 1
    }

    let secondSize = (try? FileManager.default.attributesOfItem(atPath: s.outputURL.path))?[.size] as? Int ?? 0
    guard secondSize > 0 else {
        print("  FAIL второй прогон не создал файл")
        return Int32(failures + 1)
    }
    print("  ok   файл второго прогона создан, \(secondSize) байт")

    if secondSize == firstSize, firstSize > 0 {
        print("  ok   оба прогона дали одинаковый PNG (\(firstSize) байт)")
    } else {
        print("  warn размеры PNG различаются: \(firstSize) и \(secondSize)")
    }

    if secondSeconds < firstSeconds {
        print(String(format: "  ok   второй прогон быстрее: %.1f с против %.1f с", secondSeconds, firstSeconds))
    } else {
        print("  warn второй прогон не быстрее первого — вероятно, ушла в своп")
    }

    if runner.logLines.contains(where: { $0.contains("loading tensors completed") }) == false {
        print("  warn в логе не было строк загрузки весов")
    }

    print("  последние строки лога:")
    for l in runner.logLines.suffix(8) {
        print("    | " + l)
    }

    try? FileManager.default.removeItem(at: s.outputURL)
    runner.shutdownEngine()

    return failures == 0 ? 0 : 1
}

/// Гоняет одну генерацию и печатает смену стадий.
@MainActor
func drive(runner: GenerationRunner, settings: GenerationSettings, label: String) async -> Double {
    let started = Date()
    var lastStage = ""
    runner.run(settings)

    let deadline = Date().addingTimeInterval(40 * 60)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let line = "[\(Clock.short())] \(label): \(runner.stage.rawValue)"
            + " \(runner.percentText) · \(runner.progressFraction) · шаг \(runner.stepsDone)/\(runner.stepsTotal)"
        if runner.stage.rawValue != lastStage {
            lastStage = runner.stage.rawValue
            print("  " + line)
        }
        if !runner.isRunning, lastStage != "Не запущено" { break }
    }

    let seconds = Date().timeIntervalSince(started)
    print("  \(label): этап «\(runner.stage.rawValue)», \(runner.percentText), \(String(format: "%.1f", seconds)) с")
    if !runner.exitMessage.isEmpty {
        print("    сообщение: " + runner.exitMessage)
    }
    return seconds
}

enum Clock {
    static func short() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

let code = await runE2E()
print(code == 0 ? "ИТОГ E2E: пройдено" : "ИТОГ E2E: провалено")
exit(code)