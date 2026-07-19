import SwiftUI

/// Organization rules list, strategy selection, and native edit sheet.
struct RulesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var presentedSheet: PresentedSheet? = FileNestEnvironment.isAIRulePreview ? .aiGenerator : nil
    var embeddedInSettings = false

    private enum PresentedSheet: Identifiable {
        case editor(Rule)
        case aiGenerator

        var id: String {
            switch self {
            case let .editor(rule): return "editor-\(rule.id.map(String.init) ?? "new")"
            case .aiGenerator: return "ai-generator"
            }
        }
    }

    private var newRule: Rule {
        Rule(
            id: nil,
            name: "",
            type: RuleType.rule.rawValue,
            pattern: "",
            targetFolder: "Other",
            priority: 50,
            enabled: true
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: embeddedInSettings ? 3 : 6) {
                    Text(verbatim: appState.settings.localized("Organization Rules"))
                        .font(.system(size: embeddedInSettings ? 18 : 24, weight: .semibold))
                    Text(verbatim: appState.settings.localized("Automatically organize and classify files with rules."))
                        .font(.system(size: embeddedInSettings ? 11 : 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                HStack(spacing: 12) {
                    Picker(selection: Binding(
                        get: { appState.settings.classifyStrategy },
                        set: { appState.settings.setClassifyStrategy($0) }
                    )) {
                        Text(verbatim: appState.settings.localized("Hybrid"))
                            .tag(ClassificationStrategy.hybrid.rawValue)
                        Text(verbatim: appState.settings.localized("Rules Only"))
                            .tag(ClassificationStrategy.rule.rawValue)
                    } label: {
                        Text(verbatim: appState.settings.localized("Strategy"))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help(appState.settings.localized(strategyDescriptionKey))

                    Button {
                        presentedSheet = .aiGenerator
                    } label: {
                        Label {
                            Text(verbatim: appState.settings.localized("Generate with AI"))
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .simultaneousGesture(TapGesture().onEnded {
                        presentedSheet = .aiGenerator
                    })

                    Button {
                        presentedSheet = .editor(newRule)
                    } label: {
                        Label {
                            Text(verbatim: appState.settings.localized("New Rule"))
                        } icon: {
                            Image(systemName: "plus")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FileNestTheme.accentFill)
                    .keyboardShortcut("n", modifiers: [.command])
                    .simultaneousGesture(TapGesture().onEnded {
                        presentedSheet = .editor(newRule)
                    })
                }
            }
            .padding(.horizontal, 28)
            .frame(height: embeddedInSettings ? 72 : 96)
            .background(FileNestTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FileNestTheme.border).frame(height: 1)
            }

            VStack(spacing: 0) {
                RuleColumnHeader()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.rules) { rule in
                            RuleRow(
                                rule: rule,
                                setEnabled: { update(rule, enabled: $0) },
                                edit: {
                                    presentedSheet = .editor(rule)
                                },
                                delete: { delete(rule) }
                            )
                            Divider().padding(.leading, 26)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                }

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(FileNestTheme.accent)
                    Text(verbatim: appState.settings.localized("Organization Destination"))
                        .font(.system(size: 11, weight: .medium))
                    Text(appState.organizer.organizeRoot.tildeAbbreviatedPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Text(verbatim: appState.settings.localized(strategyDescriptionKey))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 28)
                .frame(height: 54)
                .background(FileNestTheme.elevatedSurface.opacity(0.45))
                .overlay(alignment: .top) {
                    Rectangle().fill(FileNestTheme.border).frame(height: 1)
                }
            }
        }
        .background(FileNestTheme.surface)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case let .editor(rule):
                RuleEditor(rule: rule) { saved in
                    _ = try? appState.store.upsertRule(saved)
                    appState.rules = (try? appState.store.allRules()) ?? []
                    presentedSheet = nil
                }
            case .aiGenerator:
                AIRuleGeneratorSheet { rule, applyImmediately in
                    _ = try? appState.store.upsertRule(rule)
                    appState.rules = (try? appState.store.allRules()) ?? []
                    presentedSheet = nil
                    if applyImmediately { appState.organizeNow() }
                }
                .environmentObject(appState)
            }
        }
    }

    private func update(_ rule: Rule, enabled: Bool) {
        var updated = rule
        updated.enabled = enabled
        _ = try? appState.store.upsertRule(updated)
        appState.rules = (try? appState.store.allRules()) ?? []
    }

    private func delete(_ rule: Rule) {
        guard let id = rule.id else { return }
        try? appState.store.deleteRule(id: id)
        appState.rules = (try? appState.store.allRules()) ?? []
    }

    private var strategyDescriptionKey: String {
        appState.settings.classifyStrategy == ClassificationStrategy.rule.rawValue
            ? "Rules Only: only matching enabled rules organize files; unmatched files stay in place."
            : "Hybrid: matching rules take priority; unmatched files are organized by file type and AI topic."
    }
}

