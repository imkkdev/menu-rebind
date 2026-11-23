import Foundation
import XCTest
@testable import MenuRebindCore

final class MenuNamesTests: XCTestCase {
    func testReadsBundleMenuResourcesWithoutChangingTheTitles() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("Fixture.app")
        let resources = url.appendingPathComponent("Contents/Resources")
        let localized = resources.appendingPathComponent("zh-Hans.lproj")
        let base = resources.appendingPathComponent("Base.lproj")
        try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try writePlist([
            "CFBundleIdentifier": "local.menu-rebind.resources." + temporary.lastPathComponent,
            "CFBundleDevelopmentRegion": "zh-Hans",
            "CFBundlePackageType": "APPL",
            "NSMainNibFile": "EditorInterface",
        ], to: url.appendingPathComponent("Contents/Info.plist"))
        try writePlist([
            "zh-Hans": ["1.title": "关闭  文档", "2.title": "打开…", "3.title": "退出%@"],
            "en": ["1.title": "Close Document"],
        ], to: resources.appendingPathComponent("EditorInterface.loctable"))
        try """
        "AppMenu.close" = "关闭网易 UU 远程";
        "AppMenu.minimize" = "最小化";
        "AppMenu.quit" = "退出%1$@";
        "Alert.close" = "关闭提示";
        """.write(to: localized.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf16)
        try writePlist(["AppMenu.close": "Close"], to: base.appendingPathComponent("Localizable.strings"))
        let outsideTable = temporary.appendingPathComponent("AppMenu.strings")
        try writePlist(["1.title": "关闭外部资源"], to: outsideTable)
        try FileManager.default.createSymbolicLink(
            at: resources.appendingPathComponent("AppMenu.strings"), withDestinationURL: outsideTable
        )

        let application = try XCTUnwrap(TargetApplication(url: url))
        let names = MenuNames.fromBundle(of: application)
        XCTAssertEqual(Set(names), ["关闭  文档", "关闭网易 UU 远程", "打开…", "最小化"])
        XCTAssertTrue(names.first?.hasPrefix("关闭") == true)
    }

    private func writePlist(_ entries: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        try data.write(to: url)
    }
}
