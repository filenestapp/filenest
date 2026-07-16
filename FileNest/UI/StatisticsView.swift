import Charts
import SwiftUI

struct StatisticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedDays = 14
    var embeddedInSettings = false

    private var statistics: AppStatistics {
        FileNestEnvironment.isUIPreview ? .preview : appState.statistics
    }

    var body: some View {
        VStack(spacing: 0) {
            statisticsHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        StatisticMetricCard(
                            title: "Added Today",
                            value: "\(statistics.todayAddedFiles)",
                            unit: "files",
                            detail: "Added to the local library",
                            icon: "doc.badge.plus",
                            color: FileNestTheme.accentBlue
                        )
                        StatisticMetricCard(
                            title: "Indexed Files",
                            value: "\(statistics.indexedFiles)",
                            unit: "/ \(statistics.totalFiles)",
                            detail: indexCompletionText,
                            icon: "checkmark.circle",
                            color: FileNestTheme.success
                        )
                        StatisticMetricCard(
                            title: "Token Usage",
                            value: compactNumber(statistics.totalTokens),
                            unit: "estimated total",
                            detail: appState.settings.localizedFormat(
                                "Today %@",
                                compactNumber(statistics.todayTokens)
                            ),
                            icon: "sparkles",
                            color: FileNestTheme.accent
                        )
                        StatisticMetricCard(
                            title: "Managed Files",
                            value: storageText(statistics.managedFileBytes),
                            unit: "local storage",
                            detail: appState.settings.localizedFormat(
                                "%d valid files",
                                statistics.totalFiles
                            ),
                            icon: "internaldrive",
                            color: .orange
                        )
                    }

                    HStack(alignment: .top, spacing: 14) {
                        StatisticsPanel(title: "Daily File Activity", subtitle: "Files added and indexed each day") {
                            Chart(statistics.dailyActivity) { item in
                                BarMark(
                                    x: .value("Date", item.day, unit: .day),
                                    y: .value("Added", item.addedFiles)
                                )
                                .foregroundStyle(by: .value("Type", "Added"))
                                .position(by: .value("Type", "Added"))

                                BarMark(
                                    x: .value("Date", item.day, unit: .day),
                                    y: .value("Indexed", item.indexedFiles)
                                )
                                .foregroundStyle(by: .value("Type", "Indexed"))
                                .position(by: .value("Type", "Indexed"))
                            }
                            .chartForegroundStyleScale([
                                "Added": FileNestTheme.accentBlue,
                                "Indexed": FileNestTheme.success,
                            ])
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: selectedDays > 14 ? 5 : 2)) { _ in
                                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                                }
                            }
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                                    AxisValueLabel()
                                }
                            }
                            .frame(height: 210)
                        }
                        .frame(maxWidth: .infinity)

                        StatisticsPanel(title: "Index Health", subtitle: "Searchable content coverage") {
                            VStack(alignment: .leading, spacing: 18) {
                                ZStack {
                                    Circle()
                                        .stroke(FileNestTheme.border, lineWidth: 12)
                                    Circle()
                                        .trim(from: 0, to: indexCompletion)
                                        .stroke(
                                            FileNestTheme.primaryGradient,
                                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                                        )
                                        .rotationEffect(.degrees(-90))
                                    VStack(spacing: 2) {
                                        Text(indexCompletion.formatted(.percent.precision(.fractionLength(0))))
                                            .font(.system(size: 26, weight: .semibold))
                                        Text("complete")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 126, height: 126)
                                .frame(maxWidth: .infinity)

                                Label("Temporary and intermediate files are excluded automatically", systemImage: "shield.checkered")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 280)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        StatisticsPanel(title: "Token Trend", subtitle: "Estimated input and output tokens per day") {
                            Chart(statistics.dailyActivity) { item in
                                AreaMark(
                                    x: .value("Date", item.day, unit: .day),
                                    y: .value("Token", item.tokens)
                                )
                                .foregroundStyle(FileNestTheme.accent.opacity(0.12))
                                .interpolationMethod(.catmullRom)
                                LineMark(
                                    x: .value("Date", item.day, unit: .day),
                                    y: .value("Token", item.tokens)
                                )
                                .foregroundStyle(FileNestTheme.accent)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                .interpolationMethod(.catmullRom)
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .leading) { _ in
                                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                                    AxisValueLabel()
                                }
                            }
                            .frame(height: 170)
                        }
                        .frame(maxWidth: .infinity)

                        StatisticsPanel(title: "Storage Usage", subtitle: "Local data managed by FileNest") {
                            VStack(spacing: 14) {
                                StorageSummaryRow(title: "Managed Files", bytes: statistics.managedFileBytes, icon: "folder.fill", color: FileNestTheme.accentBlue)
                                StorageSummaryRow(title: "Local Models", bytes: statistics.localModelBytes, icon: "cpu.fill", color: FileNestTheme.accent)
                                StorageSummaryRow(title: "App Database", bytes: statistics.databaseBytes, icon: "cylinder.fill", color: .orange)
                                StorageSummaryRow(title: "Vector Index", bytes: statistics.vectorBytes, icon: "point.3.connected.trianglepath.dotted", color: FileNestTheme.success)
                                StorageSummaryRow(title: "Extracted Text", bytes: statistics.extractedTextBytes, icon: "doc.plaintext", color: .secondary)
                            }
                        }
                        .frame(width: 360)
                    }

                    StatisticsPanel(title: "Storage by File Type", subtitle: "File count and capacity by category") {
                        VStack(spacing: 12) {
                            ForEach(statistics.categoryStorage) { item in
                                CategoryStorageRow(item: item, totalBytes: max(1, statistics.managedFileBytes))
                            }
                            if statistics.categoryStorage.isEmpty {
                                Text("No file data yet")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 80)
                            }
                        }
                    }
                }
                .frame(maxWidth: 1120)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(FileNestTheme.surface)
        .onAppear { appState.refreshStatistics(days: selectedDays) }
    }

    private var statisticsHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: embeddedInSettings ? 3 : 6) {
                Text("Statistics")
                    .font(.system(size: embeddedInSettings ? 18 : 24, weight: .semibold))
                Text("Track file growth, indexing progress, model usage, and local storage.")
                    .font(.system(size: embeddedInSettings ? 11 : 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            statisticsControls
        }
        .padding(.horizontal, 28)
        .frame(height: embeddedInSettings ? 72 : 96)
        .background(FileNestTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }

    private var statisticsControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach([7, 14, 30], id: \.self) { days in
                    Button {
                        selectedDays = days
                        appState.refreshStatistics(days: days)
                    } label: {
                        if selectedDays == days {
                            Label(appState.settings.localizedFormat("Last %d Days", days), systemImage: "checkmark")
                        } else {
                            Text(appState.settings.localizedFormat("Last %d Days", days))
                        }
                    }
                }
            } label: {
                Label(appState.settings.localizedFormat("Last %d Days", selectedDays), systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                appState.refreshStatistics(days: selectedDays)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(QuietButtonStyle(compact: true, foreground: FileNestTheme.accent))
        }
    }

    private var indexCompletion: Double {
        guard statistics.totalFiles > 0 else { return 0 }
        return min(1, Double(statistics.indexedFiles) / Double(statistics.totalFiles))
    }

    private var indexCompletionText: String {
        appState.settings.localizedFormat(
            "%@ complete",
            indexCompletion.formatted(.percent.precision(.fractionLength(0)))
        )
    }
}

