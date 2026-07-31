import CryptoKit
import Foundation

struct DocumentTreeSection: Equatable, Sendable {
    let nodeID: String
    let fileID: Int64
    let fileName: String
    let parentIndex: Int
    let text: String
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind

    init(file: FileRecord, chunk: IndexedDocumentChunk) {
        let fileID = file.id ?? 0
        let parentIndex = chunk.parentIndex ?? chunk.index
        nodeID = "F\(fileID)P\(parentIndex)"
        self.fileID = fileID
        fileName = file.name
        self.parentIndex = parentIndex
        text = chunk.parentText ?? chunk.text
        sectionPath = chunk.sectionPath
        pageStart = chunk.pageStart
        pageEnd = chunk.pageEnd
        kind = chunk.kind
    }

    var title: String {
        if let title = sectionPath.last?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let pageStart {
            return "Page \(pageStart)"
        }
        return "Section \(parentIndex + 1)"
    }

    var pathLabel: String {
        sectionPath.isEmpty ? title : sectionPath.joined(separator: " > ")
    }

    var pageLabel: String {
        guard let pageStart else { return "unknown" }
        guard let pageEnd, pageEnd != pageStart else { return "\(pageStart)" }
        return "\(pageStart)-\(pageEnd)"
    }

    func vectorHit(score: Float) -> VectorSearchHit {
        VectorSearchHit(
            fileId: fileID,
            score: score,
            chunkText: text,
            chunkIndex: parentIndex,
            sectionPath: sectionPath,
            pageStart: pageStart,
            pageEnd: pageEnd,
            kind: kind,
            parentIndex: parentIndex,
            parentText: text
        )
    }
}

struct DocumentTreeNavigationOutcome: Equatable, Sendable {
    let primarySections: [DocumentTreeSection]
    let supplementalSections: [DocumentTreeSection]
    let cacheHit: Bool
    let usedDeterministicFallback: Bool
    let modelCalls: Int
    let candidateCount: Int
    let durationMilliseconds: Int

    var allSections: [DocumentTreeSection] {
        primarySections + supplementalSections
    }
}

private struct CachedDocumentTreeNavigation: Sendable {
    let createdAt: Date
    let primaryNodeIDs: [String]
    let supplementalNodeIDs: [String]
    let usedDeterministicFallback: Bool
}

private actor DocumentTreeNavigationCache {
    private let timeToLive: TimeInterval
    private let capacity: Int
    private var entries = [String: CachedDocumentTreeNavigation]()

    init(timeToLive: TimeInterval = 15 * 60, capacity: Int = 64) {
        self.timeToLive = timeToLive
        self.capacity = capacity
    }

    func value(for key: String, now: Date = Date()) -> CachedDocumentTreeNavigation? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.createdAt) <= timeToLive else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    func insert(_ value: CachedDocumentTreeNavigation, for key: String) {
        entries[key] = value
        guard entries.count > capacity,
              let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key else {
            return
        }
        entries.removeValue(forKey: oldest)
    }
}

final class DocumentTreeNavigator {
    private static let reasoningSignals = [
        "compare", "comparison", "difference", "different", "across",
        "relationship", "why", "reason", "rationale", "explain", "impact",
        "risk", "exception", "limitation", "requirement", "evidence",
        "summarize", "synthesize", "overview", "key findings",
        "\u{6BD4}\u{8F83}", "\u{5BF9}\u{6BD4}", "\u{5DEE}\u{5F02}",
        "\u{533A}\u{522B}", "\u{4E4B}\u{95F4}",
        "\u{4E3A}\u{4EC0}\u{4E48}", "\u{539F}\u{56E0}",
        "\u{89E3}\u{91CA}", "\u{5F71}\u{54CD}", "\u{98CE}\u{9669}",
        "\u{4F8B}\u{5916}", "\u{9650}\u{5236}", "\u{6761}\u{4EF6}",
        "\u{4F9D}\u{636E}", "\u{603B}\u{7ED3}", "\u{7EFC}\u{5408}",
        "\u{6982}\u{8FF0}", "\u{4E3B}\u{8981}\u{7ED3}\u{8BBA}",
    ]

    private static let crossSectionSignals = [
        "compare", "comparison", "difference", "across", "relationship",
        "summarize", "synthesize", "overview", "key findings",
        "\u{6BD4}\u{8F83}", "\u{5BF9}\u{6BD4}", "\u{5DEE}\u{5F02}",
        "\u{533A}\u{522B}", "\u{7EFC}\u{5408}", "\u{603B}\u{7ED3}",
        "\u{6982}\u{8FF0}", "\u{4E3B}\u{8981}\u{7ED3}\u{8BBA}",
    ]

    private struct SelectionPayload: Decodable {
        let selectedNodeIDs: [String]
        let confidence: Double
        let requiresSufficiencyCheck: Bool?

