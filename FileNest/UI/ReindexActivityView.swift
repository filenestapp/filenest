import SwiftUI

/// Displays the durable reindex job that can continue across application launches.
struct ReindexActivityView: View {
    @EnvironmentObject private var appState: AppState
    @State private var filter: ReindexFileFilter = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                progressCard

                if let summary = appState.reindexJobSummary {
                    summaryCards(summary)
                    queueCard(summary)
                } else {
                    emptyState(
                        title: "No Reindex Task",
                        detail: "There is no reindex task to monitor.",
                        icon: "checkmark.circle"
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
        }
        .background(FileNestTheme.surface)
        .task {
            appState.refreshReindexJobSummary()
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: statusIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(statusTitle))
                        .font(.system(size: 17, weight: .semibold))
                    Text(progressSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                controls
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(statusColor)

            HStack(spacing: 10) {
                Text(appState.settings.localizedFormat(
                    "%d of %d files",
                    displayedCompleted,
                    displayedTotal
                ))
                Spacer()
                Text(progressPercentage)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

            if let currentFileName = appState.vectorIndexRebuildProgress?.currentFileName,
               !currentFileName.isEmpty {
                LabeledContent {
                    Text(currentFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } label: {
                    Label("Current File", systemImage: "doc")
                }
                .font(.system(size: 12))
            }

            if displayedFailed > 0 {
                Label(
                    appState.settings.localizedFormat(
                        "%d files failed and will be retried when the task resumes.",
                        displayedFailed
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(FileNestTheme.warning)
            }
        }
        .padding(18)
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            switch appState.indexingState {
            case .running:
                Button("Pause", systemImage: "pause.fill") {
                    appState.pauseIndexing()
                }
                .buttonStyle(.bordered)
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    appState.stopIndexing()
                }
                .buttonStyle(.bordered)
            case .paused:
                Button("Resume", systemImage: "play.fill") {
                    appState.resumeIndexing()
                }
                .buttonStyle(.borderedProminent)
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    appState.stopIndexing()
                }
                .buttonStyle(.bordered)
            case .stopping:
                Button("Stopping…", systemImage: "stop.fill") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            case .failed, .stopped, .idle:
                if appState.reindexJobSummary != nil {
                    Button("Resume Reindex", systemImage: "play.fill") {
                        appState.resumeReindexJobFromSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .completed:
                EmptyView()
            }
        }
        .controlSize(.regular)
    }

    private func summaryCards(_ summary: ReindexJobSummary) -> some View {
        HStack(spacing: 10) {
            metricCard("Pending", value: summary.pending + summary.processing, icon: "clock")
            metricCard("Completed", value: summary.completed, icon: "checkmark.circle")
            metricCard("Failed", value: summary.failed, icon: "exclamationmark.triangle")
            metricCard("Total", value: summary.total, icon: "doc.on.doc")
        }
    }

    private func metricCard(_ title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FileNestTheme.accent)
                .frame(width: 28, height: 28)
                .background(FileNestTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(value.formatted())
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }

    private func queueCard(_ summary: ReindexJobSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reindex Queue")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Failed files appear first, followed by pending and completed files.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Status", selection: $filter) {
                    ForEach(ReindexFileFilter.allCases) { item in
                        Text(LocalizedStringKey(item.title)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 310)
            }
            .padding(16)

            Divider()

            LazyVStack(spacing: 0) {
                if filteredFiles(summary).isEmpty {
                    emptyState(
                        title: "No Files",
                        detail: "No files match this status.",
                        icon: "doc"
                    )
                    .frame(minHeight: 180)
                } else {
                    ForEach(filteredFiles(summary)) { item in
                        ReindexFileRow(
                            item: item,
                            isCurrent: isCurrentFile(item)
                        )
                        if item.id != filteredFiles(summary).last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }

    private func filteredFiles(_ summary: ReindexJobSummary) -> [ReindexJobFileItem] {
        summary.files.filter { filter.includes($0.state) }
    }

    private func emptyState(title: String, detail: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(LocalizedStringKey(title))
                .font(.system(size: 14, weight: .semibold))
            Text(LocalizedStringKey(detail))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private func isCurrentFile(_ item: ReindexJobFileItem) -> Bool {
        appState.indexingState.isActive
            && appState.vectorIndexRebuildProgress?.currentFileName == item.name
    }

    private var displayedCompleted: Int {
        appState.vectorIndexRebuildProgress?.completed
            ?? ((appState.reindexJobSummary?.completed ?? 0) + (appState.reindexJobSummary?.failed ?? 0))
    }

    private var displayedTotal: Int {
        appState.vectorIndexRebuildProgress?.total
            ?? appState.reindexJobSummary?.total
            ?? 0
    }

    private var displayedFailed: Int {
        max(
            appState.vectorIndexRebuildProgress?.failed ?? 0,
            appState.reindexJobSummary?.failed ?? 0
        )
    }

    private var progressFraction: Double {
        guard displayedTotal > 0 else { return 0 }
        return min(max(Double(displayedCompleted) / Double(displayedTotal), 0), 1)
    }

    private var progressPercentage: String {
        progressFraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private var progressSubtitle: LocalizedStringKey {
        if let stage = appState.vectorIndexRebuildProgress?.stage {
            return LocalizedStringKey(stage.statusText)
        }
        if let fileName = appState.vectorIndexRebuildProgress?.currentFileName {
            return LocalizedStringKey(fileName)
        }
        return LocalizedStringKey("The task state is saved automatically and can resume after relaunch.")
    }

    private var statusTitle: String {
        switch appState.indexingState {
        case .running: return "Reindexing"
        case .paused: return "Reindex Paused"
        case .stopping: return "Stopping Reindex"
        case .stopped: return "Reindex Stopped"
        case .completed: return "Reindex Complete"
        case .failed: return "Reindex Failed"
        case .idle:
            switch appState.reindexJobSummary?.job.statusValue {
            case .failed: return "Reindex Failed"
            case .interrupted: return "Reindex Interrupted"
            default: return "Reindex Ready to Resume"
            }
        }
    }

    private var statusIcon: String {
        switch appState.indexingState {
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped, .idle: return "arrow.clockwise.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch appState.indexingState {
        case .completed: return FileNestTheme.success
        case .failed: return .red
        case .paused, .stopped, .idle: return FileNestTheme.warning
        default: return FileNestTheme.accent
        }
    }
}

private enum ReindexFileFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case completed
    case failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .pending: return "Pending"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    func includes(_ state: ReindexJobFileState) -> Bool {
        switch self {
        case .all: return true
        case .pending: return state == .pending || state == .processing
        case .completed: return state == .completed
        case .failed: return state == .failed
        }
    }
}

private struct ReindexFileRow: View {
    @EnvironmentObject private var appState: AppState
    let item: ReindexJobFileItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon)
                .font(.system(size: 15))
                .foregroundStyle(isCurrent ? FileNestTheme.accent : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    (isCurrent ? FileNestTheme.accent : Color.secondary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 7)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Label(
                LocalizedStringKey(stateTitle),
                systemImage: stateIcon
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var stateTitle: String {
        if isCurrent { return "Processing" }
        switch item.state {
        case .pending, .processing: return "Pending"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private var stateIcon: String {
        if isCurrent { return "arrow.triangle.2.circlepath" }
        switch item.state {
        case .pending, .processing: return "clock"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        if isCurrent { return FileNestTheme.accent }
        switch item.state {
        case .pending, .processing: return .secondary
        case .completed: return FileNestTheme.success
        case .failed: return .red
        }
    }

    private var fileIcon: String {
        switch FileCategory.from(extension: item.ext) {
        case .documents: return "doc.text"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox"
        case .other: return "doc"
        }
    }
}
