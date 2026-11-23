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
            .first {
                !$0.isTerminated && $0.processIdentifier > 0
                    && $0.bundleURL?.resolvingSymlinksInPath().path == selectedPath
            }?
            .processIdentifier
    }

    static func read(for application: TargetApplication) -> [String] {
        guard let pid = processID(for: application) else { return [] }
        let reader = Reader(processID: pid)
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = reader.attribute(kAXMenuBarAttribute, of: app),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else { return [] }

        let paths = reader.menuPaths(from: menuBar as! AXUIElement)
        guard processID(for: application) == pid else { return [] }
        let groups = Dictionary(grouping: Set(paths)) { $0.last ?? "" }
        let names = groups.flatMap { title, paths in
            paths.count == 1 ? [title] : paths.map { $0.joined(separator: "->") }
        }
        return Array(MenuNames.sorted(names).prefix(32))
    }

    private struct Reader {
        let processID: pid_t
        let deadline = ContinuousClock.now + .seconds(3)

        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var owner: pid_t = 0
            guard !Task.isCancelled, ContinuousClock.now < deadline,
                  AXUIElementGetPid(element, &owner) == .success, owner == processID
            else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.2)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        func menuPaths(from menuBar: AXUIElement) -> [[String]] {
            guard attribute(kAXRoleAttribute, of: menuBar) as? String == kAXMenuBarRole else { return [] }
            let limit = 400
            let topLevel = attribute(kAXChildrenAttribute, of: menuBar) as? [AXUIElement] ?? []
            var queue: [(element: AXUIElement, path: [String])] = topLevel.prefix(limit).map { ($0, []) }
            var paths: [[String]] = []

            // Read top-level commands before spending the budget on large submenus.
            for index in 0..<limit {
                guard index < queue.count, !Task.isCancelled, ContinuousClock.now < deadline else { break }
                let (element, parents) = queue[index]
                guard let role = attribute(kAXRoleAttribute, of: element) as? String else { continue }
                let isMenuHeading = parents.isEmpty
                guard isMenuHeading ? role == kAXMenuBarItemRole : (role == kAXMenuRole || role == kAXMenuItemRole)
                else { continue }
                var path = parents
                if role != kAXMenuRole {
                    guard let title = attribute(kAXTitleAttribute, of: element) as? String,
                          !title.contains("->"), MenuTitle(title) != nil
                    else { continue }
                    // macOS exposes the leading Apple menu through the target app's own PID.
                    if index == 0 && (title == "Apple" || title == "\u{F8FF}") { continue }
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
