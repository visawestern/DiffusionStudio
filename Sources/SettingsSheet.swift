import SwiftUI

struct FieldRow<Content: View>: View {
    let label: String
    let help: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(help)
            }
            content
        }
        .help(help)
    }
}

/// Диалог настроек и диагностики.
///
/// В главном окне остались только элементы, которые можно менять: промпт,
/// размер, сэмплер, потоки, папка вывода. Всё, что менять нельзя — пути,
/// вычисленные значения, состояние движка, оценки и диагностика — собрано
/// здесь, чтобы не занимать место при работе.
struct SettingsSheet: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner: GenerationRunner

    enum Tab: String, CaseIterable, Identifiable {
        case engine = "Движок"
        case models = "Модели"
        case compute = "Вычисления"
        case system = "Система"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .engine: return "cpu"
            case .models: return "shippingbox"
            case .compute: return "speedometer"
            case .system: return "info.circle"
            }
        }
    }

    @State private var tab: Tab = .engine

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Label(t.rawValue, systemImage: t.symbol).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .engine: engineTab
                    case .models: modelsTab
                    case .compute: computeTab
                    case .system: systemTab
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 380)
        }
        .frame(width: 620, height: 540)
    }

    // MARK: Движок

    private var engineTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                Label("Движок", systemImage: "cpu")
                    .font(.system(size: 11, weight: .semibold))

                readOnly("Папка движка", model.s.rootPath,
                         help: "Папка со stable-diffusion.cpp фиксирована: здесь лежат build/bin/sd-server и папка models. Менять её не нужно — настраивается только папка для сохранения картинок. Если переносите движок, задайте переменную окружения DIFFUSION_STUDIO_ROOT.")

                readOnly("Бинарь", model.s.binaryURL.path,
                         help: "Именно sd-server, а не sd-cli: приложение держит его запущенным между картинками, чтобы веса не перечитывались с диска.")

                Divider()

                engineStateRow

                Divider()

                readOnly("Превью", "не поддерживается сервером",
                         help: "У sd-server нет превью: сервер отдаёт только готовый PNG. Пока идёт генерация, картинка появится в конце — за ходом работы следит полоса прогресса и журнал.")
            }
            .padding(6)
        }
    }

    private var engineStateRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Состояние")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .help(engineHelp)
            }

            HStack(spacing: 10) {
                Circle()
                    .fill(engineColor)
                    .frame(width: 8, height: 8)

                Text(runner.engine.state.title)
                    .font(.system(size: 11, weight: .medium))

                if runner.engine.residentMegabytes > 1 {
                    Text(String(format: "· %.1f ГБ в памяти", runner.engine.residentMegabytes / 1024))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(runner.engine.isWarm ? Color.green : Color.secondary)
                        .monospacedDigit()
                }

                Spacer()

                if runner.engine.state == .stopped {
                    Button {
                        runner.engine.start(model.s)
                    } label: {
                        Label("Запустить", systemImage: "bolt.fill")
                    }
                    .help("Запустить sd-server и держать веса модели в памяти")
                } else {
                    Button {
                        runner.shutdownEngine()
                    } label: {
                        Label("Остановить", systemImage: "xmark.circle")
                    }
                    .disabled(runner.isRunning)
                    .help("Остановить sd-server и выгрузить 14.6 ГБ весов из памяти")
                }
            }
        }
        .help(engineHelp)
    }

    private var engineColor: Color {
        switch runner.engine.state {
        case .stopped: return Color.secondary
        case .starting: return Color.orange
        case .ready: return runner.engine.isWarm ? Color.green : Color.yellow
        case .failed: return Color.red
        }
    }

    private var engineHelp: String {
        switch runner.engine.state {
        case .stopped:
            return "Движок не запущен. Веса модели в памяти нет — первая генерация прочитает 14.6 ГБ с диска."
        case .starting:
            return "Идёт чтение весов. Это происходит один раз: дальше sd-server держит модель в памяти и повторные генерации её не перечитывают."
        case .ready:
            return runner.engine.isWarm
                ? "sd-server работает, веса держатся в памяти. Следующая генерация начнётся сразу, без чтения модели с диска."
                : "sd-server работает. Модель будет прочитана при первой генерации и останется в памяти."
        case .failed(let why):
            return "Движок не работает: " + why
        }
    }

    // MARK: Модели

    private var modelsTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                Label("Модели", systemImage: "shippingbox")
                    .font(.system(size: 11, weight: .semibold))

                if model.s.modelSet == .qwenImage21Q6 {
                    readOnly("Diffusion", model.s.diffusionModel, help: "Файл весов модели. Q6_K — качественный квант, 5.6 ГБ. Q4 был бы быстрее, но качество заметно хуже.")
                    readOnly("Энкодер", model.s.encoderModel, help: "Текстовый энкодер Qwen3-VL 8B в int8, 9.35 ГБ. Полностью на CPU: в 8 ГБ VRAM он не помещается.")
                    readOnly("VAE", model.s.vaeModel, help: "Декодер в bf16, 675 МБ. На CPU занимает около 10 минут при 768×1024.")
                } else {
                    editable("Diffusion", text: $model.s.diffusionModel, help: "Имя файла в папке models. Расширение .gguf указывать обязательно.")
                    editable("Энкодер", text: $model.s.encoderModel, help: "Имя файла в папке models. Должен совпадать с архитектурой диффузионной модели.")
                    editable("VAE", text: $model.s.vaeModel, help: "Имя файла в папке models. Должен соответствовать версии модели.")
                }

                readOnly("Состав набора", model.s.modelSet.memoryNote, help: "Что входит в выбранный пресет моделей.")
            }
            .padding(6)
        }
    }

    // MARK: Вычисления

    private var computeTab: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 11) {
                Label("Вычисления", systemImage: "speedometer")
                    .font(.system(size: 11, weight: .semibold))

                readOnly("Режим", model.s.backend.rawValue, help: model.s.backend.hint)

                Label(model.s.backend.hint, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(model.s.backend == .auto ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                readOnly("Потоков CPU", "\(model.s.threads)",
                         help: "Сколько ядер отдано вычислениям. На 16 логических ядрах оптимально 6-10: выше начинается contention с системой, и быстрее не становится.")

                readOnly("Лимит VRAM", model.s.maxVRAM == 0 ? "авто" : String(format: "%.1f ГБ", model.s.maxVRAM),
                         help: "Потолок памяти GPU, который готова занять модель. 0 — не ограничивать. Имеет смысл только в режиме GPU; в режиме CPU поле ни на что не влияет.")

                Divider()

                readOnly("Итоговый размер", "\(model.s.width) × \(model.s.height)",
                         help: "Что реально уйдёт в модель после округления до кратных 64.")

                readOnly("Путь результата", model.s.outputURL.path,
                         help: "Полный путь, который будет записан.")
            }
            .padding(6)
        }
    }

    // MARK: Система

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Оценка времени", systemImage: "clock")
                        .font(.system(size: 11, weight: .semibold))

                    Text(model.s.estimatedCostText)
                        .font(.system(size: 10, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.s.stageWeights, id: \.stage) { w in
                            HStack(spacing: 6) {
                                Text(w.stage.rawValue)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(GenerationSettings.human(w.seconds))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "%.1f%%", w.weight * 100))
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }
                        }
                    }

                    Text("Коэффициенты взяты из замеров этой модели на CPU: 1085 с на шаг при 768×1024, декод ≈ 638 с, кодирование ≈ 127 с + 1.34 с на токен, загрузка ≈ 168 с. Сэмплирование занимает больше 90% времени, поэтому полоса почти всё время идёт по нему — но как только sd-server печатает реальную скорость шага, оценка пересчитывается по факту.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Память", systemImage: "memorychip")
                        .font(.system(size: 11, weight: .semibold))

                    Label(model.s.estimatedMemoryText(), systemImage: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let sw = swapUsedMB {
                        Label("Своп сейчас: \(sw) МБ", systemImage: sw > 2000 ? "tortoise" : "hare")
                            .font(.system(size: 10))
                            .foregroundStyle(sw > 2000 ? Color.red : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(sw > 2000
                                  ? "Много данных в свопе — генерация в разы медленнее. Закрой браузер и мессенджеры."
                                  : "Своп свободен, скорость будет нормальной.")
                    }
                }
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Проверка", systemImage: "checkmark.shield")
                        .font(.system(size: 11, weight: .semibold))

                    if model.s.problems.isEmpty {
                        Label("Всё в порядке: движок, модели и папка вывода на месте.", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(model.s.problems, id: \.self) { p in
                            Label(p, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private var swapUsedMB: Int? {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/bin/sysctl")
        out.arguments = ["-n", "vm.swapusage"]
        let pipe = Pipe()
        out.standardOutput = pipe
        out.standardError = FileHandle.nullDevice
        guard (try? out.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        out.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let digits = text.prefix { $0.isNumber }
        guard let mb = Int(digits) else { return nil }
        return mb < 1024 * 1024 ? mb : mb / 1024
    }

    // MARK: Строчки

    /// Строка со значением, которое менять нельзя.
    private func readOnly(_ title: String, _ value: String, help: String) -> some View {
        FieldRow(label: title, help: help) {
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Строка со значением, которое можно поменять.
    private func editable(_ title: String, text: Binding<String>, help: String) -> some View {
        FieldRow(label: title, help: help) {
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
        }
    }
}