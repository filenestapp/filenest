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
}

/// Library search, category filtering, organization progress, and Finder actions.
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    let startDocumentChat: (FileRecord) -> Void
    @State private var searchText = ""
    @State private var category: FileCategory?
    @State private var searchResults: [LibrarySearchResult]?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var activeSearchQuery = ""
    @State private var smartSearchEnabled = false
    @State private var smartSearchPlan: SmartLibrarySearchPlan?
    @State private var smartSearchUsedAI = false
    @State private var isOrganizing = false
    @State private var sortField: LibrarySortField = .modified
    @State private var sortDirection: LibrarySortDirection = .descending
    @State private var dateField: LibraryDateField = .modified
    @State private var draftDateRange = LibraryDateRange(start: Date(), end: Date())
    @State private var selectedDateRange: LibraryDateRange?
    @State private var isCalendarPresented = false
    @State private var creationDates: [String: Date] = [:]
    @State private var visibleLimit = 20

    private var sourceFiles: [FileRecord] {
        (searchResults?.map(\.file) ?? appState.files).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private var searchMatchesByPath: [String: LibrarySearchResult] {
        Dictionary(uniqueKeysWithValues: (searchResults ?? []).map { ($0.file.path, $0) })
    }

    private var filteredFiles: [FileRecord] {
        let matchingFiles = sourceFiles.filter { file in
            (category == nil || file.categoryEnum == category) &&
            (searchText.isEmpty || searchResults != nil ||
             file.name.localizedCaseInsensitiveContains(searchText) ||
             (file.title ?? "").localizedCaseInsensitiveContains(searchText))
        }
        let dateFiltered = LibraryFileQuery.filtered(
            matchingFiles,
            in: selectedDateRange,
            dateField: dateField,
            creationDates: creationDates
        )
        return LibraryFileQuery.sorted(dateFiltered, field: sortField, direction: sortDirection)
    }

    private var visibleFiles: [FileRecord] {
        Array(filteredFiles.prefix(visibleLimit))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: isOrganizing ? "Organizing New Files" : "Library",
                       subtitle: isOrganizing
                       ? "FileNest is building the local index; files will not move until indexing completes."
                       : "Search and manage organized files; all indexes stay on this Mac.") {
                HStack(spacing: 10) {
                    if isOrganizing {
                        Button {
                            isOrganizing = false
                        } label: {
                            Label("Pause Organization", systemImage: "pause.circle")
                        }
                        .buttonStyle(QuietButtonStyle())
                    } else {
                        Button {
                            runOrganize()
                        } label: {
                            Label("Organize Now", systemImage: "tray.and.arrow.down")
                        }
                        .buttonStyle(GradientButtonStyle())

                        Button {
                            appState.reindexAll()
                        } label: {
                            IndexingButtonLabel(defaultTitle: "Reindex", appState: appState)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(appState.reindexButtonsDisabled)
                    }
                }
            }

            if isOrganizing {
                OrganizationProgressView(files: progressFiles)
            } else {
                libraryContent
            }
        }
        .background(FileNestTheme.surface)
        .onAppear { refreshCreationDates() }
        .onChange(of: appState.files) { _ in
            resetPagination()
            refreshCreationDates()
        }
        .onChange(of: searchText) { value in
            resetPagination()
            scheduleSearch(value)
        }
        .onChange(of: category) { _ in resetPagination() }
        .onChange(of: selectedDateRange) { _ in resetPagination() }
        .onChange(of: dateField) { _ in resetPagination() }
        .onChange(of: sortField) { _ in resetPagination() }
        .onChange(of: sortDirection) { _ in resetPagination() }
        .onDisappear { searchTask?.cancel() }
    }

    private var libraryContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        if isSearching {
                            ProgressView().controlSize(.small)
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

                    Button {
                        smartSearchEnabled.toggle()
                        clearSearch()
                    } label: {
                        Label("Smart Search", systemImage: "sparkles")
                            .font(.system(size: 11, weight: smartSearchEnabled ? .semibold : .medium))
                            .foregroundStyle(smartSearchEnabled ? FileNestTheme.accent : Color.secondary)
                            .padding(.horizontal, 11)
                            .frame(height: 38)
                            .background(
                                smartSearchEnabled ? FileNestTheme.selection : FileNestTheme.elevatedSurface.opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(
                                        smartSearchEnabled ? FileNestTheme.accent.opacity(0.3) : FileNestTheme.border,
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    .help("AI analyzes the query and creates precise retrieval conditions")

                    Button(action: runSearch) {
                        if isSearching {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(LocalizedStringKey(smartSearchEnabled ? "AI Analyzing…" : "Searching…"))
                            }
                        } else {
                            Text(LocalizedStringKey(smartSearchEnabled ? "Smart Search" : "Search"))
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(isSearching || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            FilterChip(title: "All", icon: nil, selected: category == nil) {
                                category = nil
                            }
                            ForEach(FileCategory.allCases) { item in
                                FilterChip(title: item.label, icon: item.icon, selected: category == item) {
                                    category = item
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
                    }
                    .font(.system(size: 10, weight: .medium))

                    if smartSearchEnabled, let smartSearchPlan {
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
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)

            Divider()

            if isSearching, searchResults == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(LocalizedStringKey(
                        smartSearchEnabled
                            ? "AI is analyzing the query and running precise vector retrieval…"
                            : "Searching Keywords and Vector Index…"
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredFiles.isEmpty {
                EmptyLibraryView(searching: !searchText.isEmpty || category != nil || selectedDateRange != nil)
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
                                startDocumentChat: startDocumentChat
                            )
                            Divider().padding(.leading, 78)
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

    private func smartSearchPlanDescription(_ plan: SmartLibrarySearchPlan) -> String {
        var parts = [String]()
        if !plan.semanticQuery.isEmpty {
            parts.append(appState.settings.localizedFormat("Semantic: %@", plan.semanticQuery))
        }
        if !plan.keywords.isEmpty {
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

    private var progressFiles: [FileRecord] {
        Array(appState.files.prefix(4))
    }

    private func runSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        if smartSearchEnabled {
            startSmartSearch(query: query)
        } else {
            startSearch(query: query, debounceNanoseconds: 0)
        }
    }

    private func scheduleSearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }
        guard !smartSearchEnabled else {
            searchTask?.cancel()
            searchTask = nil
            searchResults = nil
            smartSearchPlan = nil
            isSearching = false
            return
        }
        startSearch(query: query, debounceNanoseconds: 300_000_000)
    }

    private func startSearch(query: String, debounceNanoseconds: UInt64) {
        searchTask?.cancel()
        activeSearchQuery = query
        isSearching = true
        searchResults = nil
        sortField = .relevance
        sortDirection = .descending
        searchTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let results = await appState.managedSearchResults(matching: query)
            guard !Task.isCancelled,
                  activeSearchQuery == query,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = results
            isSearching = false
            searchTask = nil
            resetPagination()
        }
    }

    private func startSmartSearch(query: String) {
        searchTask?.cancel()
        activeSearchQuery = query
        isSearching = true
        searchResults = nil
        smartSearchPlan = nil
        sortField = .relevance
        sortDirection = .descending
        searchTask = Task { @MainActor in
            let response = await appState.managedSmartSearchResults(matching: query)
            guard !Task.isCancelled,
                  activeSearchQuery == query,
                  searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            searchResults = response.results
            smartSearchPlan = response.plan
            smartSearchUsedAI = response.usedAI
            isSearching = false
            searchTask = nil
            resetPagination()
        }
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        searchResults = nil
        smartSearchPlan = nil
        smartSearchUsedAI = false
        activeSearchQuery = ""
        sortField = .modified
        sortDirection = .descending
        resetPagination()
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

    private func refreshCreationDates() {
        let candidates = sourceFiles.map { ($0.path, $0.discoveredAt ?? $0.addedAt) }
        Task {
            let values = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: candidates.map { path, fallback in
                    let url = URL(fileURLWithPath: path)
                    let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? fallback
                    return (path, created)
                })
            }.value
            creationDates.merge(values) { _, new in new }
        }
    }

    private func runOrganize() {
        guard !isOrganizing else { return }
        withAnimation(.easeOut(duration: 0.18)) { isOrganizing = true }
        appState.organizeNow()

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                appState.refresh()
                withAnimation(.easeOut(duration: 0.18)) { isOrganizing = false }
            }
        }
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

private enum LibraryTableLayout {
    static let spacing: CGFloat = 14
    static let iconWidth: CGFloat = 38
    static let categoryWidth: CGFloat = 90
    static let sizeWidth: CGFloat = 82
    static let modifiedWidth: CGFloat = 150
    static let actionsWidth: CGFloat = 128
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
        .frame(minHeight: 66)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered || isSelected ? FileNestTheme.selection : Color.clear)
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
            if file.supportsPreview {
                Button("Preview File") { appState.presentFilePreview(file) }
            }
            if file.supportsDocumentChat {
                Button("Chat with Document") { startDocumentChat(file) }
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
                    if file.indexedAt != nil {
                        Label("Indexed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(FileNestTheme.success)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(FileNestTheme.success.opacity(0.1), in: Capsule())
                            .fixedSize()
                    }
                    if let searchMatch {
                        Text(LocalizedStringKey(searchMatch.matchKind.label))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(FileNestTheme.accent)
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(FileNestTheme.accent.opacity(0.09), in: Capsule())
                            .fixedSize()
                    }
                }
                Text(secondaryText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            if file.supportsPreview { appState.presentFilePreview(file) }
        }
        .help(file.supportsPreview ? "Click to preview file" : "Preview is not available for this file type")
        .pointingHandOnHover(file.supportsPreview)
        .accessibilityAction(named: Text("Preview File")) {
            if file.supportsPreview { appState.presentFilePreview(file) }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if file.supportsDocumentChat {
                LibraryActionButton(
                    systemName: "doc.text.magnifyingglass",
                    tint: FileNestTheme.accent,
                    title: "Chat with Document"
                ) {
                    startDocumentChat(file)
                }
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
                    .buttonStyle(.plain)
                    .foregroundStyle(hasActiveFilter ? Color.secondary : Color.secondary.opacity(0.45))
                    .disabled(!hasActiveFilter)
                Spacer()
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .tint(FileNestTheme.accent)
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

private struct LibraryActionButton: View {
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

private struct OrganizationProgressView: View {
    let files: [FileRecord]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ProgressSteps()

                VStack(alignment: .leading, spacing: 12) {
                    (Text("Files Being Processed") + Text(" (\(files.count))"))
                        .font(.system(size: 13, weight: .medium))

                    VStack(spacing: 0) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, file in
                            ProgressFileRow(file: file, index: index)
                            if index < files.count - 1 { Divider().padding(.leading, 62) }
                        }
                    }
                    .background(FileNestTheme.elevatedSurface.opacity(0.64))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(FileNestTheme.border, lineWidth: 1)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
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
