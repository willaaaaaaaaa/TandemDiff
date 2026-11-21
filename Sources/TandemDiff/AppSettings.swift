import TandemDiffCore
import Observation
import SwiftUI

enum AppLanguage: String, CaseIterable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var locale: Locale { Locale(identifier: rawValue) }
    var nativeName: String { self == .english ? "English" : "简体中文" }
}

// Reading the language while building a view registers that view for live updates.
// UserDefaults also serves comparison diagnostics prepared on background queues.
@Observable
final class AppLocalization {
    static let shared = AppLocalization()
    private let store: UserDefaults

    init(store: UserDefaults = .standard) { self.store = store }

    var language: AppLanguage {
        get {
            access(keyPath: \.language)
            return store.string(forKey: "appLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .english
        }
        set {
            guard language != newValue else { return }
            withMutation(keyPath: \.language) { store.set(newValue.rawValue, forKey: "appLanguage") }
        }
    }
}

func L(_ english: String, _ chinese: String) -> String {
    AppLocalization.shared.language == .english ? english : chinese
}

extension DiagnosticText {
    var localized: String { L(english, simplifiedChinese) }
}

enum AppAppearance: String {
    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppSettingsView: View {
    @Bindable private var localization = AppLocalization.shared
    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @AppStorage("newTabsBesideActive") private var newTabsBesideActive = false
    @AppStorage("folderUseStripes") private var folderUseStripes = true
    @AppStorage("folderColorIcons") private var folderColorIcons = true
    @AppStorage("escapeClosesFileView") private var escapeClosesFileView = true
    @AppStorage("confirmContentCompare") private var confirmContentCompare = false
    @AppStorage(SessionDefaults.textKey) private var textDefaults: Data?
    @State private var saveError: String?

    var body: some View {
        Form {
            Section(L("General", "通用")) {
                Picker(L("Language", "语言"), selection: $localization.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text($0.nativeName).tag($0) }
                }
                Picker(L("Appearance", "外观"), selection: $appearance) {
                    Text(L("System", "跟随系统")).tag(AppAppearance.system)
                    Text(L("Light", "浅色")).tag(AppAppearance.light)
                    Text(L("Dark", "深色")).tag(AppAppearance.dark)
                }
                .pickerStyle(.segmented)
                Toggle(L("Open new tabs beside the active tab", "在当前标签页旁打开新标签页"), isOn: $newTabsBesideActive)
            }
            Section(L("Folder comparison", "文件夹比较")) {
                Toggle(L("Alternate row backgrounds", "使用交替行背景色"), isOn: $folderUseStripes)
                Toggle(L("Color folders to reflect their contents", "按内容为文件夹着色"), isOn: $folderColorIcons)
                Toggle(L("Ask before comparing contents", "比较内容前询问"), isOn: $confirmContentCompare)
            }
            Section(L("Text comparison", "文本比较")) {
                Toggle(L("Close files opened from a folder with Escape", "按 Esc 关闭从文件夹打开的文件比较"), isOn: $escapeClosesFileView)
                Stepper(value: contextLines, in: 0...100) {
                    LabeledContent(L("Context lines for new sessions", "新会话的上下文行数")) {
                        Text(verbatim: String(contextLines.wrappedValue)).monospacedDigit()
                    }
                }
                if let saveError { Text(saveError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 480)
        .navigationTitle(L("Settings", "设置"))
    }

    private var contextLines: Binding<Int> {
        Binding(get: { SessionDefaults.decodeText(textDefaults).context }, set: { count in
            let defaults = SessionDefaults()
            let original = defaults.text
            var updated = original
            updated.context = count
            do {
                try defaults.save(updated, replacing: original)
                saveError = nil
            } catch { saveError = error.localizedDescription }
        })
    }
}
