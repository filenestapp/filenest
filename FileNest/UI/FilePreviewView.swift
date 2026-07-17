import AppKit
import QuickLookUI
import SwiftUI

/// Unified file details and Quick Look preview pane on the right side of the main window.
struct FilePreviewView: View {
    @EnvironmentObject private var appState: AppState

    let file: FileRecord
    let startDocumentChat: (FileRecord) -> Void

    @State private var noteDraft: String
    @State private var isSavingNote = false
    @State private var isGeneratingSummary = false
    @State private var summaryGenerationTask: Task<Void, Never>?
    @State private var isReindexing = false
    @State private var isDeleting = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isPreviewHovered = false
    @StateObject private var expandedPreviewPresenter = ExpandedPreviewWindowPresenter()
    @State private var noteError: String?
    @State private var reindexError: String?
    @State private var trashError: String?
    @State private var didSaveNote = false
    @State private var indexedChunks: [IndexedDocumentChunk] = []
    @State private var isLoadingChunks = false
    @State private var isChunkListExpanded = false
    @State private var expandedChunkIndex: Int?

    init(file: FileRecord, startDocumentChat: @escaping (FileRecord) -> Void) {
        self.file = file
        self.startDocumentChat = startDocumentChat
        _noteDraft = State(initialValue: file.note ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    locationSection
                    sectionDivider
                    metadataSection
                    sectionDivider
                    quickActionsSection
                    sectionDivider
                    previewSection
                    sectionDivider
                    noteSection
                    sectionDivider
                    indexSection
                    sectionDivider
                    deleteSection
                }
                .padding(.bottom, 18)
            }
            .fileNestOverlayScrollStyle()
        }
        .background(.ultraThinMaterial)
        .onDisappear {
            summaryGenerationTask?.cancel()
            summaryGenerationTask = nil
            isGeneratingSummary = false
        }
        .alert("Move to Trash?", isPresented: $isDeleteConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { moveToTrash() }
        } message: {
            Text(appState.settings.localizedFormat("Are you sure you want to move “%@” to the Trash?", file.name))
        }
        .task(id: file.id) { loadIndexedChunks() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            FileIconView(file: file, size: 30)
            Text(file.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(action: appState.closeFilePreview) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close Preview")
            .accessibilityLabel("Close Preview")
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }

    private var locationSection: some View {
        InspectorSection(title: "Location") {
            Text(file.displayPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            inspectorLink("Show in Finder", icon: "folder") {
                revealInFinder()
            }
        }
    }

    private var metadataSection: some View {
        InspectorSection(title: "File Information") {
            metadataRow(
                title: "Modified",
                value: file.mtime.formatted(date: .abbreviated, time: .shortened)
            )
            metadataRow(
                title: "Type",
                value: "\(appState.settings.localized(file.categoryEnum.label)) · \(file.ext.uppercased()) · \(file.displaySize)"
            )
        }
    }

    private var quickActionsSection: some View {
        InspectorSection(title: "Quick Actions") {
            inspectorLink("Open", icon: "arrow.up.forward.app") {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            }
            inspectorLink("Copy File Path", icon: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if file.supportsDocumentChat {
                inspectorLink("Chat with Document", icon: "doc.text.magnifyingglass") {
                    startDocumentChat(file)
                }
            }
        }
    }

    private var previewSection: some View {
        InspectorSection(title: "File Preview") {
            ZStack(alignment: .bottomTrailing) {
                preview

                Button {
                    expandedPreviewPresenter.present(file: file)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Color.clear
                            .contentShape(Rectangle())

                        Label("Expand Preview", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(.black.opacity(0.68), in: Capsule())
                            .padding(9)
                            .opacity(isPreviewHovered ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!FileManager.default.fileExists(atPath: file.path))
                .accessibilityLabel("Expand Preview")
            }
                .frame(height: 220)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(FileNestTheme.strongBorder, lineWidth: 1)
                }
                .onHover { isPreviewHovered = $0 }
                .pointingHandOnHover(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @ViewBuilder
    private var preview: some View {
        let url = URL(fileURLWithPath: file.path)
        if FileManager.default.fileExists(atPath: file.path) {
            QuickLookFileView(url: url)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Unable to Preview")
                    .font(.system(size: 13, weight: .semibold))
                Text("The file was moved or deleted.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var noteSection: some View {
        InspectorSection(title: "File note") {
            TextEditor(text: $noteDraft)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: 88, maxHeight: 128)
                .background(FileNestTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(FileNestTheme.strongBorder, lineWidth: 1)
                }
                .onChange(of: noteDraft) { _ in didSaveNote = false }

            Text("The note is added to the local index for search, chat, and automatic organization.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let noteError {
                Label(noteError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if didSaveNote {
                Label("Note and index updated", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FileNestTheme.success)
            }

            HStack(spacing: 8) {
                if supportsAISummary {
                    Button {
                        generateSummary()
                    } label: {
                        if isGeneratingSummary {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Generate AI Summary", systemImage: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSavingNote || isGeneratingSummary)
                }

                Spacer(minLength: 4)

                Button {
                    saveNote()
                } label: {
                    if isSavingNote {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(FileNestTheme.accent)
                .controlSize(.small)
                .disabled(isSavingNote || isGeneratingSummary || file.id == nil)
            }
        }
    }

    private var indexSection: some View {
        InspectorSection(title: "Index Status") {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: file.indexedAt == nil ? "clock" : "checkmark.circle.fill")
                    .foregroundStyle(file.indexedAt == nil ? FileNestTheme.warning : FileNestTheme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(file.indexedAt == nil ? "Not Indexed" : "Indexed"))
                        .font(.system(size: 11, weight: .medium))
                    if let indexedAt = file.indexedAt {
                        Text(indexedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    reindexFile()
                } label: {
                    if isReindexing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Reindexing…")
                        }
                    } else {
                        Label("Reindex", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isReindexing || appState.reindexButtonsDisabled || file.id == nil)
            }

            if file.indexedAt != nil || !indexedChunks.isEmpty {
                Divider()

                HStack(spacing: 8) {
                    Label(
                        appState.settings.localizedFormat("%d Chunks", indexedChunks.count),
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                    if isLoadingChunks { ProgressView().controlSize(.mini) }
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isChunkListExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isChunkListExpanded ? "Collapse" : "View Chunks")
                            Image(systemName: isChunkListExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FileNestTheme.accent)
                    .disabled(isLoadingChunks || indexedChunks.isEmpty)
                }

                if !isLoadingChunks, indexedChunks.isEmpty {
                    Text("This file has metadata indexing only and no vector chunks to preview.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isChunkListExpanded {
                    LazyVStack(spacing: 6) {
                        ForEach(indexedChunks) { chunk in
                            IndexedChunkPreviewRow(
                                chunk: chunk,
                                isExpanded: expandedChunkIndex == chunk.index
                            ) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    expandedChunkIndex = expandedChunkIndex == chunk.index
                                        ? nil
                                        : chunk.index
                                }
                            }
                        }
                    }
                }
            }

            if let reindexError {
                Label(reindexError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deleteSection: some View {
        InspectorSection(title: "Delete File") {
            Text("The file will be moved to the macOS Trash and can be restored until the Trash is emptied.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let trashError {
                Label(trashError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                isDeleteConfirmationPresented = true
            } label: {
                HStack {
                    if isDeleting { ProgressView().controlSize(.small) }
                    Label("Move to Trash", systemImage: "trash")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.small)
            .disabled(isDeleting)
        }
    }

    private var sectionDivider: some View {
        Divider().padding(.horizontal, 16)
    }

    private var supportsAISummary: Bool {
        file.categoryEnum == .documents || file.categoryEnum == .images
    }

    private func metadataRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 10, weight: .medium))
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inspectorLink(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(LocalizedStringKey(title), systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FileNestTheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }

    private func generateSummary() {
        guard let id = file.id else { return }
        summaryGenerationTask?.cancel()
        isGeneratingSummary = true
        noteError = nil
        didSaveNote = false
        summaryGenerationTask = Task { @MainActor in
            do {
                let stream = try appState.streamNoteSummary(fileID: id)
                for try await partial in stream {
                    try Task.checkCancellation()
                    noteDraft = partial
                }
            } catch is CancellationError {
                // Closing the preview intentionally stops the typewriter stream.
            } catch {
                noteError = appState.settings.localizedRuntimeMessage(error.localizedDescription)
            }
            isGeneratingSummary = false
            summaryGenerationTask = nil
        }
    }

    private func saveNote() {
        guard let id = file.id else { return }
        isSavingNote = true
        noteError = nil
        didSaveNote = false
        Task {
            defer { isSavingNote = false }
            do {
                try await appState.saveNote(fileID: id, note: noteDraft)
                didSaveNote = true
                loadIndexedChunks()
            } catch {
                noteError = appState.settings.localizedRuntimeMessage(error.localizedDescription)
            }
        }
    }

    private func reindexFile() {
        isReindexing = true
        reindexError = nil
        Task {
            let succeeded = await appState.reindexFile(file)
            if !succeeded {
                reindexError = appState.settings.localized("Reindexing failed. Please try again later.")
            } else {
                loadIndexedChunks()
            }
            isReindexing = false
        }
    }

    private func moveToTrash() {
        isDeleting = true
        trashError = nil
        Task {
            do {
                try await appState.moveFileToTrash(file)
            } catch {
                trashError = appState.settings.localizedFormat(
                    "Could not move to Trash: %@",
                    error.localizedDescription
                )
                isDeleting = false
            }
        }
    }

    private func loadIndexedChunks() {
        guard let id = file.id else {
            indexedChunks = []
            return
        }
        isLoadingChunks = true
        indexedChunks = appState.indexedChunks(fileID: id)
        isLoadingChunks = false
        if let expandedChunkIndex,
           !indexedChunks.contains(where: { $0.index == expandedChunkIndex }) {
            self.expandedChunkIndex = nil
        }
    }
}

private struct IndexedChunkPreviewRow: View {
    @EnvironmentObject private var appState: AppState
    let chunk: IndexedDocumentChunk
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    Text("#\(chunk.index + 1)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FileNestTheme.accent)
                        .frame(width: 28, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey(kindLabel))
                                .font(.system(size: 10, weight: .medium))
                            if !locationLabel.isEmpty {
                                Text(locationLabel)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Text(chunk.text)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? 4 : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            if isExpanded {
                Divider().padding(.vertical, 8)

                HStack(spacing: 10) {
                    Label(
                        chunk.tokenCountAccuracy == .exact
                            ? appState.settings.localizedFormat("%d tokens", chunk.tokenCount)
                            : appState.settings.localizedFormat("About %d Tokens", chunk.tokenCount),
                        systemImage: "number"
                    )
                    .help("\(chunk.tokenizerProfile) · \(chunk.tokenCountAccuracy.rawValue)")
                    Text(appState.settings.localizedFormat("%d Characters", chunk.text.count))
                    Spacer()
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

                Text(chunk.text)
                    .font(.system(size: 10))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                if let embeddingPrefix {
                    Text("Added Embedding Context")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                    Text(embeddingPrefix)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }

                if let parentContext {
                    Text("Parent Context")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 10)
                    Text(parentContext)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                }
            }
        }
        .padding(9)
        .background(FileNestTheme.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExpanded ? FileNestTheme.accent.opacity(0.28) : FileNestTheme.border, lineWidth: 1)
        }
    }

    private var embeddingPrefix: String? {
        guard chunk.contextualText != chunk.text else { return nil }
        guard chunk.contextualText.hasSuffix(chunk.text) else { return chunk.contextualText }
        let prefix = chunk.contextualText.dropLast(chunk.text.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    private var parentContext: String? {
        guard let parent = chunk.parentText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parent.isEmpty, parent != chunk.text else { return nil }
        return parent
    }

    private var kindLabel: String {
        switch chunk.kind {
        case .title: return "Title Chunk"
        case .text: return "Text Chunk"
        case .table: return "Table Chunk"
        case .list: return "List Chunk"
        case .picture: return "Image Chunk"
        case .note: return "Note Chunk"
        case .metadata: return "Metadata Chunk"
        }
    }

    private var locationLabel: String {
        var parts = [String]()
        if !chunk.sectionPath.isEmpty {
            parts.append(chunk.sectionPath.joined(separator: " › "))
        }
        if let start = chunk.pageStart {
            let page = chunk.pageEnd.flatMap { $0 == start ? nil : $0 }
                .map { "p.\(start)–\($0)" } ?? "p.\(start)"
            parts.append(page)
        }
        return parts.joined(separator: " · ")
    }
}

private struct ExpandedFilePreviewView: View {
    let file: FileRecord
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileIconView(file: file, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.displayPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: close) {
                    Label("Exit Expanded Preview", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Divider()

            QuickLookFileView(url: URL(fileURLWithPath: file.path))
                .background(Color(nsColor: .underPageBackgroundColor))
                .padding(18)
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(.regularMaterial)
    }
}

@MainActor
private final class ExpandedPreviewWindowPresenter: ObservableObject {
    private var windowController: NSWindowController?

    func present(file: FileRecord) {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let targetScreen = NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
        // Borderless windows do not automatically avoid the system menu bar or Dock.
        // Use the display's visible frame so the custom header and close button remain reachable.
        let previewFrame = targetScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let content = ExpandedFilePreviewView(file: file) { [weak self] in
            self?.dismiss()
        }
        let window = ExpandedPreviewWindow(
            contentRect: previewFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: content)
        window.backgroundColor = .windowBackgroundColor
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.setFrame(previewFrame, display: true)

        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        windowController?.close()
        windowController = nil
    }
}

private final class ExpandedPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title))
                .font(.system(size: 11, weight: .semibold))
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickLookFileView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        return view
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.currentURL = url
        nsView.previewItem = url as NSURL
    }

    final class Coordinator {
        var currentURL: URL?
    }
}
