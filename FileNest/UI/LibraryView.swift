import AppKit
import SwiftUI

enum LibrarySortField: Equatable {
    case relevance
    case modified
    case size
}

enum LibrarySortDirection: Equatable {
    case ascending
    case descending
}

enum LibraryDateField: Equatable {
    case created
    case modified
}

struct LibraryDateRange: Equatable {
    var start: Date
    var end: Date
}

private enum LibraryFeedbackPresentation: Identifiable {
    case resultSet
    case singleFile(RAGSingleFileFeedbackContext)

    var id: String {
        switch self {
        case .resultSet:
            return "result-set"
        case let .singleFile(context):
            return "single-file:\(context.file.id ?? 0):\(context.file.path)"
        }
    }

    var singleFileContext: RAGSingleFileFeedbackContext? {
        guard case let .singleFile(context) = self else { return nil }
        return context
    }
}

struct LibraryFileQuery {
    static func sorted(
        _ files: [FileRecord],
        field: LibrarySortField,
        direction: LibrarySortDirection
    ) -> [FileRecord] {
        guard field != .relevance else { return files }
        return files.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch field {
            case .relevance:
                comparison = .orderedSame
            case .modified:
                comparison = lhs.mtime.compare(rhs.mtime)
            case .size:
                comparison = lhs.size == rhs.size
                    ? .orderedSame
                    : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
            }

            if comparison == .orderedSame {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return direction == .ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    static func filtered(
        _ files: [FileRecord],
        in selectedRange: LibraryDateRange?,
        dateField: LibraryDateField,
        creationDates: [String: Date],
        calendar: Calendar = .current
    ) -> [FileRecord] {
        guard let selectedRange else { return files }
        let lowerDate = min(selectedRange.start, selectedRange.end)
        let upperDate = max(selectedRange.start, selectedRange.end)
        let start = calendar.startOfDay(for: lowerDate)
        let upperStart = calendar.startOfDay(for: upperDate)
        guard let end = calendar.date(byAdding: .day, value: 1, to: upperStart) else { return files }

        return files.filter { file in
            let date: Date
            switch dateField {
            case .created:
                date = creationDates[file.path] ?? file.discoveredAt ?? file.addedAt
            case .modified:
                date = file.mtime
            }
            return date >= start && date < end
        }
    }

    static func sortedByConfidence(
        _ files: [FileRecord],
        matchesByPath: [String: LibrarySearchResult]
    ) -> [FileRecord] {
        files.sorted { lhs, rhs in
            let lhsMatch = matchesByPath[lhs.path]
            let rhsMatch = matchesByPath[rhs.path]
            let lhsConfidence = lhsMatch?.confidence ?? 0
            let rhsConfidence = rhsMatch?.confidence ?? 0
            if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
            let lhsScore = lhsMatch?.score ?? 0
            let rhsScore = rhsMatch?.score ?? 0
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Library search, category filtering, organization progress, and Finder actions.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let startDocumentChat: (FileRecord) -> Void
    @State private var searchText = FileNestEnvironment.isSearchPreview ? "renewal term" : ""
    @State private var selectedCategories = Set<FileCategory>()
    @AppStorage("librarySearchUsesAI") private var searchUsesAI = false
    @State private var sortField: LibrarySortField = .modified
    @State private var sortDirection: LibrarySortDirection = .descending
    @State private var dateField: LibraryDateField = .modified
    @State private var draftDateRange = LibraryDateRange(start: Date(), end: Date())
    @State private var selectedDateRange: LibraryDateRange?
    @State private var isCalendarPresented = false
    @State private var visibleLimit = 20
    @State private var isApplyingExternalSearch = false
    @State private var isSearchHistoryPresented = false
    @State private var derivedFiles: [FileRecord] = []
    @State private var derivedSearchMatchesByPath: [String: LibrarySearchResult] = [:]
    @State private var dismissedAutomaticProcessingItemIDs = Set<Int64>()
    @State private var feedbackPresentation: LibraryFeedbackPresentation?

    private var searchActivity: LibrarySearchActivity? {
        appState.librarySearchActivity
    }

    private var searchResults: [LibrarySearchResult]? {
        searchActivity?.results
    }

    private var isSearching: Bool {
        searchActivity?.isActive == true
    }

    private var activeSearchQuery: String {
        searchActivity?.query ?? ""
    }

    private var smartSearchEnabled: Bool {
        searchActivity?.mode == .smart
    }

    private var smartSearchPlan: SmartLibrarySearchPlan? {
        searchActivity?.smartPlan
    }

    private var smartSearchUsedAI: Bool {
        searchActivity?.usedAI == true
    }

    private var smartSearchIntent: String {
        searchActivity?.intent ?? ""
    }

    private var searchStage: LibrarySearchProgressStage? {
        searchActivity?.stage
    }

    private var isSearchCancelled: Bool {
        searchActivity?.wasCancelled == true
    }

    private var activeAutomaticProcessingItemIDs: Set<Int64> {
        Set(appState.activeAutomaticFileProcessingItems.map(\.id))
    }

    private var showsAutomaticProcessingStatus: Bool {
        !activeAutomaticProcessingItemIDs.subtracting(dismissedAutomaticProcessingItemIDs).isEmpty
    }

    private var sourceFiles: [FileRecord] {
        searchResults?.map(\.file) ?? availableFiles
    }

    private var availableFiles: [FileRecord] {
        FileNestEnvironment.isUIPreview ? UIShowcaseData.files : appState.files
    }

    private var searchMatchesByPath: [String: LibrarySearchResult] {
        derivedSearchMatchesByPath
    }

    private var filteredFiles: [FileRecord] {
        derivedFiles
    }

    private var visibleFiles: [FileRecord] {
        Array(derivedFiles.prefix(visibleLimit))
    }

    /// Filtering and sorting a large library is deliberately performed only when
    /// an input changes, never as a side effect of a SwiftUI body invalidation.
    private func rebuildDerivedFiles() {
        let matches = Dictionary(uniqueKeysWithValues: (searchResults ?? []).map { ($0.file.path, $0) })
        let files = searchResults?.map(\.file) ?? availableFiles
        let matchingFiles = files.filter { file in
            (selectedCategories.isEmpty || selectedCategories.contains(file.categoryEnum)) &&
            (searchText.isEmpty || FileNestEnvironment.isSearchPreview || searchResults != nil ||
             file.name.localizedCaseInsensitiveContains(searchText) ||
             (file.title ?? "").localizedCaseInsensitiveContains(searchText))
        }
        let dateFiltered = LibraryFileQuery.filtered(
            matchingFiles,
            in: selectedDateRange,
            dateField: dateField,
            creationDates: appState.fileCreationDates
        )
        if sortField == .relevance, searchResults != nil {
            derivedFiles = LibraryFileQuery.sortedByConfidence(
                dateFiltered,
                matchesByPath: matches
            )
        } else {
            derivedFiles = LibraryFileQuery.sorted(dateFiltered, field: sortField, direction: sortDirection)
        }
        derivedSearchMatchesByPath = matches
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Library",
                       subtitle: "Search and manage organized files; all indexes stay on this Mac.") {
                HStack(spacing: 10) {
                    if appState.organizationState == .running {
                        Button {
                            appState.pauseOrganization()
                        } label: {
                            Label("Pause Organization", systemImage: "pause.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                        Button(role: .destructive) {
                            appState.stopOrganization()
                        } label: {
                            Label("Stop Organization", systemImage: "stop.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                    } else if appState.organizationState == .paused {
                        Button {
                            appState.resumeOrganization()
                        } label: {
                            Label("Resume Organization", systemImage: "play.circle")
                        }
                        .buttonStyle(GradientButtonStyle())
                        Button(role: .destructive) {
                            appState.stopOrganization()
                        } label: {
                            Label("Stop Organization", systemImage: "stop.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                    } else {
                        OrganizeNowMenu {
                            Label("Organize Now", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(GradientButtonStyle())

                        Button {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "duplicates")
                        } label: {
                            Label(
                                appState.duplicateConfirmationFileCount > 0
                                    ? appState.settings.localizedFormat(
                                        "Review %d Duplicates",
                                        appState.duplicateConfirmationFileCount
                                    )
                                    : appState.settings.localized("Find Duplicates"),
                                systemImage: "doc.on.doc"
                            )
                        }
                        .buttonStyle(QuietButtonStyle())

                        Button {
                            if appState.hasReindexActivity {
                                appState.presentSettings(.reindexActivity)
                            } else {
                                appState.reindexAll()
                            }
                        } label: {
                            IndexingButtonLabel(defaultTitle: "Reindex", appState: appState)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(appState.reindexButtonsDisabled && !appState.hasReindexActivity)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }

            if appState.organizationState.isActive {
                ManualOrganizationQueueView(appState: appState, maximumItems: 10, showsControls: false)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(FileNestTheme.elevatedSurface)
                Divider()
            }
            if showsAutomaticProcessingStatus {
                AutomaticProcessingQueueView(
                    appState: appState,
                    maximumItems: 2,
                    onDismiss: {
                        dismissedAutomaticProcessingItemIDs.formUnion(activeAutomaticProcessingItemIDs)
                    }
                )
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(FileNestTheme.elevatedSurface)
                Divider()
            }
            libraryContent
        }
        .background(FileNestTheme.surface)
        .onAppear {
            appState.setLibrarySearchViewVisible(true)
            restoreActiveLibrarySearch()
            rebuildDerivedFiles()
            appState.refreshPersistedCreationDates()
            applyPendingLibrarySearch()
        }
        .onChange(of: appState.files) { _ in
            resetPagination()
            rebuildDerivedFiles()
            appState.refreshPersistedCreationDates()
        }
        .onChange(of: appState.fileCreationDates) { _ in
            if selectedDateRange != nil { rebuildDerivedFiles() }
        }
        .onChange(of: activeAutomaticProcessingItemIDs) { activeIDs in
            dismissedAutomaticProcessingItemIDs.formIntersection(activeIDs)
        }
        .onChange(of: searchText) { value in
            resetPagination()
            rebuildDerivedFiles()
            if !isApplyingExternalSearch { scheduleSearch(value) }
        }
        .onChange(of: searchResults) { _ in
            resetPagination()
            rebuildDerivedFiles()
        }
        .onChange(of: selectedCategories) { _ in
            resetPagination()
            rebuildDerivedFiles()
            guard !isApplyingExternalSearch else { return }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if searchUsesAI {
                    startSmartSearch(query: searchText, recordHistory: false)
                } else {
                    scheduleSearch(searchText)
                }
            }
        }
        .onChange(of: selectedDateRange) { _ in
            resetPagination()
            rebuildDerivedFiles()
        }
        .onChange(of: dateField) { _ in
            resetPagination()
            rebuildDerivedFiles()
        }
        .onChange(of: sortField) { _ in
            resetPagination()
            rebuildDerivedFiles()
        }
        .onChange(of: sortDirection) { _ in
            resetPagination()
            rebuildDerivedFiles()
        }
        .onChange(of: appState.librarySearchRequest?.id) { _ in
            applyPendingLibrarySearch()
        }
        .onDisappear {
            appState.setLibrarySearchViewVisible(false)
        }
        .sheet(item: $feedbackPresentation) { presentation in
            let singleFileContext = presentation.singleFileContext
            RAGFeedbackEditor(
                files: searchResults?.map(\.file) ?? [],
                initialFeedback: currentSearchFeedback,
                preselectedFileID: singleFileContext?.file.id,
                singleFileContext: singleFileContext
            ) { draft in
                guard let searchResults else { return }
                _ = appState.submitSearchFeedback(
                    query: activeSearchQuery,
                    isSmartSearch: smartSearchEnabled,
                    results: searchResults,
                    rating: draft.rating,
                    reason: draft.reason.isEmpty ? nil : draft.reason,
                    bestFileID: draft.bestFileID,
                    bestFileReason: draft.bestFileReason.isEmpty ? nil : draft.bestFileReason
                )
            }
            .environmentObject(appState)
            .fileNestEnvironment(appState.settings)
            .id(presentation.id)
        }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if isSearching {
                            if smartSearchEnabled {
                                AIThinkingActivitySymbol(size: 14)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        } else {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                        }
                        TextField("Search file names, titles, or contents…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .onSubmit { runSearch() }
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                                clearSearch()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 38)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(FileNestTheme.strongBorder, lineWidth: 1)
                    }

                    Toggle(isOn: $searchUsesAI) {
                        Label("Use AI", systemImage: "sparkles")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Use AI to analyze the query before retrieval")

                    Button(action: isSearching ? cancelCurrentSearch : runSearch) {
                        if isSearching {
                            Label("Stop Search", systemImage: "stop.circle")
                        } else {
                            Text("Search")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!isSearching && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(isSearching ? "Stop Search" : "Search")

                    Button {
                        appState.refreshLibrarySearchHistory()
                        isSearchHistoryPresented.toggle()
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(QuietButtonStyle())
                    .help("Search History")
                    .popover(isPresented: $isSearchHistoryPresented, arrowEdge: .bottom) {
                        LibrarySearchHistoryPopover(
                            entries: appState.librarySearchHistory,
                            restore: restoreSearchHistory,
                            delete: appState.deleteLibrarySearchHistory,
                            clear: appState.clearLibrarySearchHistory
                        )
                    }
                }

                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            FilterChip(title: "All", icon: nil, selected: selectedCategories.isEmpty) {
                                selectedCategories.removeAll()
                            }
                            ForEach(FileCategory.allCases) { item in
                                FilterChip(title: item.label, icon: item.icon, selected: selectedCategories.contains(item)) {
                                    if selectedCategories.contains(item) {
                                        selectedCategories.remove(item)
                                    } else {
                                        selectedCategories.insert(item)
                                    }
                                }
                            }
                        }
                    }

                    calendarFilterButton
                }

                if let searchResults {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .foregroundStyle(FileNestTheme.accent)
                        Text(appState.settings.localizedFormat("Found %d Related Files", searchResults.count))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(LocalizedStringKey(searchRankingDescription))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !isSearching, searchStage == nil {
                            Button {
                                feedbackPresentation = .resultSet
                            } label: {
                                Label(
                                    currentSearchFeedback == nil ? "Evaluate Results" : "Edit Evaluation",
                                    systemImage: currentSearchFeedback == nil
                                        ? "checkmark.bubble"
                                        : "checkmark.bubble.fill"
                                )
                            }
                            .buttonStyle(InlineActionButtonStyle())
                            .help("Evaluate result accuracy and mark the most accurate file")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))

                    if let searchStage {
                        HStack(spacing: 6) {
                            if searchStage == .analyzingQuery {
                                AIThinkingActivitySymbol(size: 12)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                            Text(LocalizedStringKey(searchStage.localizationKey))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.system(size: 10))
                    }

                    if smartSearchEnabled {
                        if let smartSearchPlan {
                            HStack(spacing: 7) {
                                Image(systemName: smartSearchUsedAI ? "sparkles" : "arrow.triangle.2.circlepath")
                                    .foregroundStyle(FileNestTheme.accent)
                                Text(LocalizedStringKey(smartSearchUsedAI ? "AI Search Plan" : "Local Fallback Plan"))
                                    .fontWeight(.semibold)
                                Text("·")
                                    .foregroundStyle(.tertiary)
                                Text(smartSearchPlanDescription(smartSearchPlan))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .font(.system(size: 10))
                        }
                    } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        smartSearchSuggestion
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            Divider()

            if isSearching, searchResults == nil {
                VStack(spacing: 10) {
                    if smartSearchEnabled {
                        AIThinkingActivitySymbol(size: 28)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                    }
                    Text(LocalizedStringKey(searchStage?.localizationKey ?? (
                        smartSearchEnabled
                            ? "AI is analyzing the query and running precise vector retrieval…"
                            : "Searching Keywords and Vector Index…"
                    )))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if smartSearchEnabled, !smartSearchIntent.isEmpty {
                        Text(smartSearchIntent)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.82))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSearchCancelled, searchResults == nil {
                VStack(spacing: 10) {
                    Image(systemName: "stop.circle")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Search Stopped")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The current search was stopped. Run it again when you are ready.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredFiles.isEmpty {
                EmptyLibraryView(searching: !searchText.isEmpty || !selectedCategories.isEmpty || selectedDateRange != nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        LibraryColumnHeader(
                            sortField: sortField,
                            sortDirection: sortDirection,
                            sort: updateSort
                        )
                        ForEach(visibleFiles) { file in
                            LibraryFileRow(
                                file: file,
                                searchMatch: searchMatchesByPath[file.path],
                                startDocumentChat: startDocumentChat,
                                markMostAccurate: searchResults == nil || isSearching || searchStage != nil ? nil : {
                                    beginSingleFileFeedback(for: file)
                                }
                            )
                            Divider().padding(.leading, LibraryTableLayout.nameColumnLeading)
                        }

                        if visibleFiles.count < filteredFiles.count {
                            LibraryPaginationSentinel(
                                visibleCount: visibleFiles.count,
                                totalCount: filteredFiles.count
                            )
                            .id(visibleLimit)
                            .onAppear { loadNextPage() }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
                }
                .fileNestOverlayScrollStyle()
            }
        }
    }

    private var calendarFilterButton: some View {
        Button {
            isCalendarPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selectedDateRange == nil ? "calendar" : "calendar.badge.checkmark")
                Text(calendarFilterTitle)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: selectedDateRange == nil ? .regular : .medium))
            .foregroundStyle(selectedDateRange == nil ? Color.secondary : FileNestTheme.accent)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(selectedDateRange == nil ? FileNestTheme.elevatedSurface.opacity(0.65) : FileNestTheme.selection)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(
                    selectedDateRange == nil ? FileNestTheme.border : FileNestTheme.accent.opacity(0.25),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .popover(isPresented: $isCalendarPresented, arrowEdge: .bottom) {
            LibraryCalendarPopover(
                dateField: $dateField,
                range: $draftDateRange,
                hasActiveFilter: selectedDateRange != nil,
                clear: {
                    selectedDateRange = nil
                    isCalendarPresented = false
                },
                apply: {
                    selectedDateRange = draftDateRange
                    isCalendarPresented = false
                }
            )
        }
    }

    private var calendarFilterTitle: String {
        guard let selectedDateRange else { return appState.settings.localized("Filter by Date") }
        let field = appState.settings.localized(dateField == .created ? "Created" : "Modified")
        let start = min(selectedDateRange.start, selectedDateRange.end)
        let end = max(selectedDateRange.start, selectedDateRange.end)
        let startLabel = start.formatted(date: .abbreviated, time: .omitted)
        guard !Calendar.current.isDate(start, inSameDayAs: end) else {
            return "\(field) · \(startLabel)"
        }
        let endLabel = end.formatted(date: .abbreviated, time: .omitted)
        return "\(field) · \(startLabel) – \(endLabel)"
    }

    private var searchRankingDescription: String {
        if smartSearchEnabled, smartSearchPlan != nil {
            return smartSearchUsedAI
                ? "AI Search Plan + Precise Vector and Metadata Filters"
                : "Local Parsing Fallback + Precise Vector and Metadata Filters"
        }
        return ChatService.requestedYears(in: searchText).isEmpty
            && ChatService.relativeDateIntent(in: searchText) == nil
            ? "File Keywords + Vector Semantic Ranking"
            : "Time Intent + File Keywords + Vector Semantic Ranking"
    }

    private var currentSearchFeedback: RAGFeedbackRecord? {
        let sourceKind = smartSearchEnabled
            ? RAGFeedbackSourceKind.smartSearch.rawValue
            : RAGFeedbackSourceKind.search.rawValue
        let normalizedQuery = activeSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return appState.ragFeedbackRecords.first {
            $0.sourceKind == sourceKind
                && ($0.searchQuery ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == normalizedQuery
        }
    }

    private var smartSearchSuggestion: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FileNestTheme.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Not finding what you need?")
                    .font(.system(size: 11, weight: .semibold))
                Text("Smart Search uses AI to understand your request more precisely and may take a little longer.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Try Smart Search") {
                runSmartSearch()
            }
            .buttonStyle(InlineActionButtonStyle())
            .help("AI analyzes the query and creates precise retrieval conditions")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(FileNestTheme.selection.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(FileNestTheme.accent.opacity(0.16), lineWidth: 1)
        }
    }

    private func smartSearchPlanDescription(_ plan: SmartLibrarySearchPlan) -> String {
        var parts = [String]()
        if !plan.semanticQuery.isEmpty {
            parts.append(appState.settings.localizedFormat("Semantic: %@", plan.semanticQuery))
        }
        let weightedKeywords = plan.weightedKeywords.map { keyword in
            "\(keyword.canonical) \(Int((keyword.normalizedWeight * 100).rounded()))%"
        }
        if !weightedKeywords.isEmpty {
            parts.append(appState.settings.localizedFormat("Keywords: %@", weightedKeywords.joined(separator: ", ")))
        } else if !plan.keywords.isEmpty {
            parts.append(appState.settings.localizedFormat("Keywords: %@", plan.keywords.joined(separator: ", ")))
        }
        if !plan.categories.isEmpty {
            let labels = plan.categories
                .sorted { $0.rawValue < $1.rawValue }
                .map { appState.settings.localized($0.label) }
                .joined(separator: ", ")
            parts.append(appState.settings.localizedFormat("Types: %@", labels))
        }
        if let interval = plan.dateInterval {
            let start = interval.start.formatted(date: .abbreviated, time: .omitted)
            let inclusiveEnd = Calendar.current.date(byAdding: .day, value: -1, to: interval.end)
                ?? interval.end
            let end = inclusiveEnd.formatted(date: .abbreviated, time: .omitted)
            parts.append(appState.settings.localizedFormat("Dates: %@ to %@", start, end))
        }
        if plan.sortNewestFirst { parts.append(appState.settings.localized("Newest First")) }
        return parts.joined(separator: " · ")
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        if searchUsesAI {
            startSmartSearch(query: query, recordHistory: true)
        } else {
            startSearch(query: query, debounceNanoseconds: 0, recordHistory: true)
        }
    }

    private func applyPendingLibrarySearch() {
        guard let request = appState.librarySearchRequest else { return }
        isApplyingExternalSearch = true
        searchText = request.query
        if searchUsesAI {
            startSmartSearch(query: request.query, recordHistory: true)
        } else {
            startSearch(query: request.query, debounceNanoseconds: 0, recordHistory: true)
        }
        appState.consumeLibrarySearchRequest(request.id)
        DispatchQueue.main.async { isApplyingExternalSearch = false }
    }

    private func runSmartSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searchUsesAI = true
        startSmartSearch(query: query, recordHistory: true)
    }

    private func scheduleSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        startSearch(query: query, debounceNanoseconds: 150_000_000, recordHistory: false)
    }

    private func startSearch(
        query: String,
        debounceNanoseconds: UInt64,
        recordHistory: Bool
    ) {
        sortField = .relevance
        sortDirection = .descending
        appState.startLibrarySearch(
            matching: query,
            mode: .standard,
            categories: selectedCategories,
            recordHistory: recordHistory,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func startSmartSearch(query: String, recordHistory: Bool) {
        sortField = .relevance
        sortDirection = .descending
        appState.startLibrarySearch(
            matching: query,
            mode: .smart,
            categories: selectedCategories,
            recordHistory: recordHistory
        )
    }

    private func restoreSearchHistory(_ entry: LibrarySearchHistoryEntry) {
        isSearchHistoryPresented = false
        isApplyingExternalSearch = true
        searchText = entry.query
        if entry.isSmartSearch {
            searchUsesAI = true
            startSmartSearch(query: entry.query, recordHistory: true)
        } else {
            searchUsesAI = false
            startSearch(query: entry.query, debounceNanoseconds: 0, recordHistory: true)
        }
        DispatchQueue.main.async { isApplyingExternalSearch = false }
    }

    private func clearSearch() {
        appState.clearLibrarySearch()
        sortField = .modified
        sortDirection = .descending
        resetPagination()
    }

    private func cancelCurrentSearch() {
        guard isSearching else { return }
        appState.cancelLibrarySearch()
    }

    private func restoreActiveLibrarySearch() {
        guard let activity = appState.librarySearchActivity else { return }
        isApplyingExternalSearch = true
        searchText = activity.query
        selectedCategories = activity.categories
        searchUsesAI = activity.mode == .smart
        sortField = .relevance
        sortDirection = .descending
        resetPagination()
        DispatchQueue.main.async { isApplyingExternalSearch = false }
    }

    private func updateSort(_ field: LibrarySortField) {
        if sortField == field {
            sortDirection = sortDirection == .descending ? .ascending : .descending
        } else {
            sortField = field
            sortDirection = .descending
        }
    }

    private func resetPagination() {
        visibleLimit = 20
    }

    private func loadNextPage() {
        guard visibleLimit < filteredFiles.count else { return }
        visibleLimit = min(visibleLimit + 20, filteredFiles.count)
    }

    private func beginSingleFileFeedback(for file: FileRecord) {
        guard let searchResults,
              let resultIndex = searchResults.firstIndex(where: {
                  $0.file.id == file.id && $0.file.path == file.path
              }) else {
            return
        }
        feedbackPresentation = .singleFile(
            RAGSingleFileFeedbackContext(
                file: file,
                rank: resultIndex + 1,
                confidence: searchResults[resultIndex].confidence
            )
        )
    }

}

private struct LibrarySearchHistoryPopover: View {
    let entries: [LibrarySearchHistoryEntry]
    let restore: (LibrarySearchHistoryEntry) -> Void
    let delete: (Int64) -> Void
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Search History")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !entries.isEmpty {
                    Button("Clear All", role: .destructive, action: clear)
                        .buttonStyle(InlineActionButtonStyle(tint: .red))
                }
            }
            .padding(14)

            Divider()

            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("No Search History")
                        .font(.system(size: 12, weight: .medium))
                    Text("Completed searches will appear here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                Button { restore(entry) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.isSmartSearch ? "sparkles" : "magnifyingglass")
                                            .foregroundStyle(FileNestTheme.accent)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(entry.query)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            HStack(spacing: 5) {
                                                Text(LocalizedStringKey(entry.isSmartSearch ? "Smart Search" : "Standard Search"))
                                                Text("·")
                                                Text("\(entry.resultCount)")
                                                Text(LocalizedStringKey("results"))
                                                Text("·")
                                                Text(entry.updatedAt, style: .relative)
                                                Text("·")
                                                if entry.hasValidCache {
                                                    Text("Cached")
                                                        .foregroundStyle(FileNestTheme.success)
                                                } else {
                                                    Text("Refresh Required")
                                                        .foregroundStyle(FileNestTheme.warning)
                                                }
                                            }
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button(role: .destructive) { delete(entry.id) } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .help("Delete Search History")
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                            if entry.id != entries.last?.id { Divider().padding(.leading, 42) }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 380)
    }
}

private struct FilterChip: View {
    let title: String
    let icon: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(LocalizedStringKey(title))
            }
            .font(.system(size: 11, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(selected ? FileNestTheme.selection : FileNestTheme.elevatedSurface.opacity(0.65))
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(selected ? FileNestTheme.accent.opacity(0.25) : FileNestTheme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

enum LibraryTableLayout {
    static let spacing: CGFloat = 14
    static let iconWidth: CGFloat = 38
    static let nameColumnLeading = iconWidth + spacing
    static let categoryWidth: CGFloat = 90
    static let sizeWidth: CGFloat = 82
    static let modifiedWidth: CGFloat = 150
    static let actionsWidth: CGFloat = 168
}

private struct LibraryColumnHeader: View {
    @EnvironmentObject private var appState: AppState
    let sortField: LibrarySortField
    let sortDirection: LibrarySortDirection
    let sort: (LibrarySortField) -> Void

    var body: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            Color.clear.frame(width: LibraryTableLayout.iconWidth)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            if appState.previewedFile == nil {
                Text("Category").frame(width: LibraryTableLayout.categoryWidth, alignment: .leading)
            }
            sortableHeader("Size", field: .size, width: LibraryTableLayout.sizeWidth)
            sortableHeader("Modified", field: .modified, width: LibraryTableLayout.modifiedWidth)
            Text("Actions").frame(width: LibraryTableLayout.actionsWidth, alignment: .center)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }

    private func sortableHeader(_ title: String, field: LibrarySortField, width: CGFloat) -> some View {
        Button {
            sort(field)
        } label: {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(title))
                if sortField == field {
                    Image(systemName: sortDirection == .descending ? "chevron.down" : "chevron.up")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FileNestTheme.accent)
                }
            }
            .frame(width: width, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help(sortDirection == .descending && sortField == field ? "Switch to Ascending" : "Switch to Descending")
        .accessibilityLabel(LocalizedStringKey(title))
    }
}

private struct LibraryFileRow: View {
    @EnvironmentObject private var appState: AppState
    let file: FileRecord
    let searchMatch: LibrarySearchResult?
    let startDocumentChat: (FileRecord) -> Void
    let markMostAccurate: (() -> Void)?
    @State private var isHovered = false
    @State private var isDeleting = false
    @State private var activeAlert: LibraryFileAlert?

    private var isSelected: Bool {
        guard let previewedFile = appState.previewedFile else { return false }
        if let id = file.id { return previewedFile.id == id }
        return previewedFile.path == file.path
    }

    var body: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            rowContent
            actionButtons
        }
        .font(.system(size: 11))
        .frame(minHeight: searchMatch?.evidence.isEmpty == false ? 82 : 66)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? FileNestTheme.contentSelection
                        : (isHovered ? FileNestTheme.contentHover : Color.clear)
                )
        }
        .contentShape(Rectangle())
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovered }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .confirmDelete:
                return Alert(
                    title: Text("Move to Trash?"),
                    message: Text(appState.settings.localizedFormat("Are you sure you want to move “%@” to the Trash?", file.name)),
                    primaryButton: .destructive(Text("Move to Trash"), action: moveToTrash),
                    secondaryButton: .cancel(Text("Cancel"))
                )
            case let .deleteFailed(message):
                return Alert(
                    title: Text("Could Not Move to Trash"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .contextMenu {
            Button("View File Details") { appState.toggleFilePreview(file) }
            if file.supportsFileChat(with: appState.settings) {
                Button("Chat with File") { startDocumentChat(file) }
            }
            if let markMostAccurate {
                Button("Mark as Most Accurate", action: markMostAccurate)
            }
            Button("Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            }
            Button("Show in Finder") { reveal(file) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                activeAlert = .confirmDelete
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            FileIconView(file: file, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if file.duplicateOfFileID != nil {
                        Text(appState.settings.localized("Duplicate"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FileNestTheme.warning)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(FileNestTheme.warning.opacity(0.12), in: Capsule())
                    }
                    if let searchMatch {
                        ConfidenceBadge(confidence: searchMatch.confidence)
                    }
                }
                Text(secondaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let searchMatch, !searchMatch.evidence.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(searchMatch.evidence.prefix(2), id: \.self) { evidence in
                            Text(evidenceLabel(evidence))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(FileNestTheme.accent)
                                .lineLimit(1)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(FileNestTheme.accent.opacity(0.10), in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if appState.previewedFile == nil {
                Text(LocalizedStringKey(file.categoryEnum.label))
                    .frame(width: LibraryTableLayout.categoryWidth, alignment: .leading)
            }
            Text(file.displaySize)
                .frame(width: LibraryTableLayout.sizeWidth, alignment: .leading)
            Text(file.mtime.formatted(date: .abbreviated, time: .shortened))
                .frame(width: LibraryTableLayout.modifiedWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.toggleFilePreview(file)
        }
        .help("Click to view file details")
        .pointingHandOnHover()
        .accessibilityAction(named: Text("View File Details")) {
            appState.toggleFilePreview(file)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if file.supportsFileChat(with: appState.settings) {
                LibraryActionButton(
                    systemName: "doc.text.magnifyingglass",
                    tint: FileNestTheme.accent,
                    title: "Chat with File"
                ) {
                    startDocumentChat(file)
                }
            } else {
                // Preserve the document-chat slot so Finder and Trash stay aligned
                // across rows for every file type.
                Color.clear
                    .frame(width: 36, height: 30)
                    .accessibilityHidden(true)
            }

            if let markMostAccurate {
                LibraryActionButton(
                    systemName: "checkmark.seal",
                    tint: FileNestTheme.accent,
                    title: "Mark as Most Accurate",
                    action: markMostAccurate
                )
            } else {
                Color.clear
                    .frame(width: 36, height: 30)
                    .accessibilityHidden(true)
            }

            LibraryActionButton(
                systemName: "folder",
                tint: FileNestTheme.accent,
                title: "Show in Finder"
            ) {
                reveal(file)
            }

            LibraryActionButton(
                systemName: isDeleting ? "hourglass" : "trash",
                tint: .red,
                title: "Move to Trash"
            ) {
                activeAlert = .confirmDelete
            }
            .disabled(isDeleting)
        }
        .frame(width: LibraryTableLayout.actionsWidth)
    }

    private var secondaryText: String {
        if let searchMatch, let snippet = searchMatch.snippet, !snippet.isEmpty {
            let section = searchMatch.sectionPath.joined(separator: " › ")
            let page: String
            if let start = searchMatch.pageStart {
                page = searchMatch.pageEnd.flatMap { $0 == start ? nil : $0 }
                    .map { "p.\(start)–\($0)" } ?? "p.\(start)"
            } else {
                page = ""
            }
            let location = [section, page].filter { !$0.isEmpty }.joined(separator: " · ")
            return location.isEmpty ? snippet : "\(location) · \(snippet)"
        }
        if let note = file.note, !note.isEmpty { return note }
        if let title = file.title, !title.isEmpty { return title }
        return file.displayPath
    }

    private func evidenceLabel(_ evidence: LibrarySearchEvidence) -> String {
        switch evidence.kind {
        case .exactPhrase:
            return appState.settings.localizedFormat("Exact phrase: %@", evidence.label)
        case .keyword:
            return appState.settings.localizedFormat("Matched: %@", evidence.label)
        case .semantic:
            return appState.settings.localizedFormat("Semantic match: %@", evidence.label)
        case .entity:
            return appState.settings.localized("Exact entity match")
        }
    }

    private func reveal(_ file: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    private func moveToTrash() {
        isDeleting = true
        Task {
            do {
                try await appState.moveFileToTrash(file)
            } catch {
                let message = appState.settings.localizedFormat(
                    "Could not move to Trash: %@",
                    error.localizedDescription
                )
                isDeleting = false
                activeAlert = .deleteFailed(message)
            }
        }
    }
}

struct ConfidenceBadge: View {
    @EnvironmentObject private var appState: AppState
    let confidence: Double

    private var style: ConfidenceBadgeStyle {
        ConfidenceBadgeStyle(confidence: confidence)
    }

    var body: some View {
        Text(appState.settings.localizedFormat("Confidence %d%%", confidencePercent))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(style.foreground)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(style.background, in: Capsule())
            .overlay {
                Capsule().stroke(style.foreground.opacity(0.16), lineWidth: 0.5)
            }
            .fixedSize()
            .accessibilityLabel(appState.settings.localizedFormat("Confidence %d%%", confidencePercent))
    }

    private var confidencePercent: Int {
        Int((min(max(confidence, 0), 1) * 100).rounded())
    }
}

private struct ConfidenceBadgeStyle {
    let foreground: Color
    let background: Color

    init(confidence: Double) {
        switch confidence {
        case 0.85...:
            foreground = FileNestTheme.success
            background = FileNestTheme.success.opacity(0.12)
        case 0.65..<0.85:
            foreground = FileNestTheme.accentBlue
            background = FileNestTheme.accentBlue.opacity(0.12)
        case 0.40..<0.65:
            foreground = FileNestTheme.warning
            background = FileNestTheme.warning.opacity(0.13)
        default:
            foreground = Color.red.opacity(0.88)
            background = Color.red.opacity(0.10)
        }
    }
}

private struct LibraryCalendarPopover: View {
    @Binding var dateField: LibraryDateField
    @Binding var range: LibraryDateRange
    let hasActiveFilter: Bool
    let clear: () -> Void
    let apply: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FileNestTheme.accent)
                    .frame(width: 32, height: 32)
                    .background(FileNestTheme.selection, in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse Files by Date")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Choose a created or modified date range")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Date Type", selection: $dateField) {
                Text("Created").tag(LibraryDateField.created)
                Text("Modified").tag(LibraryDateField.modified)
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                dateFieldView(title: "Start Date", date: $range.start)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                dateFieldView(title: "End Date", date: $range.end)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Ranges")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 7) {
                    quickRangeButton("Today", preset: .today)
                    quickRangeButton("Last 7 Days", preset: .lastSevenDays)
                    quickRangeButton("Last 30 Days", preset: .lastThirtyDays)
                    quickRangeButton("This Month", preset: .thisMonth)
                }
            }

            Label(rangeSummary, systemImage: "calendar.badge.checkmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FileNestTheme.accent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FileNestTheme.selection, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Clear Filter", action: clear)
                    .buttonStyle(InlineActionButtonStyle(tint: .secondary))
                    .disabled(!hasActiveFilter)
                Spacer()
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .tint(FileNestTheme.accentFill)
            }
            .controlSize(.small)
        }
        .padding(18)
        .frame(width: 390)
        .onChange(of: range.start) { start in
            if range.end < start { range.end = start }
        }
        .onChange(of: range.end) { end in
            if range.start > end { range.start = end }
        }
    }

    private func dateFieldView(title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }

    private func quickRangeButton(_ title: String, preset: DateRangePreset) -> some View {
        Button {
            applyPreset(preset)
        } label: {
            Text(LocalizedStringKey(title))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(FileNestTheme.elevatedSurface, in: Capsule())
                .overlay { Capsule().stroke(FileNestTheme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
    }

    private var rangeSummary: String {
        let start = min(range.start, range.end).formatted(date: .abbreviated, time: .omitted)
        let end = max(range.start, range.end).formatted(date: .abbreviated, time: .omitted)
        return appState.settings.localizedFormat("%@ to %@", start, end)
    }

    private func applyPreset(_ preset: DateRangePreset) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start: Date
        switch preset {
        case .today:
            start = today
        case .lastSevenDays:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .lastThirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .thisMonth:
            start = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        }
        range = LibraryDateRange(start: start, end: today)
    }
}

private enum DateRangePreset {
    case today
    case lastSevenDays
    case lastThirtyDays
    case thisMonth
}

private struct LibraryPaginationSentinel: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Scroll Down to Load More")
            Text("\(visibleCount)/\(totalCount)")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}

private enum LibraryFileAlert: Identifiable {
    case confirmDelete
    case deleteFailed(String)

    var id: String {
        switch self {
        case .confirmDelete: return "confirm-delete"
        case .deleteFailed: return "delete-failed"
        }
    }
}

struct LibraryActionButton: View {
    @Environment(\.isEnabled) private var isEnabled

    let systemName: String
    let tint: Color
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.45))
                .frame(width: 36, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered && isEnabled ? FileNestTheme.elevatedSurface : Color.clear)
                        .shadow(
                            color: isHovered && isEnabled ? Color.black.opacity(0.08) : .clear,
                            radius: 4,
                            y: 1
                        )
                }
                .scaleEffect(isHovered && isEnabled ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.1)) { isHovered = hovered }
        }
        .help(title)
        .accessibilityLabel(LocalizedStringKey(title))
    }
}

struct DuplicateFilesWindow: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedPaths = Set<String>()
    @State private var isTrashConfirmationPresented = false
    @State private var resultMessage: String?

    private var selectedCount: Int { selectedPaths.count }
    private var reclaimableBytes: Int64 {
        appState.duplicateFileGroups
            .flatMap(\.duplicateFiles)
            .filter { selectedPaths.contains($0.path) }
            .reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.settings.localized("Duplicate Files"))
                        .font(.system(size: 23, weight: .semibold))
                    Text(appState.settings.localized("Finds files with exactly the same content. Files are never removed until you confirm."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 24)
                if !appState.duplicateFileGroups.isEmpty {
                    Button {
                        Task { await appState.scanForDuplicateFiles() }
                    } label: {
                        Label(appState.settings.localized("Rescan"), systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isScanningForDuplicates)
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)

            Divider()
            HStack(spacing: 12) {
                if let resultMessage {
                    Text(resultMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let progress = appState.duplicateTrashProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.settings.localizedFormat(
                            "Moving duplicates to Trash… %d of %d",
                            progress.completedCount,
                            progress.totalCount
                        ))
                        .font(.system(size: 12, weight: .medium))
                        Text(progress.currentFileName ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    ProgressView(value: progress.fractionCompleted)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                } else if selectedCount > 0 {
                    Text(appState.settings.localizedFormat("%d selected · %@ recoverable", selectedCount, ByteCountFormatter.string(fromByteCount: reclaimableBytes, countStyle: .file)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if appState.duplicateFileGroups.isEmpty {
                    if !appState.isScanningForDuplicates {
                        Button {
                            Task { await appState.scanForDuplicateFiles() }
                        } label: {
                            Label(appState.settings.localized("Rescan"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(GradientButtonStyle())
                        .disabled(appState.isRemovingDuplicates)
                    }
                } else {
                    Button {
                        isTrashConfirmationPresented = true
                    } label: {
                        Label(
                            appState.settings.localizedFormat("Move %d Duplicates to Trash", selectedCount),
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(selectedCount == 0 || appState.isScanningForDuplicates || appState.isRemovingDuplicates)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 600)
        .background(FileNestTheme.surface)
        .onAppear {
            appState.loadKnownDuplicateFileGroups()
            selectedPaths = Set(appState.duplicateFileGroups.flatMap(\.duplicateFiles).map(\.path))
        }
        .onChange(of: appState.duplicateFileGroups) { groups in
            selectedPaths = Set(groups.flatMap(\.duplicateFiles).map(\.path))
            resultMessage = nil
        }
        .confirmationDialog(
            appState.settings.localized("Move selected duplicates to Trash?"),
            isPresented: $isTrashConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(
                appState.settings.localizedFormat("Move %d Duplicates to Trash", selectedCount),
                role: .destructive
            ) {
                Task {
                    let result = await appState.moveDuplicateFilesToTrash(paths: selectedPaths)
                    if result.failedFileNames.isEmpty {
                        resultMessage = appState.settings.localizedFormat("%d duplicate files moved to Trash", result.movedCount)
                    } else {
                        resultMessage = appState.settings.localizedFormat("Failed to move %d duplicate files to Trash", result.failedFileNames.count)
                    }
                }
            }
        } message: {
            Text(appState.settings.localized("The selected files will be moved to the macOS Trash. The kept original files are not changed."))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let progress = appState.duplicateScanProgress {
            VStack(spacing: 12) {
                ProgressView(value: progress.fractionCompleted)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 420)
                Text(appState.settings.localizedFormat("Scanning files for duplicates… %d of %d", progress.scannedCount, progress.totalCount))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else if appState.duplicateFileGroups.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                Text(appState.settings.localized("No duplicate files to review"))
                    .font(.system(size: 16, weight: .semibold))
                Text(appState.settings.localized("Start a scan to calculate SHA-256 hashes and look for exact copies."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(appState.duplicateFileGroups) { group in
                        DuplicateFileGroupCard(group: group, selectedPaths: $selectedPaths)
                    }
                }
                .padding(.vertical, 2)
            }
            .fileNestOverlayScrollStyle()
        }
    }
}

private struct DuplicateFileGroupCard: View {
    @EnvironmentObject private var appState: AppState
    let group: DuplicateFileGroup
    @Binding var selectedPaths: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label(
                    appState.settings.localizedFormat("%d exact copies", group.files.count),
                    systemImage: "doc.on.doc"
                )
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(appState.settings.localizedFormat("%@ recoverable", ByteCountFormatter.string(fromByteCount: group.reclaimableBytes, countStyle: .file)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            DuplicateFileRow(file: group.retainedFile, title: "Keep", isRetained: true, isSelected: .constant(true))
            ForEach(group.duplicateFiles) { file in
                DuplicateFileRow(
                    file: file,
                    title: "Duplicate copy",
                    isRetained: false,
                    isSelected: Binding(
                        get: { selectedPaths.contains(file.path) },
                        set: { selected in
                            if selected { selectedPaths.insert(file.path) }
                            else { selectedPaths.remove(file.path) }
                        }
                    )
                )
            }
        }
        .padding(14)
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }
}

private struct DuplicateFileRow: View {
    @EnvironmentObject private var appState: AppState
    let file: FileRecord
    let title: String
    let isRetained: Bool
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isRetained {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FileNestTheme.success)
                    .frame(width: 18)
            } else {
                Toggle("", isOn: $isSelected)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 18)
            }
            FileIconView(file: file, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(appState.settings.localized(title))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isRetained ? FileNestTheme.success : .secondary)
                    Text(file.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                Text(file.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct EmptyLibraryView: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: searching ? "doc.text.magnifyingglass" : "tray")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(FileNestTheme.accent.opacity(0.72))
            Text(LocalizedStringKey(searching ? "No Matching Files" : "No Indexed Files Yet"))
                .font(.system(size: 17, weight: .semibold))
            Text(LocalizedStringKey(
                searching ? "Try a different search term or category." : "Place files in a watched folder and FileNest will index them automatically."
            ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProgressSteps: View {
    var body: some View {
        HStack(spacing: 14) {
            ProgressStep(number: 1, title: "Discover Files", state: .complete)
            ProgressConnector(active: true)
            ProgressStep(number: 2, title: "Build Local Index", state: .active)
            ProgressConnector(active: false)
            ProgressStep(number: 3, title: "Move to Destination", state: .pending)
        }
    }
}

private struct ProgressConnector: View {
    let active: Bool
    var body: some View {
        Rectangle()
            .fill(active ? FileNestTheme.accent : FileNestTheme.border)
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .offset(y: -10)
    }
}

private struct ProgressStep: View {
    enum State { case complete, active, pending }
    let number: Int
    let title: String
    let state: State

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(state == .active ? FileNestTheme.primaryGradient : LinearGradient(colors: [.clear], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Circle().stroke(state == .pending ? FileNestTheme.border : FileNestTheme.accent, lineWidth: 1.5)
                    }
                if state == .complete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FileNestTheme.accent)
                } else {
                    Text("\(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            }
            .frame(width: 30, height: 30)
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: state == .active ? .medium : .regular))
                .foregroundStyle(state == .pending ? .secondary : .primary)
                .fixedSize()
        }
    }
}

private struct ProgressFileRow: View {
    let file: FileRecord
    let index: Int

    var body: some View {
        HStack(spacing: 14) {
            FileIconView(file: file, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                (Text("Found at") + Text(" \(file.mtime.formatted(date: .omitted, time: .shortened))"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if index == 0 {
                    Label("Indexed", systemImage: "checkmark.circle")
                        .foregroundStyle(FileNestTheme.success)
                } else if index == 1 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Indexing")
                    }
                    .foregroundStyle(FileNestTheme.accent)
                } else {
                    Label("Waiting", systemImage: "clock")
                        .foregroundStyle(FileNestTheme.warning)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(width: 150, alignment: .leading)

            Label {
                Text(LocalizedStringKey(index == 0 ? file.categoryEnum.label : "Destination Pending"))
            } icon: {
                Image(systemName: "folder")
            }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 76)
    }
}
