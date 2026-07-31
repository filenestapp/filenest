import XCTest
@testable import FileNest

final class DocumentTreeNavigatorTests: XCTestCase {
    func testRouterKeepsSimpleLookupOnFastPath() {
        let file = makeFile()
        let seedHits = [
            Int64(7): [
                VectorSearchHit(
                    fileId: 7,
                    score: 0.9,
                    chunkText: "Revenue",
                    chunkIndex: 1,
                    parentIndex: 1
                ),
            ],
        ]

        XCTAssertFalse(DocumentTreeNavigator.shouldInspectTree(
            question: "2026 revenue",
            files: [file],
            seedHitsByFile: seedHits
        ))
        XCTAssertTrue(DocumentTreeNavigator.shouldInspectTree(
            question: "Compare revenue growth with the risk factors and explain the difference",
            files: [file],
            seedHitsByFile: seedHits
        ))
    }

    func testNavigationRequiresSeveralMeaningfulNaturalSections() {
        let file = makeFile()
        let short = (0..<3).map {
            DocumentTreeSection(file: file, chunk: makeChunk(index: $0))
        }
        let complete = (0..<5).map {
            DocumentTreeSection(file: file, chunk: makeChunk(index: $0))
        }

        XCTAssertFalse(DocumentTreeNavigator.supportsNavigation(sections: short))
        XCTAssertTrue(DocumentTreeNavigator.supportsNavigation(sections: complete))

        let flat = (0..<5).map {
            DocumentTreeSection(
                file: file,
                chunk: IndexedDocumentChunk(
                    index: $0,
                    text: "Flat evidence \($0)",
                    contextualText: "Flat evidence \($0)",
                    sectionPath: [],
                    pageStart: nil,
                    pageEnd: nil,
                    kind: .text,
                    parentIndex: $0,
                    parentText: "Flat evidence \($0)",
                    tokenCount: 4,
                    tokenizerProfile: TokenCounter.canonicalProfile,
                    tokenizerVersion: TokenCounter.canonicalVersion,
                    tokenCountAccuracy: .estimated
                )
            )
        }
        XCTAssertFalse(DocumentTreeNavigator.supportsNavigation(sections: flat))
    }

    func testModelSelectsPrimaryAndSupplementalSections() async {
        let file = makeFile()
        let sections = (0..<6).map {
            DocumentTreeSection(file: file, chunk: makeChunk(index: $0))
        }
        let provider = TreeNavigationProvider()
        let navigator = DocumentTreeNavigator()

        let outcome = await navigator.navigate(
            question: "Compare revenue with risk factors",
            files: [file],
            sections: sections,
            seedHitsByFile: [
                7: [
                    VectorSearchHit(
                        fileId: 7,
                        score: 0.91,
                        chunkText: "Seed",
                        chunkIndex: 1,
                        parentIndex: 1
                    ),
                ],
            ],
            provider: provider,
            promptVersion: "test-v1"
        )

        XCTAssertEqual(outcome.primarySections.map(\.nodeID), ["F7P1", "F7P2"])
        XCTAssertEqual(outcome.supplementalSections.map(\.nodeID), ["F7P4"])
        XCTAssertEqual(outcome.modelCalls, 2)
        XCTAssertFalse(outcome.usedDeterministicFallback)
    }

    func testNavigationCacheAvoidsRepeatedModelCalls() async {
        let file = makeFile()
        let sections = (0..<6).map {
            DocumentTreeSection(file: file, chunk: makeChunk(index: $0))
        }
        let provider = TreeNavigationProvider()
        let navigator = DocumentTreeNavigator()
        let arguments = (
            question: "Compare revenue with risk factors",
            files: [file],
            sections: sections,
            seedHitsByFile: [Int64: [VectorSearchHit]](),
            provider: provider as LLMProvider?,
            promptVersion: "test-v1"
        )

        _ = await navigator.navigate(
            question: arguments.question,
            files: arguments.files,
            sections: arguments.sections,
            seedHitsByFile: arguments.seedHitsByFile,
            provider: arguments.provider,
            promptVersion: arguments.promptVersion
        )
        let cached = await navigator.navigate(
            question: arguments.question,
            files: arguments.files,
            sections: arguments.sections,
            seedHitsByFile: arguments.seedHitsByFile,
            provider: arguments.provider,
            promptVersion: arguments.promptVersion
        )

        XCTAssertTrue(cached.cacheHit)
        XCTAssertEqual(cached.modelCalls, 0)
        XCTAssertEqual(provider.callCount, 2)
    }

    private func makeFile() -> FileRecord {
        FileRecord(
            id: 7,
            path: "/tmp/report.pdf",
            name: "report.pdf",
            ext: "pdf",
            size: 1_024,
            mtime: Date(timeIntervalSince1970: 1_000),
            category: FileCategory.documents.rawValue,
            sourceDir: "/tmp",
            indexedAt: Date(timeIntervalSince1970: 1_100),
            contentHash: "content-hash",
            title: "Annual report",
            contentText: nil,
            indexSignature: "index-v1"
        )
    }

    private func makeChunk(index: Int) -> IndexedDocumentChunk {
        let text = "Evidence for section \(index + 1)"
        return IndexedDocumentChunk(
            index: index,
            text: text,
            contextualText: "Report > Section \(index + 1)\n\(text)",
            sectionPath: ["Report", "Section \(index + 1)"],
            pageStart: index + 1,
            pageEnd: index + 1,
            kind: index == 2 ? .table : .text,
            parentIndex: index,
            parentText: text,
            tokenCount: TokenCounter.estimate(text).count,
            tokenizerProfile: TokenCounter.canonicalProfile,
            tokenizerVersion: TokenCounter.canonicalVersion,
            tokenCountAccuracy: .estimated
        )
    }

    private final class TreeNavigationProvider: LLMProvider, @unchecked Sendable {
        let name = "tree-navigation-stub"
        private let lock = NSLock()
        private var storedCallCount = 0

        var callCount: Int {
            lock.withLock { storedCallCount }
        }

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "unused"
        }

        func streamChat(
            _ messages: [ChatTurn],
            context: String?,
            responseFormat: LLMResponseFormat
        ) -> AsyncThrowingStream<String, Error> {
            let isSufficiency = messages.first?.content.contains("evidence-sufficiency") == true
            lock.withLock { storedCallCount += 1 }
            return AsyncThrowingStream { continuation in
                if isSufficiency {
                    continuation.yield(
                        #"{"sufficient":false,"additional_node_ids":["F7P4"],"missing_evidence":["risk qualification"]}"#
                    )
                } else {
                    continuation.yield(
                        #"{"selected_node_ids":["F7P1","F7P2"],"confidence":0.9,"requires_sufficiency_check":true}"#
                    )
                }
                continuation.finish()
            }
        }
    }
}