        enum CodingKeys: String, CodingKey {
            case selectedNodeIDs = "selected_node_ids"
            case confidence
            case requiresSufficiencyCheck = "requires_sufficiency_check"
        }
    }

    private struct SufficiencyPayload: Decodable {
        let sufficient: Bool
        let additionalNodeIDs: [String]

        enum CodingKeys: String, CodingKey {
            case sufficient
            case additionalNodeIDs = "additional_node_ids"
        }
    }

    private let cache = DocumentTreeNavigationCache()

    static func shouldInspectTree(
        question: String,
        files: [FileRecord],
        seedHitsByFile: [Int64: [VectorSearchHit]]
    ) -> Bool {
        let eligibleExtensions: Set<String> = [
            "pdf", "doc", "docx", "pages", "ppt", "pptx", "key",
            "rtf", "md", "markdown", "html", "htm", "txt",
        ]
        guard files.contains(where: {
            !$0.isDirectory
                && $0.indexedAt != nil
                && eligibleExtensions.contains($0.ext.lowercased())
        }) else {
            return false
        }

        let normalized = question.lowercased()
        if reasoningSignals.contains(where: normalized.contains) {
            return true
        }

        let estimatedTokens = TokenCounter.estimate(question).count
        if estimatedTokens >= 24 {
            return true
        }

        let distinctSeedParents = Set(seedHitsByFile.values.flatMap { hits in
            hits.compactMap { hit in
                hit.parentIndex.map { "\(hit.fileId):\($0)" }
            }
        }).count
        return estimatedTokens >= 10 && distinctSeedParents >= 3
    }