private struct StatisticMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(LocalizedStringKey(unit))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(LocalizedStringKey(detail))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(FileNestTheme.elevatedSurface.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }
}

private struct StatisticsPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(18)
        .background(FileNestTheme.elevatedSurface.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FileNestTheme.border, lineWidth: 1)
        }
    }
}

private struct StorageSummaryRow: View {
    let title: String
    let bytes: Int64
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(LocalizedStringKey(title))
                .font(.system(size: 12))
            Spacer()
            Text(storageText(bytes))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
    }
}

private struct CategoryStorageRow: View {
    @EnvironmentObject private var appState: AppState
    let item: CategoryStorageStat
    let totalBytes: Int64

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Label {
                    Text(LocalizedStringKey(item.category.label))
                } icon: {
                    Image(systemName: item.category.icon)
                }
                .font(.system(size: 12, weight: .medium))
                Text(appState.settings.localizedFormat("%d items", item.fileCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(storageText(item.bytes))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(FileNestTheme.border)
                    Capsule()
                        .fill(categoryColor(item.category))
                        .frame(width: max(4, proxy.size.width * CGFloat(Double(item.bytes) / Double(totalBytes))))
                }
            }
            .frame(height: 6)
        }
    }
}

private func storageText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
}

private func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return "\(value)"
}

private func categoryColor(_ category: FileCategory) -> Color {
    switch category {
    case .documents: return FileNestTheme.accentBlue
    case .images: return .pink
    case .videos: return .purple
    case .audio: return .orange
    case .code: return FileNestTheme.success
    case .archives: return .yellow
    case .other: return .secondary
    }
}

private extension AppStatistics {
    static var preview: AppStatistics {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let added = [2, 5, 3, 8, 4, 6, 9, 5, 7, 3, 11, 6, 8, 6]
        let indexed = [2, 4, 3, 7, 4, 6, 8, 5, 6, 3, 10, 6, 7, 6]
        let tokens = [1200, 2800, 1600, 4200, 2100, 3300, 5100, 2600, 3900, 1700, 6200, 3600, 4700, 2900]
        let daily = added.indices.map { index in
            DailyActivityStat(
                day: calendar.date(byAdding: .day, value: index - added.count + 1, to: today) ?? today,
                addedFiles: added[index],
                indexedFiles: indexed[index],
                tokens: tokens[index]
            )
        }
        return AppStatistics(
            totalFiles: 68,
            indexedFiles: 65,
            todayAddedFiles: 6,
            totalTokens: 46_700,
            todayTokens: 2_900,
            managedFileBytes: 2_780_000_000,
            databaseBytes: 18_400_000,
            vectorBytes: 11_600_000,
            extractedTextBytes: 5_200_000,
            localModelBytes: 9_650_000_000,
            dailyActivity: daily,
            categoryStorage: [
                CategoryStorageStat(category: .videos, bytes: 1_310_000_000, fileCount: 8),
                CategoryStorageStat(category: .documents, bytes: 720_000_000, fileCount: 31),
                CategoryStorageStat(category: .images, bytes: 470_000_000, fileCount: 16),
                CategoryStorageStat(category: .archives, bytes: 210_000_000, fileCount: 5),
                CategoryStorageStat(category: .code, bytes: 70_000_000, fileCount: 8),
            ]
        )
    }
}
