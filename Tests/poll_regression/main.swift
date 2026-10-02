import AppKit
import Foundation

/// Регрессия: приложение рвало генерацию, когда сервер не отвечал на опрос.
///
/// Сценарий из реального сбоя: первый запуск, длинный промпт (318 токенов).
/// Пока `sd-server` читает 14.6 ГБ весов с диска и считает conditioning,
/// он не отвечает на HTTP. Раньше опрос ждал 15 секунд и отваливался, а сервер
/// продолжал считать впустую — приложение показывало ошибку, картинки не было.
///
/// Проверка: задача доходит до конца и картинка появляется.
@MainActor
func runRegression() async -> Int32 {
    var s = GenerationSettings()
    s.rootPath = AppConstants.defaultRoot
    s.prompt = """
    Close-up photography, A fictional ID card held by a hand, A blue symbol field in \
    the upper left with the country code MR, Young woman with long, straight blonde \
    hair and center part, Fair skin with clearly visible natural freckles on nose and \
    cheeks, neutral facial expression, hazel green eyes with a straight gaze forward, \
    Black top with visible neckline, Small silver stud earrings on the earlobes, Shiny \
    laminated surface with visible holographic security patterns and guilloche lines \
    over the portrait and text, SAMPLE NAME ERIKA 07.11.1998 BERLIN 01.12.2030, \
    Holding the lower right corner of the card, Fair, Visible thumb with long, \
    almond-shaped fingernail, painted in glossy burgundy or dark red, Plain, solid \
    white surface, Soft, even indoor lighting with slight reflections on the card \
    surface and the glossy nail polish, Vertical close-up from a bird's-eye view, \
    fully focused on the card and the thumb
    """
    s.steps = 1
    s.cfgScale = 7.0
    s.sampler = .dpmPP2sA
    s.aspect = .landscape169
    s.threads = 8
    s.backend = .cpu
    s.outputName = "poll_regression"

    print("=== Регрессия опроса: холодный старт + длинный промпт ===")
    let size = s.resolvedSize
    print("  \(size.width)×\(size.height), \(s.steps) шаг, \(s.sampler.rawValue), промпт ~\(s.prompt.count) символов")

    let problems = s.problems
    if !problems.isEmpty {
        print("  FAIL валидация:")
        problems.forEach { print("    - " + $0) }
        return 1
    }

    let runner = GenerationRunner()
    let started = Date()
    runner.run(s)

    var lastStage = ""
    let deadline = Date().addingTimeInterval(90 * 60)
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if runner.stage.rawValue != lastStage {
            lastStage = runner.stage.rawValue
            let line = String(format: "[%@] %@ %@ · %@",
                              Clock.short(), lastStage, runner.percentText, runner.stepSummary)
            print("  " + line)
        }
        if !runner.isRunning, lastStage != "Не запущено" { break }
    }

    let seconds = Date().timeIntervalSince(started)
    print(String(format: "  итог: «%@» за %.1f с", runner.stage.rawValue, seconds))
    if !runner.exitMessage.isEmpty { print("  сообщение: " + runner.exitMessage) }

    var failures = 0

    // Главная проверка регрессии.
    if runner.logLines.contains(where: { $0.contains("The request timed out") }) {
        print("  FAIL в логе остался таймаут опроса")
        failures += 1
    } else {
        print("  ok   таймаута опроса в логе нет")
    }

    if runner.stage == .done {
        print("  ok   генерация дошла до конца")
    } else {
        print("  FAIL генерация не завершилась: \(runner.stage.rawValue)")
        failures += 1
    }

    let bytes = (try? FileManager.default.attributesOfItem(atPath: s.outputURL.path))?[.size] as? Int ?? 0
    if bytes > 0 {
        print("  ok   картинка сохранена: \(bytes) байт")
    } else {
        print("  FAIL картинка не сохранена")
        failures += 1
    }

    if runner.engine.isWarm {
        print("  ok   веса остались в памяти после генерации")
    } else {
        print("  FAIL веса не удержались в памяти")
        failures += 1
    }

    try? FileManager.default.removeItem(at: s.outputURL)
    runner.shutdownEngine()

    return failures == 0 ? 0 : 1
}

enum Clock {
    static func short() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

let code = await runRegression()
print(code == 0 ? "ИТОГ РЕГРЕССИИ: пройдено" : "ИТОГ РЕГРЕССИИ: провалено")
exit(code)