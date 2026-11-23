import Foundation

public enum MenuNames {
    public static func fromBundle(of application: TargetApplication) -> [String] {
        guard let bundle = Bundle(path: application.path),
              let resources = bundle.resourceURL?.resolvingSymlinksInPath()
        else { return [] }
        let bundlePath = bundle.bundleURL.resolvingSymlinksInPath().path
        guard resources.path == bundlePath || resources.path.hasPrefix(bundlePath + "/") else { return [] }

        let preferences = UserDefaults(suiteName: application.bundleIdentifier)?.stringArray(forKey: "AppleLanguages")
            ?? Locale.preferredLanguages
        let localizations = Bundle.preferredLocalizations(
            from: bundle.localizations.filter { $0 != "Base" }, forPreferences: preferences
        )
        let languages = localizations + [bundle.developmentLocalization, "Base"].compactMap { $0 }
        let tableNames = ["NSMainNibFile", "NSMainStoryboardFile"].compactMap {
            bundle.object(forInfoDictionaryKey: $0) as? String
        } + ["MainMenu", "AppMenu", "MenuBar", "Localizable"]

        var titles: [String] = []
        for tableName in Set(tableNames) {
            guard !Task.isCancelled else { return [] }
            guard !tableName.isEmpty, !tableName.contains("/") else { continue }
            let table = rootTable(named: tableName, in: resources, languages: languages)
            titles += table.compactMap { key, title in
                let lowerKey = key.lowercased()
                let menuKey = ["appmenu.", "mainmenu.", "menubar."].contains { lowerKey.hasPrefix($0) }
                guard menuKey || (tableName != "Localizable" && lowerKey.hasSuffix(".title")) else { return nil }
                guard MenuTitle(title) != nil, !title.contains("->"),
                      title.rangeOfCharacter(from: .newlines) == nil, title.count <= 120,
                      title.range(of: #"%[0-9$+.#-]*[@a-zA-Z]"#, options: .regularExpression) == nil
                else { return nil }
                return title
            }
        }
        return Array(sorted(titles).prefix(24))
    }

    public static func sorted(_ names: [String]) -> [String] {
        let ranked = Set(names).map { (title: $0, priority: priority(of: $0)) }
        return ranked.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.map(\.title)
    }

    private static func priority(of title: String) -> Int {
        let leaf = (title.components(separatedBy: "->").last ?? title).lowercased()
        for (index, prefixes) in [
            ["关闭", "關閉", "close"],
            ["退出", "結束", "quit"],
            ["最小化", "进入全屏", "進入全螢幕", "minimize", "enter full screen"],
            ["新建", "新增", "打开", "打開", "存储", "儲存", "new", "open", "save"],
            ["撤销", "撤銷", "复制", "拷贝", "拷貝", "粘贴", "貼上", "undo", "copy", "paste"],
        ].enumerated() {
            if prefixes.contains(where: { leaf.hasPrefix($0) }) { return index }
        }
        return 5
    }

    private static func rootTable(named name: String, in resources: URL, languages: [String]) -> [String: String] {
        // Some Apple apps combine localized Interface Builder titles into a single property list.
        let translations = propertyList(resources.appendingPathComponent(name + ".loctable"), in: resources)
            as? [String: Any]
        for language in languages {
            let path = resources.appendingPathComponent(language + ".lproj").appendingPathComponent(name + ".strings")
            if let table = propertyList(path, in: resources) as? [String: String], !table.isEmpty { return table }
            if let table = translations?[language] as? [String: String], !table.isEmpty { return table }
        }
        return propertyList(resources.appendingPathComponent(name + ".strings"), in: resources) as? [String: String] ?? [:]
    }

    private static func propertyList(_ path: URL, in resources: URL) -> Any? {
        let file = path.resolvingSymlinksInPath()
        let limit = 4 * 1024 * 1024
        guard file.path.hasPrefix(resources.path + "/"),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }
}
