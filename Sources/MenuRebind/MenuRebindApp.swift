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
    private let store = ShortcutStore()

    @State private var rules: [ShortcutRule] = []
    @State private var editing = false
    @State private var application: TargetApplication?
    @State private var menuName = ""
    @State private var pickedMenuName: String?
    @State private var shortcut = ""
    @State private var notice: String?
    @State private var isError = false
    @State private var menuScanID = UUID()
    @State private var scanningMenus = false
    @State private var packageMenus: [String] = []
    @State private var configuredMenus: [String] = []
    @State private var runningMenus: [String] = []

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
        .task(id: menuScanID) {
            if let application { await scanMenus(for: application) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadRules()
        }
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
                HStack {
                    TextField("例如「关闭」或「文件->关闭」", text: $menuName)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 270)
                        .accessibilityLabel("菜单名称")
                    menuPicker
                }
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

    private var menuPicker: some View {
        let configured = configuredMenus.filter { !runningMenus.contains($0) }
        let package = packageMenus.filter { !configuredMenus.contains($0) && !runningMenus.contains($0) }

        return Menu("选取菜单") {
            if scanningMenus {
                Text("正在读取菜单…")
            } else if runningMenus.isEmpty && configured.isEmpty && package.isEmpty {
                Text("暂未找到菜单名称")
            }
            if let application, !runningMenus.isEmpty {
                Section("\(application.name) 的当前菜单") { menuOptions(runningMenus) }
                if !configured.isEmpty || !package.isEmpty {
                    Menu("已有改键和安装包候选") {
                        menuCandidates(configured: configured, package: package)
                    }
                }
            } else {
                menuCandidates(configured: configured, package: package)
            }
            Button("读取运行中的菜单…", action: readRunningMenus)
                .disabled(scanningMenus)
            Menu("手动填写参考") {
                Section("中文") {
                    menuOptions(["关闭", "关闭窗口", "关闭标签页", "关闭所有窗口", "最小化", "退出"])
                }
                Section("English") {
                    menuOptions(["Close", "Close Window", "Close Tab", "Close All Windows", "Minimize", "Quit"])
                }
            }
        }
        .fixedSize()
        .disabled(application == nil)
        .help("选取名称并原样填入输入框")
    }

    @ViewBuilder
    private func menuCandidates(configured: [String], package: [String]) -> some View {
        if !configured.isEmpty {
            Section("系统已有改键") { menuOptions(configured) }
        }
        if !package.isEmpty {
            Section("安装包候选") { menuOptions(package) }
        }
    }

    private func menuOptions(_ names: [String]) -> some View {
        ForEach(names, id: \.self) { name in
            Button(name.replacingOccurrences(of: "->", with: " › ")) {
                menuName = name
                pickedMenuName = name
            }
        }
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已改键").font(.headline)
            if rules.isEmpty {
                Text("还没有改键记录。")
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
            if application != target {
                if pickedMenuName == menuName { menuName = "" }
                pickedMenuName = nil
                clearMenus()
            }
            application = target
            notice = nil
            startMenuScan()
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: onChoose)
        } else {
            panel.begin(completionHandler: onChoose)
        }
    }

    private func scanMenus(for target: TargetApplication) async {
        let request = menuScanID
        let readLiveMenus = RunningAppMenus.isTrusted && RunningAppMenus.processID(for: target) != nil
        let worker = Task.detached(priority: .userInitiated) {
            let configured = (try? ShortcutStore().configuredMenuNames(in: target)) ?? []
            let package = MenuNames.fromBundle(of: target)
            let running = readLiveMenus ? RunningAppMenus.read(for: target) : []
            return (configured, package, running)
        }
        let (configured, package, running) = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, request == menuScanID, application == target else { return }
        configuredMenus = configured
        packageMenus = package
        runningMenus = running
        scanningMenus = false
        if readLiveMenus && running.isEmpty {
            report("请让 \(target.name) 显示要改键的窗口，再读取菜单。")
        }
    }

    private func readRunningMenus() {
        guard let application else { return }
        guard RunningAppMenus.processID(for: application) != nil else {
            report("请先打开 \(application.name)，再读取运行中的菜单。")
            return
        }
        guard RunningAppMenus.isTrusted else {
            report("请在「系统设置 → 隐私与安全性 → 辅助功能」允许菜单改键，再读取一次。")
            RunningAppMenus.requestAccess()
            return
        }
        notice = nil
        startMenuScan()
    }

    private func startMenuScan() {
        scanningMenus = true
        menuScanID = UUID()
    }

    private func clearMenus() {
        packageMenus = []
        configuredMenus = []
        runningMenus = []
        scanningMenus = false
        menuScanID = UUID()
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
        pickedMenuName = nil
        shortcut = ""
        editing = false
        clearMenus()
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
