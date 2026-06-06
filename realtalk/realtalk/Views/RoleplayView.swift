import SwiftUI

struct RoleplayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var practiceSpeech: SpeechPracticeManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    TimeFilterPicker()
                    controls
                    StatusBanner(text: combinedStatus)

                    if let scenario = model.scenario {
                        scenarioPanel(scenario)
                    } else {
                        ContentUnavailableView("选择时间范围后生成场景", systemImage: "person.2.wave.2")
                    }

                    if let roleplay = model.roleplay {
                        conversationPanel(roleplay)
                    }

                    historyPanel
                }
                .padding()
            }
            .navigationTitle("口语还原")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.replayLastAI()
                    } label: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .disabled(model.roleplay?.messages.contains(where: { $0.speaker == "ai" }) != true)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.generateScenario() }
                } label: {
                    Label(model.isWorking ? "生成中" : "生成场景", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)

                Button {
                    Task { await model.toggleVoiceConversation() }
                } label: {
                    Label(
                        model.isVoiceConversationActive ? "暂停对话" : "开始语音对话",
                        systemImage: model.isVoiceConversationActive ? "pause.circle" : "phone.connection"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || model.selectedRoleID.isEmpty)
            }

            if model.roleCandidates.isEmpty == false {
                HStack(spacing: 10) {
                    Picker("角色", selection: $model.selectedRoleID) {
                        ForEach(model.roleCandidates) { role in
                            Text(role.name).tag(role.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.roleplay != nil && model.roleplay?.completed == false)

                    Button {
                        if model.roleplay == nil {
                            model.switchRole()
                        } else {
                            Task { await model.switchRoleAndRestart() }
                        }
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.roleCandidates.count < 2 || model.isWorking)
                }
            }

            Toggle(isOn: $model.showDialogueContent) {
                Label("显示台词", systemImage: model.showDialogueContent ? "eye" : "eye.slash")
            }
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func scenarioPanel(_ scenario: ScenarioResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(scenario.title)
                .font(.headline)
            Text(scenario.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if model.showDialogueContent {
                ForEach(scenario.lines) { line in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(line.index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(model.roleName(line.targetRole))
                                .font(.caption)
                                .fontWeight(.semibold)
                            Spacer()
                            Text(line.intent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(line.sourceText)
                        Text(line.english)
                            .foregroundStyle(.blue)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func conversationPanel(_ roleplay: RoleplayStateResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("进度 \(roleplay.progress)/\(max(roleplay.total, 1))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(roleplay.score * 100))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(roleplay.messages) { message in
                messageRow(message)
            }

            if let next = roleplay.nextLine, roleplay.completed == false {
                VStack(alignment: .leading, spacing: 8) {
                    Label("轮到 \(model.roleName(next.targetRole))", systemImage: "mic")
                        .font(.headline)

                    if model.showDialogueContent {
                        Text(next.sourceText)
                            .foregroundStyle(.secondary)
                        Text(next.english)
                            .foregroundStyle(.blue)
                    }

                    if practiceSpeech.partialText.isEmpty == false {
                        Text(practiceSpeech.partialText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.systemYellow).opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Button {
                        Task { await model.toggleVoiceConversation() }
                    } label: {
                        Label(
                            model.isVoiceConversationActive ? "暂停对话" : "继续语音对话",
                            systemImage: model.isVoiceConversationActive ? "pause.circle.fill" : "phone.connection.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWorking)

                    HStack(spacing: 8) {
                        Image(systemName: practiceSpeech.isListening ? "waveform" : "speaker.wave.2")
                        Text(conversationStatusText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.systemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            } else if roleplay.completed {
                ContentUnavailableView("本轮完成", systemImage: "checkmark.seal")
            }
        }
    }

    private func messageRow(_ message: RoleplayMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.speaker == "ai" ? "waveform.circle" : "person.crop.circle")
                .font(.title3)
                .foregroundStyle(message.speaker == "ai" ? .blue : .green)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(model.roleName(message.role))
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    if message.speaker == "ai" {
                        Button {
                            model.voice.speak(message.content)
                        } label: {
                            Image(systemName: "speaker.wave.2")
                        }
                    }
                }

                if model.showDialogueContent {
                    Text(message.content)
                    if let translation = message.translation, translation.isEmpty == false {
                        Text(translation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.speaker == "ai" ? "AI 已发言" : "语音已提交")
                        .foregroundStyle(.secondary)
                }

                if let feedback = message.feedback, feedback.isEmpty == false {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("练习记录")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.loadPracticeHistory() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }

            if model.practiceHistory.isEmpty {
                Text("暂无记录")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.practiceHistory.prefix(5)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("\(item.turns)/\(max(item.total, 1))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(item.score * 100))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var combinedStatus: String {
        [model.statusMessage, practiceSpeech.statusText, practiceSpeech.lastError]
            .compactMap { $0 }
            .filter { $0.isEmpty == false && $0 != "未开始" }
            .joined(separator: "\n")
    }

    private var conversationStatusText: String {
        if practiceSpeech.isListening {
            return "正在听你说英语，停顿后会自动识别"
        }
        if model.voice.isSpeaking {
            return "AI 正在用语音还原真实对话"
        }
        if model.isVoiceConversationActive {
            return "语音对话运行中"
        }
        return "语音对话已暂停"
    }
}
