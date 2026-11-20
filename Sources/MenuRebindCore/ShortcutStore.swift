import CoreFoundation
import Darwin
import Foundation

public struct TargetApplication: Codable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let path: String

    public init(name: String, bundleIdentifier: String, path: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }

    public init?(url: URL) {
        guard url.pathExtension.lowercased() == "app",
              let identifier = Bundle(url: url)?.bundleIdentifier,
              !identifier.isEmpty
        else { return nil }

        let displayName = FileManager.default.displayName(atPath: url.path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        self.init(name: name, bundleIdentifier: identifier, path: url.path)
    }
}

public struct MenuTitle: Codable, Equatable {
    public let text: String

    public init?(_ text: String) {
        let components = text.components(separatedBy: "->")
        guard components.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              !text.contains("\u{1B}")
        else { return nil }
        self.text = text
    }

    var preferenceKey: String {
        let components = text.components(separatedBy: "->")
        // AppKit uses a leading escape and escape-delimited titles for a full menu path.
        return components.count == 1 ? text : "\u{1B}" + components.joined(separator: "\u{1B}")
    }
}

public struct ShortcutRule: Codable, Equatable, Identifiable {
    public var id: String { application.bundleIdentifier + ":" + menu.preferenceKey }
    public let application: TargetApplication
    public let menu: MenuTitle
    public let shortcut: String
    public let originalShortcut: String?
}

public enum ShortcutStoreError: LocalizedError {
    case invalidApplication
    case unreadablePreferences
    case changedExternally
    case unableToSavePreferences
    case unableToLock

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: "找不到有效的 App 标识符。"
        case .unreadablePreferences: "系统快捷键的存储格式无法读取。请在系统设置里检查该 App 的快捷键。"
        case .changedExternally: "这条快捷键在系统设置里已被改动。请检查当前设置，原来的记录仍保留。"
        case .unableToSavePreferences: "macOS 未能保存快捷键。请检查该 App 的快捷键后重试。"
        case .unableToLock: "暂时无法打开改键记录。请重新打开菜单改键后重试。"
        }
    }
}

public struct ShortcutStore {
    private static let preferencesKey = "NSUserKeyEquivalents"
    private let directory: URL

    public init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Menu Rebind")) {
        self.directory = directory
    }

    public func rules() throws -> [ShortcutRule] {
        try withLock { try loadState().rules }
    }

    /// Returns false when the requested shortcut is already present in System Settings.
    @discardableResult
    public func apply(_ shortcut: String, to menu: MenuTitle, in application: TargetApplication) throws -> Bool {
        try withLock {
            var state = try loadState()
            let bundleIdentifier = application.bundleIdentifier
            let current = try readValue(for: menu, in: bundleIdentifier)
            guard current != shortcut else { return false }

            let original = state.rules.first {
                $0.application.bundleIdentifier == bundleIdentifier && $0.menu == menu && $0.shortcut == current
            }
            let rule = ShortcutRule(
                application: application,
                menu: menu,
                shortcut: shortcut,
                originalShortcut: original.map(\.originalShortcut) ?? current
            )
            let change = PendingChange(
                bundleIdentifier: bundleIdentifier,
                menu: menu,
                before: current,
                after: shortcut,
                replacement: rule
            )
            try perform(change, state: &state)
            return true
        }
    }

    public func restore(_ id: ShortcutRule.ID) throws {
        try withLock {
            var state = try loadState()
            guard let rule = state.rules.first(where: { $0.id == id }) else { return }
            let bundleIdentifier = rule.application.bundleIdentifier
            let current = try readValue(for: rule.menu, in: bundleIdentifier)
            if current == rule.originalShortcut {
                state.rules.removeAll { $0.id == id }
                try saveState(state)
                return
            }
            guard current == rule.shortcut else { throw ShortcutStoreError.changedExternally }
            let change = PendingChange(
                bundleIdentifier: bundleIdentifier,
                menu: rule.menu,
                before: current,
                after: rule.originalShortcut,
                replacement: nil
            )
            try perform(change, state: &state)
        }
    }

    struct PendingChange: Codable {
        let bundleIdentifier: String
        let menu: MenuTitle
        let before: String?
        let after: String?
        let replacement: ShortcutRule?
    }

    struct State: Codable {
        var rules: [ShortcutRule] = []
        var pending: PendingChange?
    }

    private var stateFile: URL { directory.appendingPathComponent("rules.json") }

    private func withLock<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("rules.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ShortcutStoreError.unableToLock }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ShortcutStoreError.unableToLock }
        return try action()
    }

    private func loadState() throws -> State {
        guard FileManager.default.fileExists(atPath: stateFile.path) else { return State() }
        var state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
        if let pending = state.pending {
            // A previous process may have stopped between the preferences write and the history write.
            let current = try readValue(for: pending.menu, in: pending.bundleIdentifier)
            if current == pending.after { finish(pending, state: &state) }
            state.pending = nil
            try saveState(state)
        }
        return state
    }

    private func saveState(_ state: State) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    private func perform(_ change: PendingChange, state: inout State) throws {
        state.pending = change
        try saveState(state)
        try writePreference(change)
        finish(change, state: &state)
        state.pending = nil
        try saveState(state)
    }

    private func finish(_ change: PendingChange, state: inout State) {
        state.rules.removeAll {
            $0.application.bundleIdentifier == change.bundleIdentifier && $0.menu == change.menu
        }
        if let rule = change.replacement { state.rules.insert(rule, at: 0) }
    }

    private func readValue(for menu: MenuTitle, in bundleIdentifier: String) throws -> String? {
        try value(for: menu, in: readPreferences(bundleIdentifier))
    }

    private func value(for menu: MenuTitle, in preferences: [String: Any]) throws -> String? {
        guard let existing = preferences[menu.preferenceKey] else { return nil }
        guard let shortcut = existing as? String else { throw ShortcutStoreError.unreadablePreferences }
        return shortcut
    }

    private func readPreferences(_ bundleIdentifier: String) throws -> [String: Any] {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != (kCFPreferencesAnyApplication as String),
              bundleIdentifier != ".GlobalPreferences"
        else { throw ShortcutStoreError.invalidApplication }

        let domain = bundleIdentifier as CFString
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw ShortcutStoreError.unreadablePreferences
        }
        guard let value = CFPreferencesCopyValue(
            Self.preferencesKey as CFString, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) else { return [:] }
        guard let preferences = value as? [String: Any] else { throw ShortcutStoreError.unreadablePreferences }
        return preferences
    }

    private func writePreference(_ change: PendingChange) throws {
        var preferences = try readPreferences(change.bundleIdentifier)
        guard try value(for: change.menu, in: preferences) == change.before else {
            throw ShortcutStoreError.changedExternally
        }
        if let shortcut = change.after {
            preferences[change.menu.preferenceKey] = shortcut
        } else {
            preferences.removeValue(forKey: change.menu.preferenceKey)
        }
        let domain = change.bundleIdentifier as CFString
        let value = preferences.isEmpty ? nil : preferences as CFDictionary
        CFPreferencesSetValue(Self.preferencesKey as CFString, value, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost),
              try readValue(for: change.menu, in: change.bundleIdentifier) == change.after
        else { throw ShortcutStoreError.unableToSavePreferences }
    }
}
