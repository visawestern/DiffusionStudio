import Foundation

/// Модель бюджета времени по стадиям пайплайна.
///
/// Зачем она нужна: у `sd-cli` есть точный прогресс только внутри сэмплирования
/// (`N/M - Xs/it`). Остальные стадии он печатает только постфактум, поэтому без
/// модели стадий прогрессбар скачет с 0 сразу на 95% и обратно не откатывается.
///
/// Все опорные числа — реальные замеры `sd-cli` на этой машине (Qwen-Image 2.1
/// Q6_K, CPU, 8 потоков, 32 ГБ RAM). Источники зафиксированы рядом с числами,
/// чтобы их можно было перепроверить по логам.
enum Measured {
    /// Опорный размер, на котором сняты основные замеры: 768×1024.
    static let referencePixels = 768.0 * 1024.0

    // MARK: Сэмплирование

    /// `sampling completed, taking 26040.83s` за 24 шага при 768×1024.
    static let samplingSecondsPerStepAtReference = 1085.03

    /// Опорные точки «секунд на шаг» по площади кадра.
    /// - 65536 px (256×256, 1 шаг, сквозной тест) → 174.1 с/шаг
    /// - 262144 px (512×512, 8 шагов) → 818.97 с/шаг
    /// - 786432 px (768×1024, 24 шага) → 1085.03 с/шаг
    ///
    /// Зависимость от площади заметно слабее линейной: между 512×512 и 768×1024
    /// площадь растёт втрое, а время на шаг — всего в 1.3 раза. Основная часть
    /// стоимости шага не зависит от числа пикселей. Именно поэтому модель
    /// степенная, а не линейная, и именно поэтому реальная скорость из лога
    /// важнее любого прогноза: как только `sd-cli` печатает первую строку
    /// `N/M - Xs/it`, бюджет сэмплирования пересчитывается по факту.
    static let samplingAnchors: [(pixels: Double, seconds: Double)] = [
        (65_536, 174.1),
        (262_144, 818.97),
        (786_432, 1085.03),
    ]

    // MARK: Кодирование промпта

    /// `get_learned_condition completed, taking 128.21s` при 1 токене.
    static let encodingBase = 126.87

    /// Наклон по числу токенов: (495.86 − 128.21) / (276 − 1).
    /// 495.86 с — тот же замер на промпте из 276 токенов.
    static let encodingSecondsPerToken = 1.3371

    /// Грубая оценка, если точное число токенов из лога ещё не пришло.
    /// Английский текст даёт ~4.2 символа на токен, русский — заметно меньше,
    /// поэтому берём консервативные 3.2.
    static let encodingCharsPerToken = 3.2

    // MARK: Остальные стадии

    /// `loading tensors completed`: 78.16 с (энкодер) + 66.38 с (диффузия)
    /// + 2.30 с (VAE) = 146.84 с. В сквозном тесте та же стадия заняла 192 с.
    static let loadingSeconds = 168.0

    /// `latent 1 decoded, taking ...`:
    /// - 65536 px → 41.82 с
    /// - 262144 px → 624.00 с
    /// - 786432 px → 637.79 с
    ///
    /// Странность данных: между 512×512 и 768×1024 время растёт всего на 2%,
    /// хотя площадь втрое. Похоже, при включённом тайлинге стоимость упирается
    /// в число тайлов, а не в пиксели. Поэтому на больших кадрах кривая
    /// практически плоская, и аппроксимировать её линейной зависимостью от
    /// площади нельзя — отсюда кусочно-степенная интерполяция по опорным точкам.
    static let decodingAnchors: [(pixels: Double, seconds: Double)] = [
        (65_536, 41.82),
        (262_144, 624.00),
        (786_432, 637.79),
    ]

    /// Запись PNG на диск: в логах это доли секунды, округляем до 3 с,
    /// чтобы полоса не дёргалась в самом конце.
    static let savingSeconds = 3.0
}

