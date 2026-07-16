import Foundation

struct ChatContextPlan {
    let turns: [ChatTurn]
    let context: String
    let contextWindowTokens: Int
    let responseReserveTokens: Int
    let inputBudgetTokens: Int
    let estimatedInputTokens: Int
    let compressedTurnCount: Int
}

enum ChatContextPlanner {
    private static let turnOverheadTokens = 8

    static func plan(history: [ChatTurn],
                     context: String,
                     contextWindowTokens: Int,
                     thinkingEnabled: Bool) -> ChatContextPlan {
        let window = max(contextWindowTokens, 2_048)
        let responseReserve = responseReserveTokens(for: window, thinkingEnabled: thinkingEnabled)
        // Tokenization differs by provider/model; keep a 10% guard band beyond response capacity.
        let safetyReserve = max(128, window / 10)
        let inputBudget = max(512, window - responseReserve - safetyReserve)
        guard !history.isEmpty else {
            let fittedContext = truncated(context, maxTokens: max(inputBudget - turnOverheadTokens, 0))
            return makePlan(
                turns: [], context: fittedContext, window: window,
                responseReserve: responseReserve, inputBudget: inputBudget,
                compressedTurnCount: 0
            )
        }

        let latest = history[history.count - 1]
        let latestCost = turnCost(latest)
        if latestCost >= inputBudget {
            let fittedLatest = ChatTurn(
                role: latest.role,
                content: truncated(latest.content, maxTokens: max(inputBudget - turnOverheadTokens, 1))
            )
            return makePlan(
                turns: [fittedLatest], context: "", window: window,
                responseReserve: responseReserve, inputBudget: inputBudget,
                compressedTurnCount: history.count - 1
            )
        }

        let maximumContextCost = min(inputBudget * 65 / 100, inputBudget - latestCost)
        let fittedContext = fittedContext(context, maximumCost: maximumContextCost)
        let historyBudget = inputBudget - contextCost(fittedContext)
        let fullHistoryCost = history.reduce(0) { $0 + turnCost($1) }
        if fullHistoryCost <= historyBudget {
            return makePlan(
                turns: history, context: fittedContext, window: window,
                responseReserve: responseReserve, inputBudget: inputBudget,
                compressedTurnCount: 0
            )
        }

        let maximumSummaryCost = min(2_056, max(200, historyBudget / 4))
        let summaryCostBudget = min(maximumSummaryCost, max(historyBudget - latestCost, 0))
        let recentBudget = historyBudget - summaryCostBudget
        var recentReversed = [ChatTurn]()
        var recentCost = 0
        for turn in history.reversed() {
            let cost = turnCost(turn)
            guard recentCost + cost <= recentBudget else { break }
            recentReversed.append(turn)
            recentCost += cost
        }
        if recentReversed.isEmpty {
            recentReversed = [latest]
        }

        var recent = Array(recentReversed.reversed())
        var firstRecentIndex = history.count - recent.count
        if firstRecentIndex > 0, recent.first?.role == .assistant, recent.count > 1 {
            recent.removeFirst()
            firstRecentIndex += 1
        }
        let omitted = Array(history.prefix(firstRecentIndex))
        var plannedTurns = Array(recent)
        if !omitted.isEmpty, summaryCostBudget > turnOverheadTokens {
            let summary = compressedSummary(
                omitted,
                maxTokens: summaryCostBudget - turnOverheadTokens
            )
            if !summary.isEmpty {
                plannedTurns.insert(ChatTurn(role: .system, content: summary), at: 0)
            }
        }

        return makePlan(
            turns: plannedTurns, context: fittedContext, window: window,
            responseReserve: responseReserve, inputBudget: inputBudget,
            compressedTurnCount: omitted.count
        )
    }

    private static func responseReserveTokens(for window: Int,
                                              thinkingEnabled: Bool) -> Int {
        let base = max(512, min(4_096, window / 4))
        return thinkingEnabled ? max(base, min(2_048, window / 3)) : base
    }

    private static func makePlan(turns: [ChatTurn],
                                 context: String,
                                 window: Int,
                                 responseReserve: Int,
                                 inputBudget: Int,
                                 compressedTurnCount: Int) -> ChatContextPlan {
        ChatContextPlan(
            turns: turns,
            context: context,
            contextWindowTokens: window,
            responseReserveTokens: responseReserve,
            inputBudgetTokens: inputBudget,
            estimatedInputTokens: contextCost(context) + turns.reduce(0) { $0 + turnCost($1) },
            compressedTurnCount: compressedTurnCount
        )
    }

    private static func fittedContext(_ context: String, maximumCost: Int) -> String {
        guard maximumCost > turnOverheadTokens else { return "" }
        return truncated(context, maxTokens: maximumCost - turnOverheadTokens)
    }

    private static func turnCost(_ turn: ChatTurn) -> Int {
        ChatService.estimatedTokens(in: turn.content) + turnOverheadTokens
    }

    private static func contextCost(_ context: String) -> Int {
        context.isEmpty ? 0 : ChatService.estimatedTokens(in: context) + turnOverheadTokens
    }

