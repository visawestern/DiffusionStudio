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
    s.preview = .proj
    s.previewInterval = 1
    s.verbose = false
    s.outputName = "e2e_selftest"
    s.batchCount = 1

    let runner = GenerationRunner()
    print("=== Сквозной тест: 256x256, 1 шаг ===")
    print("  цель: " + s.outputURL.path)
    print("  бинарь: " + s.binaryURL.path)

    let problems = s.problems
    if !problems.isEmpty {
        print("  FAIL валидация не прошла:")
        problems.forEach { print("    - " + $0) }
        return 1
    }

    runner.run(s)

    let deadline = Date().addingTimeInterval(20 * 60)
    var lastStage = ""

    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if runner.stage.rawValue != lastStage {
            lastStage = runner.stage.rawValue
            print("  [" + Clock.short() + "] этап: \(lastStage)  шаг \(runner.stepsDone)/\(runner.stepsTotal)  \(runner.stepSummary)")
        }
        if !runner.isRunning && lastStage != "Не запущено" {
            break
        }
    }

    print("  итоговый этап: \(runner.stage.rawValue)")
    print("  сообщение: \(runner.exitMessage.isEmpty ? "—" : runner.exitMessage)")
    print("  время: \(String(format: "%.1f", runner.lastRunSeconds)) с")
    print("  строк в логе: \(runner.logLines.count)")

    var failures = 0

    let outExists = FileManager.default.fileExists(atPath: s.outputURL.path)
    print(outExists ? "  ok   файл результата создан" : "  FAIL файл результата не создан")
    if !outExists { failures += 1 }

    if let img = runner.resultImage {
        print("  ok   результат загружен в память: \(img.size.width)×\(img.size.height)")
    } else {
        print("  FAIL результат не загрузился в NSImage")
        failures += 1
    }

    if runner.lastRunSeconds > 0 {
        print("  ok   таймер завершения отработал")
    } else {
        print("  FAIL завершение не зафиксировано")
        failures += 1
    }

    if runner.stage == .done {
        print("  ok   этап перешёл в «Готово»")
    } else {
        print("  FAIL этап не «Готово»: \(runner.stage.rawValue)")
        failures += 1
    }

    if runner.stepsTotal == 1 {
        print("  ok   счётчик шагов разобран")
    } else {
        print("  FAIL счётчик шагов: \(runner.stepsTotal)")
        failures += 1
    }

    let previewExists = FileManager.default.fileExists(atPath: s.previewURL.path)
    print(previewExists ? "  ok   превью создано" : "  warn превью не создано (1 шаг — превью могло не успеть)")

    print("  последние строки лога:")
    for l in runner.logLines.suffix(6) {
        print("    | " + l)
    }

    try? FileManager.default.removeItem(at: s.outputURL)
    try? FileManager.default.removeItem(at: s.previewURL)

    return failures == 0 ? 0 : 1
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