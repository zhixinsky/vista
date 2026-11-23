import XCTest
@testable import CarVista

final class CacheRecoveryTests: XCTestCase {
    private let root = "/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111"
    private var directory: String { root + "/Library/Caches/MappedImageCache/com.apple.CarPlayApp.wallpaper-images" }
    private func path(_ slot: String, version: Int = 16) -> String {
        "\(directory)/CARWallpaper\(slot)-\(version).cpbitmap"
    }
    private var allPaths: [String] {
        ["Blue", "Purple", "Gray", "Green", "Brown", "Red"].flatMap { colour in
            [path(colour + "-Dark"), path(colour + "-Light")]
        }
    }
    private func plan(_ saved: [String], present: [String] = []) -> [String: Any] {
        let records = Dictionary(uniqueKeysWithValues: saved.map { ($0, ["root": root]) })
        return CCEngine.cacheRecoveryPlan(records: records,
            files: present.map { ["path": $0] }, root: root) as? [String: Any] ?? [:]
    }
    func testEmptyCacheRecoversAllTwelveIndependentAppearances() {
        XCTAssertEqual(Set(plan(allPaths)["paths"] as? [String] ?? []), Set(allPaths))
    }
    func testHealthyCacheNeedsNoWrites() {
        XCTAssertEqual(plan(allPaths, present: allPaths)["paths"] as? [String], [])
    }
    func testOnlyMissingLightIsRestoredWithoutTouchingDark() {
        let light = path("Blue-Light")
        XCTAssertEqual(plan(allPaths, present: allPaths.filter { $0 != light })["paths"] as? [String], [light])
    }
    func testPartialBackupDoesNotInventOtherSlots() {
        XCTAssertEqual(plan([path("Blue-Light")])["paths"] as? [String], [path("Blue-Light")])
    }
    func testExistingNewSystemVersionSuppressesOldVersionRestore() {
        XCTAssertEqual(plan([path("Blue-Light")], present: [path("Blue-Light", version: 17)])["paths"] as? [String], [])
    }
    func testAmbiguousOldRecordsAreNotChosenArbitrarily() {
        let result = plan([path("Blue-Light"), path("Blue-Light", version: 17), path("Blue-Dark")])
        XCTAssertEqual(result["paths"] as? [String], [path("Blue-Dark")])
        XCTAssertEqual(result["ambiguous"] as? Int, 1)
    }
    func testCachesRootIsNeverARestoreDestination() {
        let misplaced = root + "/Library/Caches/CARWallpaperBlue-Light-16.cpbitmap"
        XCTAssertEqual(plan([misplaced])["paths"] as? [String], [])
    }
    func testAnotherContainersRecordCannotBeRestored() {
        let result = CCEngine.cacheRecoveryPlan(records: [path("Blue-Light"): ["root": "/another-container"]], files: [], root: root)
        XCTAssertEqual(result["paths"] as? [String], [])
    }
    func testMatchingLooseFileCanBeUsedForCopyAndCleanup() {
        let bytes = Data([1, 2, 3])
        let choice = CCEngine.recoverySource(backup: bytes, loose: bytes)
        XCTAssertEqual(choice["source"] as? String, "loose")
        XCTAssertEqual(choice["data"] as? Data, bytes)
    }
    func testCustomBackupWinsWhenRootFileDiffers() {
        let custom = Data([1, 2, 3])
        let choice = CCEngine.recoverySource(backup: custom, loose: Data([9, 8, 7]))
        XCTAssertEqual(choice["source"] as? String, "backup")
        XCTAssertEqual(choice["data"] as? Data, custom)
    }
    func testUnbackedSlotUsesValidatedRootFileBeforeDefaults() {
        let bytes = Data([1, 2, 3])
        let choice = CCEngine.recoverySource(backup: nil, loose: bytes)
        XCTAssertEqual(choice["source"] as? String, "loose")
        XCTAssertEqual(choice["data"] as? Data, bytes)
    }
    func testMissingOrRejectedRootFileKeepsBackup() {
        let bytes = Data([1, 2, 3])
        XCTAssertEqual(CCEngine.recoverySource(backup: bytes, loose: nil)["source"] as? String, "backup")
    }
    func testDefaultsOnlyWhenNeitherLocalSourceIsUsable() {
        XCTAssertEqual(CCEngine.recoverySource(backup: nil, loose: nil)["source"] as? String, "default")
        XCTAssertEqual(CCEngine.recoverySource(backup: Data(), loose: Data())["source"] as? String, "default")
    }
    func testTwelveSlotsKeepSingleLightCustomizationAndReuseOtherLooseFiles() {
        let custom = Data([99])
        let loose = Data([10])
        var choices: [String: Data] = [:]
        for path in allPaths {
            let backup: Data? = path == self.path("Blue-Light") ? custom : nil
            let result = CCEngine.recoverySource(backup: backup, loose: loose)
            choices[path] = result["data"] as? Data
        }
        XCTAssertEqual(choices.count, 12)
        XCTAssertEqual(choices[path("Blue-Light")], custom)
        XCTAssertEqual(choices[path("Blue-Dark")], loose)
        XCTAssertEqual(choices.values.filter { $0 == loose }.count, 11)
    }
}
