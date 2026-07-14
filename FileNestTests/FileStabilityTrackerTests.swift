import XCTest
@testable import FileNest

final class FileStabilityTrackerTests: XCTestCase {
    func testFileBecomesStableOnlyAfterMinimumDuration() {
        var tracker = FileStabilityTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = FileSnapshot(size: 100, modificationDate: start)

        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                        observedAt: start, minimumStableDuration: 2))
        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                        observedAt: start.addingTimeInterval(1), minimumStableDuration: 2))
        XCTAssertTrue(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                       observedAt: start.addingTimeInterval(2), minimumStableDuration: 2))
    }

    func testChangingFileRestartsStableDuration() {
        var tracker = FileStabilityTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let initial = FileSnapshot(size: 100, modificationDate: start)
        let changed = FileSnapshot(size: 200, modificationDate: start.addingTimeInterval(3))

        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: initial,
                                        observedAt: start, minimumStableDuration: 2))
        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: changed,
                                        observedAt: start.addingTimeInterval(3), minimumStableDuration: 2))
        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: changed,
                                        observedAt: start.addingTimeInterval(4), minimumStableDuration: 2))
        XCTAssertTrue(tracker.isStable(path: "/tmp/file.pdf", snapshot: changed,
                                       observedAt: start.addingTimeInterval(5), minimumStableDuration: 2))
    }

    func testMissingFileDropsPendingObservation() {
        var tracker = FileStabilityTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let snapshot = FileSnapshot(size: 100, modificationDate: start)

        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                        observedAt: start, minimumStableDuration: 2))
        tracker.retainExistingPaths([])
        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                        observedAt: start.addingTimeInterval(3), minimumStableDuration: 2))
    }
}
