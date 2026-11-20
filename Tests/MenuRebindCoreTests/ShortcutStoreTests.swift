import CoreFoundation
import Foundation
import XCTest
@testable import MenuRebindCore

final class ShortcutStoreTests: XCTestCase {
    func testChangingAndRestoringPreservesOtherCommands() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let title = try XCTUnwrap(MenuTitle("关闭"))
        fixture.write(["关闭": "@w", "退出": "@q"])

        XCTAssertTrue(try fixture.store.apply("@^w", to: title, in: fixture.application))
        XCTAssertTrue(try fixture.store.apply("@~w", to: title, in: fixture.application))
        let rule = try XCTUnwrap(fixture.store.rules().first)
        XCTAssertEqual(rule.originalShortcut, "@w")
        XCTAssertEqual(fixture.read(), ["关闭": "@~w", "退出": "@q"])

        fixture.write(["关闭": "@~w", "退出": "@^q", "缩放": "@+"])
        try fixture.store.restore(rule.id)
        XCTAssertEqual(fixture.read(), ["关闭": "@w", "退出": "@^q", "缩放": "@+"])
        XCTAssertTrue(try fixture.store.rules().isEmpty)
    }

    func testNewOverrideCanBeRemovedAfterEditingIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let title = try XCTUnwrap(MenuTitle("文件->关闭"))
        let key = "\u{1B}文件\u{1B}关闭"

        XCTAssertTrue(try fixture.store.apply("@^w", to: title, in: fixture.application))
        XCTAssertTrue(try fixture.store.apply("@~w", to: title, in: fixture.application))
        XCTAssertEqual(fixture.read(), [key: "@~w"])
        let rule = try XCTUnwrap(fixture.store.rules().first)
        XCTAssertNil(rule.originalShortcut)

        try fixture.store.restore(rule.id)
        XCTAssertTrue(fixture.read().isEmpty)
        XCTAssertTrue(try fixture.store.rules().isEmpty)
    }

    func testExistingIdenticalOverrideIsNotClaimed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.write(["关闭": "@^w"])
        let title = try XCTUnwrap(MenuTitle("关闭"))

        XCTAssertFalse(try fixture.store.apply("@^w", to: title, in: fixture.application))
        XCTAssertTrue(try fixture.store.rules().isEmpty)
        XCTAssertEqual(fixture.read(), ["关闭": "@^w"])
    }

    func testExternalOverrideIsPreservedAndCanBecomeNewBaseline() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let title = try XCTUnwrap(MenuTitle("关闭"))
        try fixture.store.apply("@^w", to: title, in: fixture.application)
        let initialRule = try XCTUnwrap(fixture.store.rules().first)
        fixture.write(["关闭": "@$w"])

        XCTAssertThrowsError(try fixture.store.restore(initialRule.id)) { error in
            guard case ShortcutStoreError.changedExternally = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(fixture.read(), ["关闭": "@$w"])
        try fixture.store.apply("@~w", to: title, in: fixture.application)
        try fixture.store.restore(initialRule.id)
        XCTAssertEqual(fixture.read(), ["关闭": "@$w"])
    }

    func testReopensAfterPreferenceWasSavedBeforeHistoryCommit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let title = try XCTUnwrap(MenuTitle("关闭"))
        let rule = ShortcutRule(
            application: fixture.application, menu: title, shortcut: "@^w", originalShortcut: "@w"
        )
        let pending = ShortcutStore.PendingChange(
            bundleIdentifier: fixture.application.bundleIdentifier,
            menu: title,
            before: "@w",
            after: "@^w",
            replacement: rule
        )
        let history = ShortcutStore.State(rules: [], pending: pending)
        try JSONEncoder().encode(history).write(to: fixture.directory.appendingPathComponent("rules.json"))
        fixture.write(["关闭": "@^w"])

        XCTAssertEqual(try fixture.store.rules(), [rule])
        try fixture.store.restore(rule.id)
        XCTAssertEqual(fixture.read(), ["关闭": "@w"])
    }
}

private struct Fixture {
    let directory: URL
    let application: TargetApplication
    var store: ShortcutStore { ShortcutStore(directory: directory) }
    private var domain: CFString { application.bundleIdentifier as CFString }
    private var key: CFString { "NSUserKeyEquivalents" as CFString }

    init() throws {
        let id = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-rebind-tests-\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        application = TargetApplication(name: "Fixture", bundleIdentifier: "local.menu-rebind.tests.\(id)", path: "")
    }

    func read() -> [String: String] {
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: String] ?? [:]
    }

    func write(_ preferences: [String: String]?) {
        CFPreferencesSetValue(key, preferences as CFDictionary?, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func cleanUp() {
        write(nil)
        try? FileManager.default.removeItem(at: directory)
    }
}