/// Кусочно-степенная интерполяция `y = a · x^k` по опорным точкам, отсортированным
/// по x. Крайние участки продолжаются тем же показателем, что и ближайший отрезок.
enum PowerCurve {
    static func value(x: Double, anchors: [(pixels: Double, seconds: Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if x <= first.pixels { return extrapolate(x: x, from: first, to: anchors.count > 1 ? anchors[1] : first) }
        if x >= last.pixels { return extrapolate(x: x, from: last, to: anchors.count > 1 ? anchors[anchors.count - 2] : last) }

        for i in 0..<(anchors.count - 1) {
            let a = anchors[i], b = anchors[i + 1]
            if x >= a.pixels && x <= b.pixels {
                return interpolate(x: x, a: a, b: b)
            }
        }
        return last.seconds
    }

    private static func interpolate(x: Double, a: (pixels: Double, seconds: Double), b: (pixels: Double, seconds: Double)) -> Double {
        guard b.pixels > a.pixels, b.seconds > 0, a.seconds > 0 else { return b.seconds }
        let k = log(b.seconds / a.seconds) / log(b.pixels / a.pixels)
        return a.seconds * pow(x / a.pixels, k)
    }

    private static func extrapolate(x: Double, from: (pixels: Double, seconds: Double), to: (pixels: Double, seconds: Double)) -> Double {
        guard from.pixels > 0, from.seconds > 0, to.pixels > 0, to.seconds > 0 else { return from.seconds }
        let k = log(to.seconds / from.seconds) / log(to.pixels / from.pixels)
        return max(from.seconds * pow(x / from.pixels, k), 0.01)
    }
}

/// Строка разбивки прогресса по стадиям для панели в UI.
struct StageRow: Identifiable {
    enum State { case pending, running, finished }

    let stage: RunStage
    let weight: Double
    let progress: Double
    let seconds: Double
    let state: State

    var id: String { stage.rawValue }

    /// «12%» — доля стадии в общем времени работы.
    var weightText: String {
        String(format: "%.0f%%", weight * 100)
    }

    var secondsText: String {
        if state == .finished && seconds > 0 {
            return GenerationSettings.human(seconds)
        }
        return "≈ " + GenerationSettings.human(seconds)
    }

    var title: String { stage.rawValue }
}

/// Сколько секунд ожидается на каждой стадии для конкретного набора параметров.
struct StageBudget {
    var loading: Double
    var encoding: Double
    var sampling: Double
    var decoding: Double
    var saving: Double

    var total: Double { loading + encoding + sampling + decoding + saving }

    /// Доля стадии в общем времени, 0...1.
    func weight(of stage: RunStage) -> Double {
        let total = self.total
        guard total > 0 else { return 0 }
        return seconds(for: stage) / total
    }

    /// Доля работы, которая уже позади, до начала этой стадии.
    func offset(of stage: RunStage) -> Double {
        RunStage.pipeline
            .prefix(while: { $0 != stage })
            .reduce(0.0) { $0 + weight(of: $1) }
    }

    func seconds(for stage: RunStage) -> Double {
        switch stage {
        case .loading: return loading
        case .encoding: return encoding
        case .sampling: return sampling
        case .decoding: return decoding
        case .saving: return saving
        case .idle, .done, .failed, .cancelled: return 0
        }
    }

    /// Бюджет по параметрам. Фактические замеры, если они есть, подставляются
    /// вместо прогноза — см. `StageBudget.measured(...)`.
    static func projected(
        settings: GenerationSettings,
        promptTokens: Int? = nil,
        measuredStepSeconds: Double? = nil,
        measuredLoading: Double? = nil,
        measuredEncoding: Double? = nil,
        measuredDecoding: Double? = nil
    ) -> StageBudget {
        let pixels = Double(settings.width * settings.height)
        let steps = Double(max(1, settings.steps))
        let batch = Double(max(1, settings.batchCount))

        let loading = measuredLoading ?? Measured.loadingSeconds * batch

        let tokens = promptTokens ?? estimatedTokens(settings.prompt)
        let encoding = measuredEncoding
            ?? (Measured.encodingBase + Measured.encodingSecondsPerToken * Double(tokens)) * batch

        // Измеренная скорость всегда важнее прогноза: сэмплирование занимает
        // больше половины времени, и одна точная строка из лога исправляет
        // всю оценку.
        let perStep = measuredStepSeconds
            ?? PowerCurve.value(x: pixels, anchors: Measured.samplingAnchors)
        let sampling = perStep * steps * batch

        let decoding = measuredDecoding
            ?? PowerCurve.value(x: pixels, anchors: Measured.decodingAnchors) * batch

        return StageBudget(
            loading: loading,
            encoding: encoding,
            sampling: sampling,
            decoding: decoding,
            saving: Measured.savingSeconds
        )
    }

    /// Оценка числа токенов, пока в логе не появилось точное значение.
    static func estimatedTokens(_ prompt: String) -> Int {
        let length = Double((prompt as NSString).length)
        return max(1, Int((length / Measured.encodingCharsPerToken).rounded()))
    }
}