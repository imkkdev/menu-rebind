import AppKit
import ApplicationServices
import MenuRebindCore

enum RunningAppMenus {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func processID(for application: TargetApplication) -> pid_t? {
        let selectedPath = URL(fileURLWithPath: application.path).resolvingSymlinksInPath().path
        return NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleIdentifier)
            .first { $0.bundleURL?.resolvingSymlinksInPath().path == selectedPath && !$0.isTerminated }?
            .processIdentifier
    }

    static func read(processID: pid_t) -> [String] {
        let reader = Reader()
        let app = AXUIElementCreateApplication(processID)
        guard let menuBar = reader.attribute(kAXMenuBarAttribute, of: app),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else { return [] }

        let paths = reader.menuPaths(from: menuBar as! AXUIElement)
        let groups = Dictionary(grouping: Set(paths)) { $0.last ?? "" }
        let names = groups.flatMap { title, paths in
            paths.count == 1 ? [title] : paths.map { $0.joined(separator: "->") }
        }
        return Array(MenuNames.sorted(names).prefix(32))
    }

    private struct Reader {
        let deadline = ContinuousClock.now + .seconds(3)

        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        func menuPaths(from menuBar: AXUIElement) -> [[String]] {
            let limit = 400
            var queue: [(element: AXUIElement, path: [String])] = [(menuBar, [])]
            var paths: [[String]] = []

            // Read top-level commands before spending the budget on large submenus.
            for index in 0..<limit {
                guard index < queue.count, !Task.isCancelled, ContinuousClock.now < deadline else { break }
                let (element, parents) = queue[index]
                guard let role = attribute(kAXRoleAttribute, of: element) as? String else { continue }
                var path = parents
                if role == kAXMenuBarItemRole || role == kAXMenuItemRole {
                    guard let title = attribute(kAXTitleAttribute, of: element) as? String,
                          !title.contains("->"), MenuTitle(title) != nil
                    else { continue }
                    path.append(title)
                }

                let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
                if role == kAXMenuItemRole, children.isEmpty {
                    paths.append(path)
                } else {
                    queue += children.prefix(limit - queue.count).map { ($0, path) }
                }
            }
            return paths
        }
    }
}