    private static func compressedSummary(_ turns: [ChatTurn], maxTokens: Int) -> String {
        guard maxTokens > 32, !turns.isEmpty else { return "" }
        let header = "Earlier conversation (automatically compressed; recent messages take precedence):"
        let headerTokens = ChatService.estimatedTokens(in: header)
        guard headerTokens < maxTokens else { return truncated(header, maxTokens: maxTokens) }

        var indexes = [0]
        indexes.append(contentsOf: turns.indices.suffix(7))
        var seen = Set<Int>()
        indexes = indexes.filter { seen.insert($0).inserted }.sorted()
        let remaining = max(maxTokens - headerTokens, 1)
        let perTurn = max(12, remaining / max(indexes.count, 1))
        let lines = indexes.map { index -> String in
            let turn = turns[index]
            let role = turn.role == .user ? "User" : turn.role == .assistant ? "Assistant" : "System"
            let compact = turn.content
                .replacingOccurrences(of: "\n", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return "- \(role): \(truncated(compact, maxTokens: perTurn))"
        }
        return truncated(([header] + lines).joined(separator: "\n"), maxTokens: maxTokens)
    }

    private static func truncated(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        guard ChatService.estimatedTokens(in: text) > maxTokens else { return text }
        let characters = Array(text)
        let marker = " …"
        let contentBudget = max(maxTokens - ChatService.estimatedTokens(in: marker), 1)
        var lower = 0
        var upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if ChatService.estimatedTokens(in: String(characters.prefix(middle))) <= contentBudget {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        return String(characters.prefix(lower)).trimmingCharacters(in: .whitespacesAndNewlines) + marker
    }
}

enum ChatModelContextSource: Hashable {
    case ollama(host: String, model: String, memoryGB: Int)
    case cloud(format: String, model: String)
    case fallback
}

enum ChatModelContextWindowCatalog {
    static let fallbackTokens = 612_000

    static func cloudContextWindow(model: String, format: String) -> Int {
        let name = model.lowercased()
        if format == AppSettings.CloudAPIFormat.anthropic.rawValue || name.contains("claude") {
            return 200_000
        }
        if name.contains("gpt-4.1") { return 1_047_576 }
        if name.contains("gpt-5") { return 400_000 }
        if name.contains("gpt-4o") { return 128_000 }
        if name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4") { return 200_000 }
        if name.contains("gpt-4-turbo") { return 128_000 }
        if name.contains("gpt-3.5") { return 16_385 }
        return fallbackTokens
    }

    static func ollamaDefaultContextWindow(memoryGB: Int) -> Int {
        if memoryGB >= 48 { return 262_144 }
        if memoryGB >= 24 { return 32_768 }
        return 4_096
    }
}

actor ChatModelContextWindowResolver {
    private let session: URLSession
    private var cache: [ChatModelContextSource: Int] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ source: ChatModelContextSource, overrideTokens: Int? = nil) async -> Int {
        if let overrideTokens, overrideTokens > 0 {
            return max(overrideTokens, 2_048)
        }
        if let cached = cache[source] { return cached }
        let value: Int
        switch source {
        case let .ollama(host, model, memoryGB):
            let defaultWindow = ChatModelContextWindowCatalog.ollamaDefaultContextWindow(memoryGB: memoryGB)
            if let details = await OllamaModelMetadataCache.shared.details(host: host, model: model),
               let contextLength = details.contextLength {
                value = details.contextLengthIsExplicit
                    ? contextLength
                    : min(contextLength, defaultWindow)
            } else if let running = await runningContextWindow(host: host, model: model) {
                value = running
            } else if let configured = await modelContextWindow(host: host, model: model) {
                value = configured.isExplicit ? configured.tokens : min(configured.tokens, defaultWindow)
            } else {
                value = defaultWindow
            }
        case let .cloud(format, model):
            value = ChatModelContextWindowCatalog.cloudContextWindow(model: model, format: format)
        case .fallback:
            value = ChatModelContextWindowCatalog.fallbackTokens
        }
        cache[source] = max(value, 2_048)
        return max(value, 2_048)
    }

    private func runningContextWindow(host: String, model: String) async -> Int? {
        guard let url = endpoint(host: host, path: "api/ps") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return nil }
        for item in models {
            let name = (item["name"] as? String) ?? (item["model"] as? String) ?? ""
            if OllamaServiceManager.modelNamesMatch(name, model),
               let value = (item["context_length"] as? NSNumber)?.intValue,
               value > 0 {
                return value
            }
        }
        return nil
    }

    private func modelContextWindow(host: String,
                                    model: String) async -> (tokens: Int, isExplicit: Bool)? {
        guard let url = endpoint(host: host, path: "api/show") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let details = OllamaModelMetadataParser.details(from: data),
              let contextLength = details.contextLength else { return nil }
        await OllamaModelMetadataCache.shared.store(details, host: host, model: model)
        return (contextLength, details.contextLengthIsExplicit)
    }

    private func endpoint(host: String, path: String) -> URL? {
        let base = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(path)")
    }

}
