import SwiftUI

/// 规则视图：查看/编辑分类规则
struct RulesView: View {
    @EnvironmentObject var appState: AppState
    @State private var editingRule: Rule?
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            // 说明
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("整理规则").font(.title2.bold())
                    Text(appState.settings.classifyStrategy == ClassificationStrategy.rule.rawValue
                         ? "仅规则：未命中的文件保留在原位。"
                         : "混合：优先匹配规则，未命中时按扩展名自动归类。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("策略", selection: Binding(
                    get: { appState.settings.classifyStrategy },
                    set: { appState.settings.setClassifyStrategy($0) }
                )) {
                    Text("混合").tag(ClassificationStrategy.hybrid.rawValue)
                    Text("仅规则").tag(ClassificationStrategy.rule.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Button { showAdd = true } label: { Label("新增规则", systemImage: "plus") }
            }
            .padding(12)
            Divider()

            // 规则列表
            Table(appState.rules) {
                TableColumn("启用") { r in
                    Toggle("", isOn: Binding(
                        get: { r.enabled },
                        set: { newVal in update(r, enabled: newVal) }
                    )).labelsHidden().disabled(r.typeEnum == .ai)
                }.width(50)
                TableColumn("规则名") { r in Text(r.name) }
                TableColumn("类型") { r in Text(r.typeEnum == .rule ? "规则" : "AI（停用）") }.width(80)
                TableColumn("匹配模式") { r in
                    Text(r.pattern).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                TableColumn("目标文件夹") { r in Text(r.targetFolder) }.width(120)
                TableColumn("优先级") { r in Text("\(r.priority)") }.width(60)
                TableColumn("") { r in
                    HStack {
                        Button { editingRule = r } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                        Button { delete(r) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }.width(64)
            }

            Divider()

            // 归类目标说明
            VStack(alignment: .leading, spacing: 4) {
                Label("整理目标目录", systemImage: "folder")
                    .font(.headline)
                Text(appState.organizer.organizeRoot.path)
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("归类后的文件会移动到该目录下按分类命名的子文件夹中。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditor(rule: rule) { saved in
                _ = try? appState.store.upsertRule(saved)
                appState.rules = (try? appState.store.allRules()) ?? []
                editingRule = nil
            }
        }
        .sheet(isPresented: $showAdd) {
            RuleEditor(rule: Rule(id: nil, name: "", type: "rule", pattern: "", targetFolder: "其他", priority: 0, enabled: true)) { saved in
                _ = try? appState.store.upsertRule(saved)
                appState.rules = (try? appState.store.allRules()) ?? []
                showAdd = false
            }
        }
    }

    private func update(_ rule: Rule, enabled: Bool) {
        var r = rule
        r.enabled = enabled
        _ = try? appState.store.upsertRule(r)
        appState.rules = (try? appState.store.allRules()) ?? []
    }

    private func delete(_ rule: Rule) {
        guard let id = rule.id else { return }
        try? appState.store.deleteRule(id: id)
        appState.rules = (try? appState.store.allRules()) ?? []
    }
}

struct RuleEditor: View {
    @State var rule: Rule
    let onSave: (Rule) -> Void
    @Environment(\.dismiss) var dismiss

    private var validatedTargetFolder: String? {
        OrganizationTarget.folderName(from: rule.targetFolder)
    }

    private var canSave: Bool {
        !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        validatedTargetFolder != nil &&
        rule.type == RuleType.rule.rawValue
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(rule.id == nil ? "新增规则" : "编辑规则").font(.headline)
            Form {
                TextField("规则名", text: $rule.name)
                if rule.type == RuleType.ai.rawValue {
                    Picker("类型", selection: $rule.type) {
                        Text("规则（按扩展名）").tag(RuleType.rule.rawValue)
                        Text("AI（尚未实现）").tag(RuleType.ai.rawValue)
                    }
                    Text("AI 规则当前不会执行。请改为扩展名规则后再保存。")
                        .font(.caption2).foregroundStyle(.orange)
                } else {
                    LabeledContent("类型", value: "规则（按扩展名）")
                }
                TextField("匹配模式（逗号分隔扩展名，如 pdf,doc,md）", text: $rule.pattern, axis: .vertical)
                    .lineLimit(2...4)
                TextField("目标文件夹（如 文档 / 合同 / 发票）", text: $rule.targetFolder)
                if !rule.targetFolder.isEmpty && validatedTargetFolder == nil {
                    Text("目标文件夹必须是单个名称，不能包含 /、\\、:，也不能是 . 或 ..")
                        .font(.caption2).foregroundStyle(.red)
                }
                Stepper("优先级：\(rule.priority)", value: $rule.priority, in: 0...100)
                Toggle("启用", isOn: $rule.enabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") {
                    var saved = rule
                    saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.targetFolder = validatedTargetFolder ?? saved.targetFolder
                    onSave(saved)
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460, height: 460)
    }
}
