import SwiftUI

/// 设置视图：监听目录 / 文件类型 / Provider 配置
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var newDir = ""
    @State private var newExt = ""
    @State private var testResult: String?

    var body: some View {
        TabView {
            generalSettings.tabItem { Label("通用", systemImage: "gearshape") }
            aiSettings.tabItem { Label("AI / 模型", systemImage: "cpu") }
        }
        .frame(width: 560, height: 480)
    }

    // MARK: 通用设置
    private var generalSettings: some View {
        Form {
            Section("监听目录（文件放这里会被自动整理+索引）") {
                ForEach(appState.settings.watchDirs, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(dir).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { removeDir(dir) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("目录路径", text: $newDir)
                    Button("添加") { addDir() }.disabled(newDir.isEmpty)
                }
            }

            Section("自动整理") {
                Toggle("监听到新文件后自动归类移动", isOn: Binding(
                    get: { appState.settings.autoOrganize },
                    set: { appState.settings.setAutoOrganize($0) }
                ))
                Toggle("跳过隐藏文件（以 . 开头）", isOn: Binding(
                    get: { appState.settings.excludeHidden },
                    set: { appState.settings.setExcludeHidden($0) }
                ))
            }

            Section("索引文件类型") {
                Text("启用的扩展名（逗号分隔）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { appState.settings.enabledExtensions.joined(separator: ", ") },
                    set: { appState.settings.setEnabledExtensions($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
                ))
                .font(.caption)
                .frame(minHeight: 60, maxHeight: 100)
            }

            Section("数据") {
                Text("数据库位置").font(.caption).foregroundStyle(.secondary)
                Text(SQLiteStore.databaseURL().path).font(.caption2).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func addDir() {
        let dir = newDir.trimmingCharacters(in: .whitespaces)
        guard !dir.isEmpty, !appState.settings.watchDirs.contains(dir) else { return }
        var dirs = appState.settings.watchDirs
        dirs.append(dir)
        appState.settings.setWatchDirs(dirs)
        newDir = ""
        // 重启监听
        appState.stopWatching()
        appState.startWatching()
    }
    private func removeDir(_ dir: String) {
        var dirs = appState.settings.watchDirs
        dirs.removeAll { $0 == dir }
        appState.settings.setWatchDirs(dirs)
        appState.stopWatching()
        appState.startWatching()
    }

    // MARK: AI 设置
    private var aiSettings: some View {
        Form {
            Section("聊天模型（LLM）") {
                Picker("来源", selection: Binding(
                    get: { appState.settings.llmChoice },
                    set: { appState.settings.setLLMChoice($0) }
                )) {
                    ForEach(AppSettings.LLMChoice.allCases) { c in
                        Text(c.label).tag(c.rawValue)
                    }
                }

                if appState.settings.llmChoice == AppSettings.LLMChoice.ollama.rawValue {
                    TextField("Ollama 地址", text: Binding(
                        get: { appState.settings.ollamaHost },
                        set: { appState.settings.setOllamaHost($0) }
                    ))
                    TextField("模型（如 qwen2.5:7b / llama3.1:8b）", text: Binding(
                        get: { appState.settings.ollamaModel },
                        set: { appState.settings.setOllamaModel($0) }
                    ))
                    HStack {
                        Button("测试连接") { Task { await testOllama() } }
                        Text(testResult ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("安装：brew install ollama && ollama serve；拉模型：ollama pull \(appState.settings.ollamaModel)")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if appState.settings.llmChoice == AppSettings.LLMChoice.cloud.rawValue {
                    SecureField("API Key", text: Binding(
                        get: { appState.settings.cloudAPIKey },
                        set: { appState.settings.setCloudKey($0) }
                    ))
                    TextField("Base URL", text: Binding(
                        get: { appState.settings.cloudBaseURL },
                        set: { appState.settings.setCloudBaseURL($0) }
                    ))
                    TextField("模型", text: Binding(
                        get: { appState.settings.cloudModel },
                        set: { appState.settings.setCloudModel($0) }
                    ))
                    Text("兼容 OpenAI Chat Completions 接口（OpenAI / DeepSeek / 智谱等）。文件内容会发送到云端，注意隐私。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Section("向量化（Embedding）") {
                Text("默认使用 Apple 内置 NLEmbedding（离线、隐私、零配置）").font(.caption)
                Text("向量维度与检索均在本地完成，不上传任何文件内容。").font(.caption2).foregroundStyle(.secondary)
                Text("已加载向量数：\(AppStateIndexerProxy.shared.indexer?.vectorStore.count ?? 0)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func testOllama() async {
        guard let url = URL(string: "\(appState.settings.ollamaHost)/api/tags") else {
            testResult = "地址无效"; return
        }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                testResult = "连接失败（确认 ollama serve 已启动）"; return
            }
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = obj["models"] as? [[String: Any]] {
                let names = models.compactMap { $0["name"] as? String }
                testResult = names.isEmpty ? "无已安装模型" : "可用模型：\(names.joined(separator: ", "))"
            } else {
                testResult = "已连接"
            }
        } catch {
            testResult = "连接失败：\(error.localizedDescription)"
        }
    }
}