    static func supportsNavigation(sections: [DocumentTreeSection]) -> Bool {
        guard sections.count >= 4 else { return false }
        let meaningfulPaths = Set(sections.compactMap { section -> String? in
            let path = section.sectionPath
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " > ")
            return path.isEmpty ? nil : path.lowercased()
        })
        return meaningfulPaths.count >= 3
    }

    func navigate(
        question: String,
        files: [FileRecord],
        sections: [DocumentTreeSection],
        seedHitsByFile: [Int64: [VectorSearchHit]],
        provider: LLMProvider?,
        promptVersion: String
    ) async -> DocumentTreeNavigationOutcome {
        let startedAt = Date()
        let candidates = Self.boundedCandidates(
            sections,
            question: question,
            seedHitsByFile: seedHitsByFile
        )
        let sectionByID = candidates.reduce(into: [String: DocumentTreeSection]()) {
            if $0[$1.nodeID] == nil {
                $0[$1.nodeID] = $1
            }
        }
        let cacheKey = Self.cacheKey(
            question: question,
            files: files,
            candidates: candidates,
            providerName: provider?.name ?? "deterministic",
            promptVersion: promptVersion
        )
        if let cached = await cache.value(for: cacheKey) {
            let primary = cached.primaryNodeIDs.compactMap { sectionByID[$0] }
            let supplemental = cached.supplementalNodeIDs.compactMap { sectionByID[$0] }
            if !primary.isEmpty {
                return DocumentTreeNavigationOutcome(
                    primarySections: primary,
                    supplementalSections: supplemental,
                    cacheHit: true,
                    usedDeterministicFallback: cached.usedDeterministicFallback,
                    modelCalls: 0,
                    candidateCount: candidates.count,
                    durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
                )
            }
        }

        let fallback = Self.deterministicSelection(
            from: candidates,
            question: question,
            seedHitsByFile: seedHitsByFile,
            limit: 4
        )
        var primary = fallback
        var supplemental = [DocumentTreeSection]()
        var usedFallback = provider == nil
        var modelCalls = 0
        var selectionConfidence = 0.0
        var requestedSufficiencyCheck = false

        if let provider {
            do {
                let response = try await LongDocumentStructuredStreamCollector.collect(
                    provider.streamChat(
                        [
                            ChatTurn(
                                role: .system,
                                content: PromptCatalog.TreeNavigation.selection
                            ),
                            ChatTurn(
                                role: .user,
                                content: Self.selectionInput(
                                    question: question,
                                    candidates: candidates
                                )
                            ),
                        ],
                        context: nil,
                        responseFormat: .jsonObject
                    ),
                    totalTimeout: 20,
                    maximumOutputTokens: 700
                )
                modelCalls += 1
                if let payload = Self.decode(SelectionPayload.self, from: response) {
                    let selected = Self.validSections(
                        ids: payload.selectedNodeIDs,
                        sectionByID: sectionByID,
                        excluding: [],
                        limit: 6
                    )
                    if !selected.isEmpty {
                        primary = selected
                        selectionConfidence = min(max(payload.confidence, 0), 1)
                        requestedSufficiencyCheck = payload.requiresSufficiencyCheck ?? false
                        usedFallback = false
                    } else {
                        usedFallback = true
                    }
                } else {
                    usedFallback = true
                }
            } catch {
                usedFallback = true
                if !Task.isCancelled {
                    AppLogService.shared.write(
                        "Document tree selection fell back to deterministic ranking",
                        category: .searchPerformance,
                        level: .info,
                        metadata: [
                            "error": error.localizedDescription,
                            "provider": provider.name,
                        ]
                    )
                }
            }
        }

        let shouldCheckSufficiency = provider != nil
            && !usedFallback
            && (
                requestedSufficiencyCheck
                    || selectionConfidence < 0.75
                    || Self.requiresCrossSectionCoverage(question)
            )
        if shouldCheckSufficiency, let provider {
            do {
                let response = try await LongDocumentStructuredStreamCollector.collect(
                    provider.streamChat(
                        [
                            ChatTurn(
                                role: .system,
                                content: PromptCatalog.TreeNavigation.sufficiency
                            ),
                            ChatTurn(
                                role: .user,
                                content: Self.sufficiencyInput(
                                    question: question,
                                    candidates: candidates,
                                    primary: primary
                                )
                            ),
                        ],
                        context: nil,
                        responseFormat: .jsonObject
                    ),
                    totalTimeout: 15,
                    maximumOutputTokens: 400
                )
                modelCalls += 1
                if let payload = Self.decode(SufficiencyPayload.self, from: response),
                   !payload.sufficient {
                    supplemental = Self.validSections(
                        ids: payload.additionalNodeIDs,
                        sectionByID: sectionByID,
                        excluding: Set(primary.map(\.nodeID)),
                        limit: 3
                    )
                }
            } catch {
                if !Task.isCancelled {
                    AppLogService.shared.write(
                        "Document tree sufficiency check was skipped",
                        category: .searchPerformance,
                        level: .info,
                        metadata: [
                            "error": error.localizedDescription,
                            "provider": provider.name,
                        ]
                    )
                }
            }
        }

        if provider != nil, !usedFallback {
            await cache.insert(
                CachedDocumentTreeNavigation(
                    createdAt: Date(),
                    primaryNodeIDs: primary.map(\.nodeID),
                    supplementalNodeIDs: supplemental.map(\.nodeID),
                    usedDeterministicFallback: false
                ),
                for: cacheKey
            )
        }
        return DocumentTreeNavigationOutcome(
            primarySections: primary,
            supplementalSections: supplemental,
            cacheHit: false,
            usedDeterministicFallback: usedFallback,
            modelCalls: modelCalls,
            candidateCount: candidates.count,
            durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
        )
    }

    static func requiresCrossSectionCoverage(_ question: String) -> Bool {
        let normalized = question.lowercased()
        return crossSectionSignals.contains(where: normalized.contains)
    }

    private static func boundedCandidates(
        _ sections: [DocumentTreeSection],
        question: String,
        seedHitsByFile: [Int64: [VectorSearchHit]],
        limit: Int = 72
    ) -> [DocumentTreeSection] {
        guard sections.count > limit else {
            return sections.sorted(by: sectionOrder)
        }

        let seedKeys = Set(seedHitsByFile.values.flatMap { hits in
            hits.compactMap { hit -> String? in
                guard let parentIndex = hit.parentIndex ?? hit.chunkIndex else { return nil }
                return "F\(hit.fileId)P\(parentIndex)"
            }
        })
        let queryTerms = searchTerms(question)
        var chosen = [DocumentTreeSection]()
        var chosenIDs = Set<String>()

        func append(_ section: DocumentTreeSection) {
            guard chosen.count < limit, chosenIDs.insert(section.nodeID).inserted else { return }
            chosen.append(section)
        }

        for section in sections where seedKeys.contains(section.nodeID) {
            append(section)
        }
        for section in sections where queryTerms.contains(where: {
            section.pathLabel.localizedCaseInsensitiveContains($0)
        }) {
            append(section)
        }

        let grouped = Dictionary(grouping: sections, by: \.fileID)
        for fileSections in grouped.values {
            for section in fileSections.sorted(by: sectionOrder).prefix(12) {
                append(section)
            }
        }

        let remaining = sections
            .filter { !chosenIDs.contains($0.nodeID) }
            .sorted(by: sectionOrder)
        let slots = max(0, limit - chosen.count)
        if slots > 0, !remaining.isEmpty {
            let stride = max(1, remaining.count / slots)
            var index = 0
            while chosen.count < limit, index < remaining.count {
                append(remaining[index])
                index += stride
            }
        }
        return chosen.sorted(by: sectionOrder)
    }

    private static func deterministicSelection(
        from candidates: [DocumentTreeSection],
        question: String,
        seedHitsByFile: [Int64: [VectorSearchHit]],
        limit: Int
    ) -> [DocumentTreeSection] {
        var seedRanks = [String: Int]()
        for hits in seedHitsByFile.values {
            for (rank, hit) in hits.enumerated() {
                guard let parentIndex = hit.parentIndex ?? hit.chunkIndex else { continue }
                let nodeID = "F\(hit.fileId)P\(parentIndex)"
                seedRanks[nodeID] = min(seedRanks[nodeID] ?? rank, rank)
            }
        }
        let queryTerms = searchTerms(question)
        return Array(candidates.sorted { lhs, rhs in
            func score(_ section: DocumentTreeSection) -> Double {
                var value = 0.0
                if let rank = seedRanks[section.nodeID] {
                    value += 100 - Double(min(rank, 50))
                }
                let searchable = (section.pathLabel + "\n" + String(section.text.prefix(500))).lowercased()
                value += Double(queryTerms.filter(searchable.contains).count) * 8
                if section.kind == .table { value += 1 }
                return value
            }
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            return lhsScore == rhsScore ? sectionOrder(lhs, rhs) : lhsScore > rhsScore
        }.prefix(max(1, limit)))
    }

    private static func selectionInput(
        question: String,
        candidates: [DocumentTreeSection]
    ) -> String {
        """
        USER QUESTION:
        \(question)

        DOCUMENT OUTLINE:
        \(outline(candidates))
        """
    }

    private static func sufficiencyInput(
        question: String,
        candidates: [DocumentTreeSection],
        primary: [DocumentTreeSection]
    ) -> String {
        var remainingCharacters = 10_000
        let evidence = primary.compactMap { section -> String? in
            guard remainingCharacters > 0 else { return nil }
            let excerpt = compact(section.text, limit: min(2_000, remainingCharacters))
            remainingCharacters -= excerpt.count
            return "[\(section.nodeID)] \(section.pathLabel), pages \(section.pageLabel)\n\(excerpt)"
        }.joined(separator: "\n\n")
        return """
        USER QUESTION:
        \(question)

        SELECTED EVIDENCE:
        \(evidence)

        AVAILABLE DOCUMENT OUTLINE:
        \(outline(candidates))
        """
    }

    private static func outline(_ candidates: [DocumentTreeSection]) -> String {
        var lines = [String]()
        var usedCharacters = 0
        for section in candidates {
            let preview = compact(section.text, limit: 140)
                .replacingOccurrences(of: "\"", with: "'")
            let line = "[\(section.nodeID)] file=\"\(section.fileName)\" path=\"\(section.pathLabel)\" pages=\(section.pageLabel) kind=\(section.kind.rawValue) preview=\"\(preview)\""
            guard usedCharacters + line.count <= 16_000 else { break }
            lines.append(line)
            usedCharacters += line.count
        }
        return lines.joined(separator: "\n")
    }

    private static func validSections(
        ids: [String],
        sectionByID: [String: DocumentTreeSection],
        excluding: Set<String>,
        limit: Int
    ) -> [DocumentTreeSection] {
        var seen = excluding
        return Array(ids.compactMap { rawID -> DocumentTreeSection? in
            let nodeID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(nodeID).inserted else { return nil }
            return sectionByID[nodeID]
        }.prefix(limit))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from response: String) -> T? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func searchTerms(_ question: String) -> [String] {
        let normalized = ChatService.relevanceTerms(in: question)
        var seen = Set<String>()
        return normalized.filter { seen.insert($0).inserted }
    }

    private static func compact(_ text: String, limit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(0, limit))) + "…"
    }

    private static func cacheKey(
        question: String,
        files: [FileRecord],
        candidates: [DocumentTreeSection],
        providerName: String,
        promptVersion: String
    ) -> String {
        let fileSignature = files.compactMap { file -> String? in
            guard let id = file.id else { return nil }
            return [
                String(id),
                file.contentHash ?? "",
                file.indexSignature ?? "",
                String(file.mtime.timeIntervalSince1970),
            ].joined(separator: ":")
        }.joined(separator: "|")
        let nodeSignature = candidates.map {
            "\($0.nodeID):\($0.pathLabel):\($0.pageLabel)"
        }.joined(separator: "|")
        let source = [
            promptVersion,
            providerName,
            question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            fileSignature,
            nodeSignature,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(source.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func sectionOrder(
        _ lhs: DocumentTreeSection,
        _ rhs: DocumentTreeSection
    ) -> Bool {
        if lhs.fileID != rhs.fileID { return lhs.fileID < rhs.fileID }
        if lhs.pageStart != rhs.pageStart {
            return (lhs.pageStart ?? Int.max) < (rhs.pageStart ?? Int.max)
        }
        return lhs.parentIndex < rhs.parentIndex
    }
}