private struct RuleColumnHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: appState.settings.localized("Rule Name")).frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: appState.settings.localized("Type")).frame(width: 110, alignment: .leading)
            Text(verbatim: appState.settings.localized("Condition")).frame(width: 220, alignment: .leading)
            Text(verbatim: appState.settings.localized("Action")).frame(width: 130, alignment: .leading)
            Text(verbatim: appState.settings.localized("Priority")).frame(width: 62, alignment: .center)
            Text(verbatim: appState.settings.localized("Enabled")).frame(width: 54, alignment: .center)
            Text(verbatim: appState.settings.localized("Actions")).frame(width: 54, alignment: .center)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .frame(height: 48)
        .background(FileNestTheme.elevatedSurface.opacity(0.42))
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }
}

private struct RuleRow: View {
    @EnvironmentObject private var appState: AppState
    let rule: Rule
    let setEnabled: (Bool) -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(rule.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: appState.settings.localized(
                rule.typeEnum == .rule ? "Rule (by extension)" : "AI Generated"
            ))
                .frame(width: 110, alignment: .leading)

            Text(rule.pattern)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 220, alignment: .leading)

            Label {
                if rule.actionEnum == .ignore {
                    Text(verbatim: appState.settings.localized("Do Not Process"))
                } else {
                    Text(rule.targetFolder)
                }
            } icon: {
                Image(systemName: rule.actionEnum == .ignore ? "hand.raised.fill" : "folder")
            }
                .foregroundStyle(rule.actionEnum == .ignore ? FileNestTheme.warning : FileNestTheme.accent)
                .frame(width: 130, alignment: .leading)

            Text("\(rule.priority)")
                .frame(width: 62, alignment: .center)

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: setEnabled
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .frame(width: 54)

            Menu {
                Button(appState.settings.localized("Edit"), action: edit)
                Divider()
                Button(appState.settings.localized("Delete"), role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 54)
        }
        .font(.system(size: 11))
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .contextMenu {
            Button(appState.settings.localized("Edit"), action: edit)
            Button(appState.settings.localized("Delete"), role: .destructive, action: delete)
        }
    }
}

struct RuleEditor: View {
    @EnvironmentObject private var appState: AppState
    @State var rule: Rule
    let onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    private var validatedTargetFolder: String? {
        OrganizationTarget.folderName(from: rule.targetFolder)
    }

    private var canSave: Bool {
        !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (rule.actionEnum == .ignore || validatedTargetFolder != nil) &&
        RuleType(rawValue: rule.type) != nil
    }

