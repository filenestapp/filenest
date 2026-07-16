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
        tracker.retainExistingPaths([], in: "/tmp")
        XCTAssertFalse(tracker.isStable(path: "/tmp/file.pdf", snapshot: snapshot,
                                        observedAt: start.addingTimeInterval(3), minimumStableDuration: 2))
    }

    func testChangingDirectoryTreeRestartsStableDuration() {
        var tracker = DirectoryStabilityTracker()
        let start = Date(timeIntervalSince1970: 1_000)
        let cloning = DirectorySnapshot(
            fileCount: 10,
            totalSize: 1_000,
            latestModificationDate: start,
            signature: "clone-in-progress"
        )
        let completed = DirectorySnapshot(
            fileCount: 20,
            totalSize: 2_000,
            latestModificationDate: start.addingTimeInterval(5),
            signature: "clone-complete"
        )

        XCTAssertFalse(tracker.isStable(path: "/tmp/repo", snapshot: cloning,
                                        observedAt: start, minimumStableDuration: 10))
        XCTAssertFalse(tracker.isStable(path: "/tmp/repo", snapshot: completed,
                                        observedAt: start.addingTimeInterval(5), minimumStableDuration: 10))
        XCTAssertFalse(tracker.isStable(path: "/tmp/repo", snapshot: completed,
                                        observedAt: start.addingTimeInterval(14), minimumStableDuration: 10))
        XCTAssertTrue(tracker.isStable(path: "/tmp/repo", snapshot: completed,
                                       observedAt: start.addingTimeInterval(15), minimumStableDuration: 10))
    }
}
