import XCTest
@testable import FileNest

final class FileContentHasherTests: XCTestCase {
    func testSHA256UsesFileContents() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello".utf8).write(to: url)

        XCTAssertEqual(
            try FileContentHasher.sha256(of: url),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }
}
