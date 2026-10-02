import AppKit
import SwiftUI

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
        let r = s.resolvedSize
        s.width = r.width
        s.height = r.height
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

struct LogSidebar: View {
    @ObservedObject var runner: GenerationRunner
    var onClose: () -> Void

    @State private var filter: String = ""
    @State private var autoscroll = true

    private var visibleLines: [String] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        if f.isEmpty { return runner.logLines }
        let needle = f.lowercased()
        return runner.logLines.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body_
            Divider()
            footer
        }
        .frame(width: 470)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Журнал")
                .font(.system(size: 12, weight: .semibold))
            Text("\(visibleLines.count)/\(runner.logLines.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                autoscroll.toggle()
            } label: {
                Image(systemName: autoscroll ? "arrow.down.to.line.compact" : "arrow.down.to.line")
            }
            .buttonStyle(.borderless)
            .help("Автопрокрутка к последней строке")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(visibleLines.joined(separator: "\n"), forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Скопировать отфильтрованные строки в буфер обмена")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Закрыть журнал (⌘L)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var body_: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Фильтр по тексту, например: ERROR или sampling", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .help("Показывать только строки, содержащие этот текст")
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Сбросить фильтр")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(visibleLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .onChange(of: visibleLines.count) { _, n in
                    if autoscroll && n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(runner.stage.rawValue)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if !runner.stepSummary.isEmpty {
                Text(runner.stepSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Очистить") { runner.clearLog() }
                .buttonStyle(.borderless)
                .font(.system(size: 10))
                .help("Удалить все строки из журнала")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[ERROR") || line.hasPrefix("!") { return .red }
        if line.hasPrefix("[WARN") { return .orange }
        if line.hasPrefix("[INFO") { return .primary }
        if line.hasPrefix("$") || line.hasPrefix("—") { return .secondary }
        return .primary
    }
}

struct RootView: View {
    @StateObject private var model = SettingsModel()
    @StateObject private var runner = GenerationRunner()
    @StateObject private var presets = PresetStore()

    @State private var presetName = ""
    @AppStorage("DiffusionStudio.logSidebar") private var logVisible = false
    @State private var didSync = false
    @FocusState private var promptFocused: Bool

    private var s: Binding<GenerationSettings> { $model.s }

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                HSplitView {
                    parameterPanel
                        .frame(minWidth: 390, idealWidth: 450, maxWidth: 540)
                    outputPanel
                        .frame(minWidth: 420)
                }
            }

            if logVisible {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    LogSidebar(runner: runner) {
                        withAnimation(.easeOut(duration: 0.18)) { logVisible = false }
                    }
                    .transition(.move(edge: .trailing))
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.25)).frame(width: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, x: -3)
                }
            }

            floatingButton
        }
        .frame(minWidth: 980, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.s) { _, _ in
            model.normalize()
            model.persist()
        }
        .onChange(of: model.s.modelSet) { _, _ in model.normalize() }
        .onAppear {
            if !didSync {
                didSync = true
                model.ensureOutputDirectory()
            }
        }
    }

    private func toggleLog() {
        withAnimation(.easeOut(duration: 0.18)) { logVisible.toggle() }
    }

    private var floatingButton: some View {
        Button {
            toggleLog()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: logVisible ? "chevron.right" : "terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text("ЖУРНАЛ")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
                if runner.isRunning {
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 6)
            .frame(width: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(nsColor: .controlAccentColor).opacity(0.94))
            )
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l", modifiers: .command)
        .help(logVisible ? "Скрыть журнал (⌘L)" : "Показать журнал (⌘L)")
        .padding(.trailing, logVisible ? 478 : 5)
        .padding(.vertical, 62)
        .transition(.opacity)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                model.ensureOutputDirectory()
                runner.run(model.s)
            } label: {
                Label("Запустить", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(runner.isRunning || !model.s.problems.isEmpty)
            .help("Запустить генерацию с текущими параметрами (⌘↩)")

            Button {
                runner.cancel()
            } label: {
                Label("Стоп", systemImage: "stop.fill")
            }
            .disabled(!runner.isRunning)
            .help("Досрочно прервать процесс sd-cli")

            Button {
                runner.runEnvironmentCheck()
            } label: {
                Image(systemName: "cpu")
            }
            .help("Показать список доступных вычислительных устройств (CPU / Metal / BLAS)")

            Button {
                model.chooseOutputDirectory()
            } label: {
                Image(systemName: "folder.badge.gearshape")
            }
            .help("Выбрать папку, куда будут сохраняться картинки")

            Button {
                model.ensureOutputDirectory()
                NSWorkspace.shared.activateFileViewerSelecting([model.s.outputURL])
            } label: {
                Image(systemName: "folder")
            }
            .help("Открыть папку с сохранёнными картинками в Finder")

            Divider().frame(height: 18)

            Text(runner.stage.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(runner.stage == .failed ? Color.red : Color.secondary)
                .help("Текущая стадия пайплайна: загрузка моделей, кодирование промпта, сэмплирование, декод, готово")

            Spacer()

            if !runner.logVisibleHint.isEmpty {
                Text(runner.logVisibleHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var parameterPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                modelSection
                promptSection
                sizeSection
                samplerSection
                qualitySection
                performanceSection
                outputSection
                estimateSection
            }
            .padding(12)
        }
    }

    private var modelSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Модели", systemImage: "shippingbox")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Пресет моделей", help: "Набор файлов для Qwen-Image 2.1. Переключение подставит имена трёх файлов: диффузия, текстовый энкодер и VAE.") {
                    Picker("", selection: s.modelSet) {
                        ForEach(ModelSet.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }

                FieldRow(label: "Движок", help: "Папка со stable-diffusion.cpp фиксирована: здесь лежат build/bin/sd-cli и папка models. Менять её не нужно — выбирается только папка для сохранения картинок. Если переносите движок, задайте переменную окружения DIFFUSION_STUDIO_ROOT.") {
                    Text(model.s.rootPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if model.s.modelSet == .qwenImage21Q6 {
                    fileRow("Diffusion", value: model.s.diffusionModel, help: "Файл весов модели. Q6_K — качественный квант, 5.6 ГБ. Q4 был бы быстрее, но качество заметно хуже.")
                    fileRow("Энкодер", value: model.s.encoderModel, help: "Текстовый энкодер Qwen3-VL 8B в int8, 9.35 ГБ. Полностью на CPU: в 8 ГБ VRAM он не помещается.")
                    fileRow("VAE", value: model.s.vaeModel, help: "Декодер в bf16, 675 МБ. На CPU занимает около 10 минут при 768×1024.")
                    Label(model.s.modelSet.memoryNote, systemImage: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    fileRow("Diffusion", value: model.s.diffusionModel, help: "Имя файла в папке models. Расширение .gguf указывать обязательно.", editable: $model.s.diffusionModel)
                    fileRow("Энкодер", value: model.s.encoderModel, help: "Имя файла в папке models. Должен совпадать с архитектурой диффузионной модели.", editable: $model.s.encoderModel)
                    fileRow("VAE", value: model.s.vaeModel, help: "Имя файла в папке models. Должен соответствовать версии модели.", editable: $model.s.vaeModel)
                }
            }
            .padding(6)
        }
    }

    private func fileRow(_ title: String, value: String, help: String, editable: Binding<String>? = nil) -> some View {
        FieldRow(label: title, help: help) {
            if let binding = editable {
                TextField("имя файла в models/", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
            } else {
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var promptSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Промпты", systemImage: "text.bubble")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Промпт — что должно быть на картинке", help: "Описывай предмет, освещение, стиль и камеру. Чем конкретнее — тем лучше результат. До 500-700 символов; после 300 кодирование заметно замедляется.") {
                    TextEditor(text: s.prompt)
                        .font(.system(size: 11))
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if model.s.prompt.isEmpty {
                                Text("например: portrait photo of a woman, soft window light, 85mm lens, shallow depth of field, photorealistic")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                FieldRow(label: "Negative prompt — чего быть не должно", help: "Перечисляет дефекты, которые модель чаще всего добавляет. Уже заполнено большим списком артефактов; можно дополнить или очистить, но убирать полностью не стоит — заметно ухудшает результат.") {
                    TextEditor(text: s.negativePrompt)
                        .font(.system(size: 10))
                        .frame(height: 86)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        .overlay(alignment: .topLeading) {
                            if model.s.negativePrompt.isEmpty {
                                Text("чего избегать: blurry, lowres, watermark, deformed hands…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 7)
                                    .allowsHitTesting(false)
                            }
                        }
                }

                HStack(spacing: 6) {
                    Button("Вернуть дефолтный") { model.s.negativePrompt = Defaults.negative }
                        .controlSize(.small)
                        .help("Подставить большой стандартный список артефактов, который обычно убирают")
                    Button("Очистить") { model.s.negativePrompt = "" }
                        .controlSize(.small)
                        .help("Полностью очистить negative prompt — качество обычно падает")
                    Spacer()
                    Text("\(model.s.prompt.count) / \(model.s.negativePrompt.count) симв.")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(6)
        }
    }

    private var sizeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Размер", systemImage: "aspectratio")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Пропорции", help: "Все размеры автоматически округляются до кратных 64 — этого требует сетка модели. Промежуточных знароджений быть не может.") {
                    Picker("", selection: s.aspect) {
                        ForEach(AspectPreset.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                FieldRow(label: "Длинная сторона, px", help: "Размер по большей стороне. 512 — быстрые черновики, 768 — рабочий размер, 1024 и выше — долго. Каждый шаг стоит времени линейно по площади.") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(model.s.longEdge) },
                            set: { model.s.longEdge = Int($0) }
                        ), in: 256...1536, step: 64)
                        Text("\(model.s.longEdge)")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                FieldRow(label: "Итоговый размер", help: "Показывает, что реально уйдёт в модель после округления до кратных 64.") {
                    Text("\(model.s.width) × \(model.s.height)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                }

                FieldRow(label: "Картинок за раз", help: "Batch count. Каждая следующая картинка добавляет полный проход по всем шагам, поэтому время растёт линейно.") {
                    Stepper("", value: s.batchCount, in: 1...4)
                        .labelsHidden()
                        .help("Сколько вариантов сгенерировать за один запуск")
                }
            }
            .padding(6)
        }
    }

    private var samplerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Сэмплирование", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Шаги, \(model.s.steps)", help: "Количество итераций сэмплера. Для этой модели 16-24 — рабочий диапазон: ниже 12 появляется каша, выше 32 почти нет выигрыша в качестве, только время.") {
                    Stepper("", value: s.steps, in: 1...60)
                        .labelsHidden()
                }

                FieldRow(label: "CFG, \(String(format: "%.1f", model.s.cfgScale))", help: "Сила следования промпту. Для Qwen-Image оптимально 3.5-4.5. Ниже 2 — изображение «плывёт», выше 7 — артефакты и пересыщение.") {
                    Slider(value: s.cfgScale, in: 1...12, step: 0.1)
                        .help("Слайдер CFG")
                }

                FieldRow(label: "Flow shift, \(String(format: "%.1f", model.s.flowShift))", help: "Сдвиг расписания шума. Для Qwen-Image держать около 3.0. Влияет на контраст и «чистоту» фона.") {
                    Slider(value: s.flowShift, in: 0...8, step: 0.1)
                        .help("Слайдер flow shift")
                }

                FieldRow(label: "Сэмплер", help: "Алгоритм интегрирования. euler — самый предсказуемый и быстрый, dpm++2m обычно чуть точнее на том же числе шагов.") {
                    Picker("", selection: s.sampler) {
                        ForEach(Sampler.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }

                FieldRow(label: "Сид", help: "Фиксированное зерно. Одинаковый сид при одинаковых параметрах даёт воспроизводимый результат — удобно для подбора промпта методом перебора.") {
                    HStack(spacing: 6) {
                        TextField("42", value: s.seed, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 84)
                            .disabled(model.s.randomSeed)
                        Toggle("случайный", isOn: s.randomSeed)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 10))
                            .help("Каждый запуск получит новое зерно (-1). Полезно, когда нужно разнообразие, а не повторяемость")
                    }
                }
            }
            .padding(6)
        }
    }

    private var qualitySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Оптимизация и качество", systemImage: "bolt")
                    .font(.system(size: 11, weight: .semibold))

                toggleRow("Flash attention (diffusion)", $model.s.diffusionFA,
                          "Ускоряет и уменьшает расход памяти на внимании в диффузионной модели. На этой модели включено по умолчанию.")
                toggleRow("Тайлинг VAE", $model.s.vaeTiling,
                          "Декодирует картинку кусками, а не целиком. Снижает пиковую память; на 512-768 px почти не влияет на скорость, на 1024+ заметно спасает от падений.")
                toggleRow("Offload to CPU", $model.s.offloadToCPU,
                          "Держать веса в RAM и подгружать в VRAM по мере надобности. На этой машине бесполезно: VRAM всё равно занята десктопом, поэтому режим CPU.")
                toggleRow("Без сегментации", $model.s.disableSegmentedCompute,
                          "Отключает автоматическое разбиение графа на сегменты. Может ускорить CPU-режим, но повышает риск нехватки памяти.")
                toggleRow("Eager load", $model.s.eagerLoad,
                          "Грузить все веса сразу, без ленивой подгрузки. Старт медленнее, но во время сэмплирования меньше пауз.")
                toggleRow("Подробный лог", $model.s.verbose,
                          "Добавляет флаг -v. Нужен для разбора ошибок; на большой картинке даёт тысячи строк, поэтому по умолчанию включён, а журнал удобно фильтровать.")
            }
            .padding(6)
        }
    }

    private var performanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Производительность", systemImage: "speedometer")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Режим вычислений", help: "CPU — единственный рабочий вариант на этом Mac: в 8 ГБ VRAM Radeon Pro 5500M десктоп оставляет около 700 МБ, и модель в неё не помещается. Auto-fit включает автоматический подбор, но он падал дважды.") {
                    Picker("", selection: s.backend) {
                        ForEach(BackendChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }

                Label(model.s.backend.hint, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(model.s.backend == .auto ? Color.orange : Color.secondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                FieldRow(label: "Потоков CPU, \(model.s.threads)", help: "Сколько ядер отдать вычислениям. На 16 логических ядрах оптимально 6-10: выше начинается contention с системой, и быстрее не становится.") {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(model.s.threads) },
                            set: { model.s.threads = Int($0) }
                        ), in: 1...Double(ProcessInfo.processInfo.activeProcessorCount), step: 1)
                        Text("\(model.s.threads)")
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 30, alignment: .trailing)
                    }
                }

                FieldRow(label: "Лимит VRAM, \(model.s.maxVRAM == 0 ? "авто" : String(format: "%.1f ГБ", model.s.maxVRAM))", help: "Потолок памяти GPU, который готова занять модель. 0 — не ограничивать. Имеет смысл только в режиме GPU; в режиме CPU поле ни на что не влияет.") {
                    HStack {
                        Slider(value: s.maxVRAM, in: 0...8, step: 0.5)
                        Text(model.s.maxVRAM == 0 ? "авто" : String(format: "%.1f", model.s.maxVRAM))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                FieldRow(label: "Превью, \(model.s.preview.rawValue) каждые \(model.s.previewInterval) \(GenerationSettings.stepsWord(model.s.previewInterval))", help: "Промежуточная картинка, чтобы не ждать вслепую. proj — мгновенно, но в 1/16 разрешения: видно только крупные пятна. tae и vae дают честную картинку, но на этой модели декод занимает 10-40 минут, так что для контроля они не годятся.") {
                    HStack(spacing: 6) {
                        Picker("", selection: s.preview) {
                            ForEach(PreviewChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Stepper("", value: s.previewInterval, in: 1...8)
                            .labelsHidden()
                            .help("Обновлять превью каждые N шагов")
                    }
                }
            }
            .padding(6)
        }
    }

    private var outputSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Label("Сохранение", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))

                FieldRow(label: "Папка для сохранения", help: "Куда писать готовые картинки. По умолчанию outputs/ внутри папки движка. Кнопка справа открывает системный выбор папки.") {
                    HStack(spacing: 6) {
                        TextField("outputs", text: s.outputDirectory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                        Button {
                            model.chooseOutputDirectory()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Выбрать папку через системный диалог")
                        Button {
                            model.ensureOutputDirectory()
                            NSWorkspace.shared.activateFileViewerSelecting([model.s.outputURL])
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .help("Открыть папку в Finder")
                    }
                }

                FieldRow(label: "Имя файла", help: "Без расширения — .png добавится сам. Превью всегда пишется рядом как preview.png и перезаписывается.") {
                    HStack(spacing: 6) {
                        TextField("output", text: s.outputName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                        Text(".png")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(model.s.outputURL.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help("Полный путь, который будет записан")

                Divider()

                FieldRow(label: "Пресеты настроек", help: "Сохранить текущий набор параметров под именем, потом переключаться одной строкой. Хранятся в настройках приложения.") {
                    HStack(spacing: 6) {
                        TextField("имя пресета", text: $presetName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10))
                            .onSubmit { savePreset() }
                        Button("Сохранить") { savePreset() }
                            .help("Запомнить текущие параметры под указанным именем")
                        Picker("", selection: Binding(
                            get: { presets.selected ?? "" },
                            set: { n in if let v = presets.named(n) { model.s = v } }
                        )) {
                            Text("загрузить…").tag("")
                            ForEach(presets.names, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                        .help("Загрузить сохранённый пресет")
                        Button {
                            if let n = presets.selected { presets.delete(n) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Удалить выбранный пресет")
                        Button("Сброс") { model.resetToDefaults() }
                            .help("Вернуть оптимальные параметры по умолчанию, сохранив выбранную папку")
                    }
                }
            }
            .padding(6)
        }
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        presets.save(name: name.isEmpty ? "Без имени" : name, settings: model.s)
        presetName = ""
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>, _ help: String) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.checkbox)
            .font(.system(size: 10))
            .help(help)
    }

    private var estimateSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Label("Оценка и проверка", systemImage: "clock")
                    .font(.system(size: 11, weight: .semibold))

                Text(model.s.estimatedCostText)
                    .font(.system(size: 10, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)

                Text("Расчёт по замерам этой модели на CPU: 1085 с на шаг сэмплирования при 768×1024, декод ≈ 637 с. Реальное время сильно зависит от свободной памяти — при уходе в своп шаг становится в разы длиннее.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Label(model.s.estimatedMemoryText(), systemImage: "memorychip")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !model.s.problems.isEmpty {
                    Divider()
                    ForEach(model.s.problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

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
    }

    private var swapUsedMB: Int? {
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        out.arguments = ["-n", "vm.swapusage"]
        let pipe = Pipe()
        out.standardOutput = pipe
        try? out.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: " ").map(String.init)
        guard let idx = parts.firstIndex(of: "used"), idx + 1 < parts.count else { return nil }
        let number = parts[idx + 1].replacingOccurrences(of: "M", with: "")
        return Double(number).map { Int($0) }
    }

    private var outputPanel: some View {
        VStack(spacing: 0) {
            progressBar
            Divider()
            imageArea
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let f = runner.progressFraction {
                ProgressView(value: f)
            } else if runner.isRunning {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: 0).opacity(0.25)
            }
            if !runner.exitMessage.isEmpty {
                Text(runner.exitMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(runner.stage == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var imageArea: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                if let img = runner.resultImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: geo.size.height * 0.72)
                        .shadow(radius: 5)
                    Text("Результат · \(model.s.width)×\(model.s.height) · \(runner.resultImage?.size.width ?? 0)px")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(model.s.outputURL.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let img = runner.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: geo.size.height * 0.72)
                        .shadow(radius: 5)
                    Text("Превью · шаг \(runner.stepsDone)/\(runner.stepsTotal) · \(model.s.preview.rawValue)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 42))
                            .foregroundStyle(.tertiary)
                        Text("Здесь появится результат")
                            .foregroundStyle(.secondary)
                        Text("первое превью — после первого шага сэмплирования")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
        .frame(minHeight: 260)
    }
}