    private var normalizedExtensions: String {
        rule.pattern
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
            .joined(separator: "、")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: appState.settings.localized(
                    rule.id == nil ? "New Organization Rule" : "Edit Organization Rule"
                ))
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 72)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FileNestTheme.border).frame(height: 1)
            }

            Form {
                TextField(appState.settings.localized("Rule Name"), text: $rule.name)

                LabeledContent {
                    Text(verbatim: appState.settings.localized(
                        rule.type == RuleType.rule.rawValue
                            ? "Rule (by extension)"
                            : "AI Generated (Deterministic Rule)"
                    ))
                        .foregroundStyle(.secondary)
                } label: {
                    Text(verbatim: appState.settings.localized("Type"))
                }

                TextField(appState.settings.localized("Matching Extensions"), text: $rule.pattern)
                Text(verbatim: appState.settings.localized("Separate extensions with commas; higher-priority rules match first."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Picker(selection: $rule.action) {
                    Text(verbatim: appState.settings.localized("Organize into Folder"))
                        .tag(RuleAction.organize.rawValue)
                    Text(verbatim: appState.settings.localized("Do Not Process"))
                        .tag(RuleAction.ignore.rawValue)
                } label: {
                    Text(verbatim: appState.settings.localized("When Matched"))
                }
                .pickerStyle(.segmented)

                if rule.actionEnum == .organize {
                    TextField(appState.settings.localized("Destination Folder"), text: $rule.targetFolder)
                    if !rule.targetFolder.isEmpty && validatedTargetFolder == nil {
                        Text(verbatim: appState.settings.localized(
                            "The destination must be one folder name and cannot contain /, \\, :, . or ..."
                        ))
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(verbatim: appState.settings.localized(
                        "Matched files stay in their original location and are excluded from automatic organization."
                    ))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Stepper(
                    appState.settings.localizedFormat("Priority %d", rule.priority),
                    value: $rule.priority,
                    in: 0...100
                )
                Toggle(isOn: $rule.enabled) {
                    Text(verbatim: appState.settings.localized("Enabled"))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                Image(systemName: canSave ? "checkmark.circle" : "info.circle")
                    .foregroundStyle(canSave ? FileNestTheme.success : .secondary)
                if canSave {
                    Text(rule.actionEnum == .ignore
                         ? appState.settings.localizedFormat("%@ files will stay in their original location", normalizedExtensions)
                         : appState.settings.localizedFormat(
                            "%@ files will be moved to “%@”",
                            normalizedExtensions,
                            validatedTargetFolder ?? rule.targetFolder
                         ))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                } else {
                    Text(verbatim: appState.settings.localized(
                        "Enter a rule name, extensions, and a valid destination folder to save."
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(FileNestTheme.elevatedSurface.opacity(0.52))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(FileNestTheme.border, lineWidth: 1)
            }
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(appState.settings.localized("Cancel")) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(appState.settings.localized("Save Rule")) {
                    var saved = rule
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.targetFolder = validatedTargetFolder ?? saved.targetFolder
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(24)
        }
        .frame(width: 520, height: 590)
        .background(FileNestTheme.surface)
    }
}

private struct AIRuleGeneratorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var request = ""
    @State private var draft: Rule?
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var applyImmediately = true
    let onSave: (Rule, Bool) -> Void

    private var canSave: Bool {
        guard let draft else { return false }
        return !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            OrganizationTarget.folderName(from: draft.targetFolder) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(FileNestTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: appState.settings.localized("AI Organization Rule"))
                        .font(.system(size: 20, weight: .semibold))
                    Text(verbatim: appState.settings.localized(
                        "Describe your organization habits and AI will create a reviewable extension rule that runs automatically."
                    ))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 76)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FileNestTheme.border).frame(height: 1)
            }

            Form {
                Section {
                    TextEditor(text: $request)
                        .font(.system(size: 12))
                        .frame(minHeight: 74)
                    Text(verbatim: appState.settings.localized(
                        "Example: Move PDF, Word, and Excel contracts to ‘Client Contracts’ with priority 90."
                    ))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await generate() }
                    } label: {
                        if isGenerating {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text(verbatim: appState.settings.localized("Generating"))
                            }
                        } else {
                            Label {
                                Text(verbatim: appState.settings.localized(
                                    draft == nil ? "Generate Rule" : "Regenerate"
                                ))
                            } icon: {
                                Image(systemName: "sparkles")
                            }
                        }
                    }
                    .disabled(isGenerating || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(verbatim: appState.settings.localized("Rule Description"))
                }

                if let draftBinding = Binding($draft) {
                    Section {
                        TextField(appState.settings.localized("Rule Name"), text: draftBinding.name)
                        TextField(appState.settings.localized("Extensions (comma-separated)"), text: draftBinding.pattern)
                        TextField(appState.settings.localized("Destination Folder"), text: draftBinding.targetFolder)
                        Stepper(
                            appState.settings.localizedFormat(
                                "Priority %d",
                                draftBinding.wrappedValue.priority
                            ),
                            value: draftBinding.priority,
                            in: 0...100
                        )
                        Toggle(isOn: draftBinding.enabled) {
                            Text(verbatim: appState.settings.localized("Enable Rule"))
                        }
                        Toggle(isOn: $applyImmediately) {
                            Text(verbatim: appState.settings.localized("Organize Existing Files After Saving"))
                        }
                    } header: {
                        Text(verbatim: appState.settings.localized("Generated Result (editable before saving)"))
                    }
                }

                if let errorMessage {
                    Label(
                        appState.settings.localizedRuntimeMessage(errorMessage),
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button(appState.settings.localized("Cancel")) { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                Spacer()
                Button(appState.settings.localized("Save & Enable")) {
                    guard var draft else { return }
                    draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.targetFolder = OrganizationTarget.folderName(from: draft.targetFolder) ?? draft.targetFolder
                    onSave(draft, applyImmediately)
                    dismiss()
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.5)
            }
            .padding(24)
        }
        .frame(width: 580, height: 650)
        .background(FileNestTheme.surface)
    }

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            draft = try await AIRuleGenerator(provider: appState.settings.makeLLMProvider())
                .generate(from: request)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
