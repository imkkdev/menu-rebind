import AppKit
import MenuRebindCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MenuRebindApp: App {
    var body: some Scene {
        Window("菜单改键", id: "main") {
            ContentView()
        }
        .defaultSize(width: 620, height: 390)
        .windowResizability(.contentMinSize)
    }
}

private struct ContentView: View {
    private static let uuIdentifier = "com.netease.uuremote"
    private static let uuMenu = "关闭网易UU远程"
    private static let uuShortcut = "@^w"
    private let store = ShortcutStore()

    @State private var rules: [ShortcutRule] = []
    @State private var editing = false
    @State private var application: TargetApplication?
    @State private var menuName = ""
    @State private var shortcut = ""
    @State private var notice: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("App 快捷键").font(.title2.bold())
                Spacer()
                Button("添加改键", systemImage: "plus") {
                    editing = true
                }
                .disabled(editing)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preset
                    if editing { editor }
                    ruleList
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 18)
            }
            if let notice {
                Divider()
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(minWidth: 495, minHeight: 340)
        .task { reloadRules() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadRules()
        }
    }

    private var preset: some View {
        HStack(spacing: 13) {
            Image(systemName: "macwindow")
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("UU 远程防误关").font(.headline)
                Text(Self.uuMenu).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ShortcutLabel(value: "⌘W")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    ShortcutLabel(value: ShortcutText.display(Self.uuShortcut), emphasized: true)
                }
            }
            Spacer()
            Button("应用预设", action: applyPreset)
                .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("应用") {
                HStack {
                    if let application {
                        ApplicationIcon(application: application, size: 22)
                        Text(application.name)
                    }
                    Button(application == nil ? "选择应用…" : "更换应用…", action: pickApplication)
                }
            }
            LabeledContent("菜单名称") {
                TextField("例如「关闭」或「文件->关闭」", text: $menuName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 270)
                    .accessibilityLabel("菜单名称")
            }
            LabeledContent("新快捷键") {
                ShortcutRecorder(value: $shortcut)
                    .fixedSize()
            }
            HStack {
                Spacer()
                Button("取消") { resetEditor() }
                Button("应用改键", action: applyCustom)
                    .buttonStyle(.borderedProminent)
                    .disabled(application == nil || MenuTitle(menuName) == nil || shortcut.isEmpty)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已改键").font(.headline)
            if rules.isEmpty {
                Text("还没有由菜单改键管理的快捷键。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(rules) { rule in
                HStack(spacing: 10) {
                    ApplicationIcon(application: rule.application, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rule.application.name).fontWeight(.medium)
                        Text(rule.menu.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    ShortcutLabel(value: rule.originalShortcut.map(ShortcutText.display) ?? "原有绑定")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    ShortcutLabel(value: ShortcutText.display(rule.shortcut), emphasized: true)
                    Button("恢复") { restore(rule) }
                        .accessibilityLabel("恢复 \(rule.application.name) 的\(rule.menu.text)")
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
    }

    private func pickApplication() {
        let panel = NSOpenPanel()
        panel.title = "选取应用"
        panel.prompt = "选取"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]

        let onChoose: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let target = TargetApplication(url: url) else {
                report("无法读取所选 App 的标识符，请选择完整的 .app。", isError: true)
                return
            }
            application = target
            if menuName.isEmpty && target.bundleIdentifier == Self.uuIdentifier {
                menuName = Self.uuMenu
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: onChoose)
        } else {
            panel.begin(completionHandler: onChoose)
        }
    }

    private func applyPreset() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.uuIdentifier),
              let application = TargetApplication(url: url),
              let menu = MenuTitle(Self.uuMenu)
        else {
            report("未找到 UU 远程。若它放在其他目录，可以用「添加改键」手动选取。", isError: true)
            return
        }
        apply(Self.uuShortcut, menu: menu, application: application)
    }

    private func applyCustom() {
        guard let application, let menu = MenuTitle(menuName), !shortcut.isEmpty else { return }
        if apply(shortcut, menu: menu, application: application) { resetEditor() }
    }

    @discardableResult
    private func apply(_ shortcut: String, menu: MenuTitle, application: TargetApplication) -> Bool {
        do {
            let changed = try store.apply(shortcut, to: menu, in: application)
            let label = ShortcutText.display(shortcut)
            report(changed
                ? "\(application.name) 的快捷键已保存为 \(label)。重新打开目标 App 后验证。"
                : "\(application.name) 的这条菜单快捷键已经是 \(label)。")
            reloadRules()
            return true
        } catch {
            report(error.localizedDescription, isError: true)
            return false
        }
    }

    private func restore(_ rule: ShortcutRule) {
        do {
            try store.restore(rule.id)
            report("\(rule.application.name) 的「\(rule.menu.text)」已恢复。重新打开目标 App 后验证。")
            reloadRules()
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func reloadRules() {
        do {
            rules = try store.rules()
        } catch {
            report(error.localizedDescription, isError: true)
        }
    }

    private func resetEditor() {
        application = nil
        menuName = ""
        shortcut = ""
        editing = false
    }

    private func report(_ message: String, isError: Bool = false) {
        notice = message
        self.isError = isError
    }
}

private struct ApplicationIcon: View {
    let application: TargetApplication
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct ShortcutLabel: View {
    let value: String
    var emphasized = false

    var body: some View {
        Text(value)
            .font(.callout.weight(.medium))
            .foregroundStyle(emphasized ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.background, in: RoundedRectangle(cornerRadius: 5))
            .fixedSize()
    }
}
