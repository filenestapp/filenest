import SwiftUI
import UniformTypeIdentifiers

struct RAGFeedbackDraft {
    var rating: RAGFeedbackRating
    var reason: String
    var bestFileID: Int64?
    var bestFileReason: String
}

struct RAGSingleFileFeedbackContext {
    let file: FileRecord
    let rank: Int?
    let confidence: Double?

    var defaultRating: RAGFeedbackRating {
        RAGFeedbackPolicy.defaultRating(
            selectedFileRank: rank,
            confidence: confidence
        )
    }
}

/// Shared feedback editor for chat answers and library-search result sets.
struct RAGFeedbackEditor: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let files: [FileRecord]
    let initialFeedback: RAGFeedbackRecord?
    let preselectedFileID: Int64?
    let singleFileContext: RAGSingleFileFeedbackContext?
    let onSave: (RAGFeedbackDraft) -> Void

    @State private var rating: RAGFeedbackRating
    @State private var reason: String
    @State private var bestFileID: Int64?
    @State private var bestFileReason: String

    init(
        files: [FileRecord],
        initialFeedback: RAGFeedbackRecord?,
        preselectedFileID: Int64? = nil,
        singleFileContext: RAGSingleFileFeedbackContext? = nil,
        onSave: @escaping (RAGFeedbackDraft) -> Void
    ) {
        self.files = files
        self.initialFeedback = initialFeedback
        self.preselectedFileID = preselectedFileID
        self.singleFileContext = singleFileContext
        self.onSave = onSave
        let storedRating = singleFileContext?.defaultRating
            ?? initialFeedback.flatMap { RAGFeedbackRating(rawValue: $0.rating) }
            ?? .accurate
        _rating = State(initialValue: storedRating)
        _reason = State(initialValue: initialFeedback?.reason ?? "")
        _bestFileID = State(
            initialValue: singleFileContext?.file.id
                ?? preselectedFileID
                ?? initialFeedback?.bestFileID
        )
        let selectedFileID = singleFileContext?.file.id ?? preselectedFileID
        let storedBestFileReason = selectedFileID == nil
            || selectedFileID == initialFeedback?.bestFileID
            ? initialFeedback?.bestFileReason
            : nil
        _bestFileReason = State(initialValue: storedBestFileReason ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if singleFileContext != nil {
                    singleFileReasonSection
                        .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 20) {
                        accuracySection
                        bestFileSection
                        analysisDisclosure
                    }
                    .padding(24)
                }
            }
            Divider()
            footer
        }
        .frame(width: 620, height: singleFileContext == nil ? 640 : 280)
        .background(FileNestTheme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: appState.settings.localized(
                singleFileContext == nil
                    ? "Improve Future Results"
                    : "Mark as Most Accurate"
            ))
                .font(.system(size: 22, weight: .semibold))
            Text(verbatim: singleFileContext?.file.name ?? appState.settings.localized(
                "Your evaluation is saved with this result and used to refine FileNest skills."
            ))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var accuracySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: appState.settings.localized("Result Accuracy"))
                .font(.system(size: 14, weight: .semibold))
            Picker(appState.settings.localized("Result Accuracy"), selection: $rating) {
                Text(verbatim: appState.settings.localized("Accurate"))
                    .tag(RAGFeedbackRating.accurate)
                Text(verbatim: appState.settings.localized("Inaccurate"))
                    .tag(RAGFeedbackRating.inaccurate)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(verbatim: appState.settings.localized(
                rating == .inaccurate
                    ? "What was inaccurate or missing?"
                    : "What made this result accurate? (Optional)"
            ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextEditor(text: $reason)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 84, maxHeight: 110)
                .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(FileNestTheme.border, lineWidth: 1)
                }
        }
    }

    private var bestFileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: appState.settings.localized("Most Accurate File"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(verbatim: appState.settings.localized(
                        "Select the file that best answers the request."
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bestFileID != nil {
                    Button(appState.settings.localized("Clear Selection")) {
                        bestFileID = nil
                        bestFileReason = ""
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(FileNestTheme.accent)
                    .pointingHandOnHover()
                }
            }

            if files.isEmpty {
                Label(
                    appState.settings.localized("No retrieved files are available for annotation."),
                    systemImage: "doc.questionmark"
                )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(Array(files.prefix(30))) { file in
                        Button {
                            bestFileID = file.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: bestFileID == file.id
                                      ? "checkmark.circle.fill"
                                      : "circle")
                                    .foregroundStyle(bestFileID == file.id
                                                     ? FileNestTheme.accent
                                                     : .secondary)
                                FileIconView(file: file, size: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.name)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(file.displayPath)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .frame(height: 48)
                            .background(
                                bestFileID == file.id
                                    ? FileNestTheme.contentSelection
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                }
                .padding(4)
                .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
            }

            if bestFileID != nil {
                Text(verbatim: appState.settings.localized("Why is this the best match? (Optional)"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(
                    appState.settings.localized("Add a concise reason"),
                    text: $bestFileReason
                )
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var singleFileReasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: appState.settings.localized("Why is this the best match? (Optional)"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(
                appState.settings.localized("Add a concise reason"),
                text: $bestFileReason
            )
                .textFieldStyle(.roundedBorder)
        }
    }

    private var analysisDisclosure: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "brain.head.profile")
                .foregroundStyle(FileNestTheme.accent)
            Text(analysisDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 9))
    }

    private var analysisDescription: String {
        switch AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama {
        case .ollama:
            return appState.settings.localized(
                "After saving, the configured local Ollama model analyzes this feedback in the background with Thinking enabled."
            )
        case .cloud:
            return appState.settings.localized(
                "After saving, the configured cloud AI analyzes this feedback in the background."
            )
        case .none:
            return appState.settings.localized(
                "AI is disabled. This feedback stays queued until an AI source is enabled."
            )
        }
    }

    private var footer: some View {
        HStack {
            Button(appState.settings.localized("Cancel")) { dismiss() }
                .buttonStyle(QuietButtonStyle())
            Spacer()
            Button {
                onSave(RAGFeedbackDraft(
                    rating: rating,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    bestFileID: bestFileID,
                    bestFileReason: bestFileReason.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                dismiss()
            } label: {
                Label(
                    appState.settings.localized("Save Feedback"),
                    systemImage: "checkmark"
                )
            }
            .buttonStyle(GradientButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}

struct AISkillsSettingsView: View {
    private enum SkillTab: String, CaseIterable, Identifiable {
        case builtIn
        case fileNest
        case shared

        var id: Self { self }

        var titleKey: String {
            switch self {
            case .builtIn: return "Built-in"
            case .fileNest: return "FileNest Learning"
            case .shared: return "Shared Skills"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @State private var pendingDeletion: AgentSkill?
    @State private var isImportingSkill = false
    @State private var importError: String?
    @State private var selectedSkillTab: SkillTab = .builtIn

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Button {
                        appState.revealAgentSkillsFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .help(appState.settings.localized("Open Skills Folder"))
                    .accessibilityLabel(appState.settings.localized("Open Skills Folder"))
                    Button {
                        appState.refreshRAGLearningState()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .help(appState.settings.localized("Refresh Skills"))
                    .accessibilityLabel(appState.settings.localized("Refresh Skills"))
                    Button {
                        isImportingSkill = true
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                    .help(appState.settings.localized("Import Skill…"))
                    .accessibilityLabel(appState.settings.localized("Import Skill…"))
                }

                Picker(appState.settings.localized("Skill Source"), selection: $selectedSkillTab) {
                    ForEach(SkillTab.allCases) { tab in
                        Text(appState.settings.localized(tab.titleKey)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(appState.settings.localizedFormat(
                        "%d skills",
                        skillsForSelectedTab.count
                    ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    Spacer()
                }

                if skillsForSelectedTab.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.secondary)
                        Text(verbatim: appState.settings.localized(emptyTitleKey))
                            .font(.system(size: 14, weight: .semibold))
                        Text(verbatim: appState.settings.localized(
                            emptyDescriptionKey
                        ))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    skillGroup(skillsForSelectedTab)
                }
            } header: {
                Text(verbatim: appState.settings.localized("Agent Skills"))
            } footer: {
                Text(verbatim: appState.settings.localized(
                    "Built-in skills are always enabled. FileNest Learning skills can be enabled or disabled, while Shared Skills stay disabled until you enable them."
                ))
            }

            if let importError {
                Section {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(FileNestTheme.warning)
                        .font(.system(size: 11))
                }
            }

            if !appState.agentSkillDiagnostics.isEmpty {
                Section {
                    ForEach(appState.agentSkillDiagnostics.prefix(20)) { diagnostic in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: diagnostic.severity == .error
                                  ? "xmark.octagon.fill"
                                  : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnostic.severity == .error
                                                 ? Color.red
                                                 : FileNestTheme.warning)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(diagnostic.message)
                                    .font(.system(size: 11))
                                Text(URL(fileURLWithPath: diagnostic.path).lastPathComponent)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text(verbatim: appState.settings.localized("Skill Diagnostics"))
                }
            }

            Section {
                HStack(spacing: 9) {
                    Image(systemName: "brain")
                        .foregroundStyle(FileNestTheme.accent)
                    Text(providerDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Text(verbatim: appState.settings.localized(
                    "Feedback analysis refines FileNest Learning skills; it does not change Built-in or Shared Skills."
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if appState.ragFeedbackRecords.isEmpty {
                    Text(verbatim: appState.settings.localized(
                        "No result evaluations have been saved."
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.ragFeedbackRecords.prefix(30)) { feedback in
                        HStack(spacing: 10) {
                            Image(systemName: statusIcon(feedback))
                                .foregroundStyle(statusColor(feedback))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sourceTitle(feedback))
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(statusDetail(feedback))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if feedback.analysisStatus == RAGFeedbackAnalysisStatus.failed.rawValue
                                || feedback.analysisStatus == RAGFeedbackAnalysisStatus.pending.rawValue {
                                Button(appState.settings.localized("Analyze Again")) {
                                    appState.retryRAGFeedbackAnalysis(feedback)
                                }
                                .buttonStyle(QuietButtonStyle(compact: true))
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            } header: {
                Text(verbatim: appState.settings.localized("Feedback Analysis"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { appState.refreshRAGLearningState() }
        .fileImporter(
            isPresented: $isImportingSkill,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try appState.importAgentSkillPackage(from: url)
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
        .confirmationDialog(
            appState.settings.localized("Delete AI Skill?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { skill in
            Button(appState.settings.localized("Delete Skill"), role: .destructive) {
                appState.deleteManagedAgentSkill(skill)
                pendingDeletion = nil
            }
            Button(appState.settings.localized("Cancel"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { skill in
            Text(appState.settings.localizedFormat(
                "“%@” will no longer affect future searches or answers.",
                skill.name
            ))
        }
    }

    private var providerDescription: String {
        switch AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama {
        case .ollama:
            return appState.settings.localized(
                "Feedback analysis uses the configured local Ollama model with Thinking forced on."
            )
        case .cloud:
            return appState.settings.localized(
                "Feedback analysis uses the configured cloud AI provider."
            )
        case .none:
            return appState.settings.localized(
                "AI is disabled; new feedback remains queued for analysis."
            )
        }
    }

    private var skillsForSelectedTab: [AgentSkill] {
        switch selectedSkillTab {
        case .builtIn:
            return appState.installedAgentSkills.filter { $0.origin == .bundled }
        case .fileNest:
            return appState.installedAgentSkills.filter { $0.origin == .managed }
        case .shared:
            return appState.installedAgentSkills.filter { $0.origin == .sharedUser }
        }
    }

    private var emptyTitleKey: String {
        switch selectedSkillTab {
        case .builtIn: return "No Built-in Skills Found"
        case .fileNest: return "No FileNest Learning Skills Found"
        case .shared: return "No Shared Skills Found"
        }
    }

    private var emptyDescriptionKey: String {
        switch selectedSkillTab {
        case .builtIn:
            return "Built-in Skills are included with FileNest."
        case .fileNest:
            return "Import a SKILL.md package to add it to FileNest Learning."
        case .shared:
            return "Add standard SKILL.md packages to the shared Agent Skills folder."
        }
    }

    private func skillGroup(_ skills: [AgentSkill]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(skills) { skill in
                AgentSkillRow(
                    skill: skill,
                    setEnabled: skill.origin == .bundled
                        ? nil
                        : { appState.setAgentSkillEnabled(skill, enabled: $0) },
                    delete: skill.isManaged ? { pendingDeletion = skill } : nil
                )
            }
        }
    }

    private func sourceTitle(_ feedback: RAGFeedbackRecord) -> String {
        switch RAGFeedbackSourceKind(rawValue: feedback.sourceKind) ?? .chat {
        case .chat:
            return appState.settings.localized("Chat Answer Feedback")
        case .search:
            return feedback.searchQuery ?? appState.settings.localized("Search Result Feedback")
        case .smartSearch:
            return feedback.searchQuery ?? appState.settings.localized("Smart Search Feedback")
        }
    }

    private func statusDetail(_ feedback: RAGFeedbackRecord) -> String {
        if let summary = feedback.analysisSummary, !summary.isEmpty { return summary }
        if let error = feedback.analysisError, !error.isEmpty { return error }
        return appState.settings.localized(feedback.analysisStatus.capitalized)
    }

    private func statusIcon(_ feedback: RAGFeedbackRecord) -> String {
        switch RAGFeedbackAnalysisStatus(rawValue: feedback.analysisStatus) ?? .pending {
        case .pending: return "clock"
        case .analyzing: return "brain"
        case .applied: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ feedback: RAGFeedbackRecord) -> Color {
        switch RAGFeedbackAnalysisStatus(rawValue: feedback.analysisStatus) ?? .pending {
        case .pending, .analyzing: return FileNestTheme.accent
        case .applied: return FileNestTheme.success
        case .failed: return FileNestTheme.warning
        }
    }
}

private struct AgentSkillRow: View {
    @EnvironmentObject private var appState: AppState
    let skill: AgentSkill
    let setEnabled: ((Bool) -> Void)?
    let delete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: scopeIcon)
                    .foregroundStyle(FileNestTheme.accent)
                    .frame(width: 20)
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(verbatim: appState.settings.localized(originTitle))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(height: 19)
                    .background(FileNestTheme.elevatedSurface, in: Capsule())
                Spacer()
                if let setEnabled {
                    Toggle(appState.settings.localized("Enabled"), isOn: Binding(
                        get: { skill.enabled },
                        set: setEnabled
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                } else {
                    Label(appState.settings.localized("Always On"), systemImage: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FileNestTheme.success)
                }
                if let delete {
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help(appState.settings.localized("Delete Skill"))
                }
            }
            Text(skill.description)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(skill.skillFilePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !skill.resources.isEmpty {
                    Text(appState.settings.localizedFormat(
                        "%d resources",
                        skill.resources.count
                    ))
                }
                if !skill.diagnostics.isEmpty {
                    Text(appState.settings.localizedFormat(
                        "%d warnings",
                        skill.diagnostics.count
                    ))
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
    }

    private var originTitle: String {
        switch skill.origin {
        case .bundled: return "Built In"
        case .sharedUser: return "Shared User"
        case .managed: return "FileNest Learning"
        }
    }

    private var scopeIcon: String {
        if skill.metadata["filenest-auto-activate"] == AgentSkillCapability.search.rawValue {
            return "magnifyingglass"
        }
        if skill.metadata["filenest-auto-activate"] == AgentSkillCapability.feedbackLearning.rawValue {
            return "arrow.triangle.2.circlepath"
        }
        return "puzzlepiece.extension"
    }
}
