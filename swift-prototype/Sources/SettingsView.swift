import AppKit
import SwiftUI

// Settings is deliberately an in-panel destination.  MenuBarExtra can dismiss its
// window whenever focus changes, so project and credential editing live in these
// small drafts instead of a second Window scene.
enum SettingsRequest: Equatable {
    case overview
    case addProject
    case github
    case gitlab
    case addGitLab
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case projects = "本地项目"
    case github = "GitHub"
    case gitlab = "GitLab"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .projects: return "folder"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .gitlab: return "shippingbox"
        }
    }
}

@MainActor
struct ProjectServiceDraft: Identifiable {
    let id: String
    var name: String
    var command: String
    var url: String
    var directory: String

    init(id: String = UUID().uuidString, name: String = "服务", command: String = "", url: String = "", directory: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.url = url
        self.directory = directory
    }
}

@MainActor
final class ProjectDraft: ObservableObject {
    let id: String?
    @Published var name: String
    @Published var directory: String
    @Published var services: [ProjectServiceDraft]

    init(project: Project? = nil) {
        id = project?.id
        name = project?.name ?? ""
        directory = project?.directory ?? ""
        services = project?.services.map { ProjectServiceDraft(id: $0.id, name: $0.name, command: $0.command, url: $0.url, directory: $0.directory ?? "") }
            ?? [ProjectServiceDraft()]
    }
}

@MainActor
final class GitLabDraft: ObservableObject {
    let id: UUID?
    @Published var name: String
    @Published var host: String
    @Published var token: String = ""

    init(instance: GitLabInstance? = nil) {
        id = instance?.id
        name = instance?.name ?? ""
        host = instance?.host ?? ""
    }
}

@MainActor
final class SettingsPanelState: ObservableObject {
    @Published var selectedTab: SettingsTab = .projects
    @Published var projectDraft: ProjectDraft?
    @Published var gitlabDraft: GitLabDraft?
    @Published var editingGitHub = false
    @Published var feedback: String?
    @Published var deletingProject: Project?
    @Published var deletingInstance: GitLabInstance?

    func consume(_ request: SettingsRequest?) {
        guard let request else { return }
        switch request {
        case .overview: break
        case .addProject: beginNewProject()
        case .github: selectedTab = .github
        case .gitlab: selectedTab = .gitlab
        case .addGitLab: beginNewInstance()
        }
    }

    func beginNewProject() {
        selectedTab = .projects
        projectDraft = ProjectDraft()
        feedback = nil
    }

    func beginEditProject(_ project: Project) {
        selectedTab = .projects
        projectDraft = ProjectDraft(project: project)
        feedback = nil
    }

    func beginNewInstance() {
        selectedTab = .gitlab
        gitlabDraft = GitLabDraft()
        feedback = nil
    }

    func beginEditInstance(_ instance: GitLabInstance) {
        selectedTab = .gitlab
        gitlabDraft = GitLabDraft(instance: instance)
        feedback = nil
    }

    func cancelEditor() {
        projectDraft = nil
        gitlabDraft = nil
        editingGitHub = false
        feedback = nil
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: StackHubStore
    @ObservedObject var state: SettingsPanelState
    @ObservedObject var githubOAuth: GitHubOAuthController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("设置").font(.title3.weight(.semibold))
                    Text("项目和认证连接都在当前面板管理").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "lock.shield.fill").font(.caption).foregroundStyle(.teal)
            }

            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) {
                            state.selectedTab = tab
                            state.cancelEditor()
                        }
                    } label: {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.caption2.weight(state.selectedTab == tab ? .semibold : .medium))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(state.selectedTab == tab ? .white : .white.opacity(0.5))
                    .background(state.selectedTab == tab ? Color.white.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1)))

            Group {
                switch state.selectedTab {
                case .projects: projectsContent
                case .github: githubContent
                case .gitlab: gitlabContent
                }
            }
        }
        .onAppear { consumeRequest() }
        .onChange(of: store.settingsRequest) { _, _ in consumeRequest() }
        .alert("移除本地项目？", isPresented: Binding(get: { state.deletingProject != nil }, set: { if !$0 { state.deletingProject = nil } })) {
            Button("移除项目", role: .destructive) {
                if let project = state.deletingProject { store.removeProject(project) }
                state.deletingProject = nil
            }
            Button("取消", role: .cancel) { state.deletingProject = nil }
        } message: {
            Text("只移除 StackHub 配置，不会删除磁盘上的项目文件。")
        }
        .alert("移除 GitLab 实例？", isPresented: Binding(get: { state.deletingInstance != nil }, set: { if !$0 { state.deletingInstance = nil } })) {
            Button("移除实例", role: .destructive) {
                if let instance = state.deletingInstance { store.removeInstance(instance) }
                state.deletingInstance = nil
            }
            Button("取消", role: .cancel) { state.deletingInstance = nil }
        } message: {
            Text("该实例的 Token 和缓存流水线也会从本机移除。")
        }
    }

    private func consumeRequest() {
        state.consume(store.settingsRequest)
        if store.settingsRequest != nil { store.settingsRequest = nil }
    }

    private var projectsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft = state.projectDraft {
                ProjectInlineEditor(draft: draft) {
                    saveProject(draft)
                } onCancel: {
                    state.cancelEditor()
                }
            } else {
                sectionHeader("本地项目", detail: "仅用于本机服务的启动和停止", actionTitle: "添加") { state.beginNewProject() }
                if store.projects.isEmpty {
                    SettingsEmptyRow(icon: "folder", title: "还没有本地项目", detail: "添加工作目录和启动命令后即可管理服务")
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.projects) { project in
                            HStack(spacing: 9) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.orange)
                                    .frame(width: 29, height: 29)
                                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.name).font(.caption.weight(.semibold))
                                    Text(project.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                Text("\(project.services.count) 服务").font(.caption2).foregroundStyle(.secondary)
                                Button { state.beginEditProject(project) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(StackIconButtonStyle()).controlSize(.small)
                                Button { state.deletingProject = project } label: { Image(systemName: "trash") }
                                    .buttonStyle(StackIconButtonStyle()).controlSize(.small)
                            }
                            .padding(10)
                            if project.id != store.projects.last?.id { Divider().padding(.leading, 48) }
                        }
                    }
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
                }
                Text("本地项目与 CI 关注项目相互独立。").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 2)
            }
        }
    }

    private var githubContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.editingGitHub {
                GitHubInlineEditor(isConnected: store.isGitHubConnected, oauth: githubOAuth, onOAuthToken: { credential in
                    store.saveGitHubCredential(credential)
                    store.refreshCI()
                    state.cancelEditor()
                }, onDisconnect: disconnectGitHub, onCancel: { state.cancelEditor() })
            } else {
                sectionHeader("GitHub", detail: "读取你有权限访问的仓库、Actions 和作业日志")
                HStack(spacing: 10) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.weight(.bold))
                        .frame(width: 31, height: 31)
                        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GitHub 授权").font(.caption.weight(.semibold))
                        Text(store.isGitHubConnected ? "Token 已安全保存在本机钥匙串" : "尚未连接")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(store.isGitHubConnected ? .green : .orange).frame(width: 8, height: 8)
                    Button(store.isGitHubConnected ? "管理" : "连接") {
                        state.editingGitHub = true
                    }.buttonStyle(StackSecondaryButtonStyle()).controlSize(.small)
                }
                .padding(12)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
                SettingsInfoCard(icon: "lock.shield", title: "本地安全存储", detail: "Token 只保存在当前 Mac 的钥匙串，不会写入项目文件或 UserDefaults。")
            }
        }
    }

    private var gitlabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let draft = state.gitlabDraft {
                GitLabInlineEditor(draft: draft, existingToken: draft.id.flatMap { id in store.instances.first(where: { $0.id == id }).flatMap { KeychainVault.shared.read(account: "gitlab:\($0.host)") } }, onSave: { saveGitLab(draft) }, onCancel: { state.cancelEditor() })
            } else {
                sectionHeader("GitLab", detail: "支持 GitLab.com 和多个自建实例", actionTitle: "添加") { state.beginNewInstance() }
                if store.instances.isEmpty {
                    SettingsEmptyRow(icon: "shippingbox", title: "尚未添加 GitLab 实例", detail: "每个实例独立保存地址、项目和 Token")
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.instances) { instance in
                            HStack(spacing: 9) {
                                Circle().fill(KeychainVault.shared.read(account: "gitlab:\(instance.host)") == nil ? .orange : .green).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(instance.name).font(.caption.weight(.semibold))
                                    Text(instance.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 2)
                                Button { state.beginEditInstance(instance) } label: { Image(systemName: "pencil") }
                                    .buttonStyle(StackIconButtonStyle()).controlSize(.small)
                                Button { state.deletingInstance = instance } label: { Image(systemName: "trash") }
                                    .buttonStyle(StackIconButtonStyle()).controlSize(.small)
                            }
                            .padding(10)
                            if instance.id != store.instances.last?.id { Divider().padding(.leading, 17) }
                        }
                    }
                    .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
                }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(StackSecondaryButtonStyle()).controlSize(.small) }
        }
    }

    private func saveProject(_ draft: ProjectDraft) {
        let succeeded: Bool
        if let id = draft.id, let project = store.projects.first(where: { $0.id == id }) {
            succeeded = store.updateProject(project, name: draft.name, directory: draft.directory, services: draft.services)
        } else {
            succeeded = store.addProject(name: draft.name, directory: draft.directory, services: draft.services)
        }
        if succeeded { state.cancelEditor() }
    }

    private func disconnectGitHub() {
        store.disconnectGitHub()
        state.cancelEditor()
    }

    private func saveGitLab(_ draft: GitLabDraft) {
        let succeeded: Bool
        if let id = draft.id, let instance = store.instances.first(where: { $0.id == id }) {
            succeeded = store.updateInstance(instance, name: draft.name, host: draft.host, project: "", token: draft.token)
        } else {
            succeeded = store.addInstance(name: draft.name, host: draft.host, project: "", token: draft.token)
        }
        if succeeded { state.cancelEditor() }
    }
}

private struct ProjectInlineEditor: View {
    @ObservedObject var draft: ProjectDraft
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader(title: draft.id == nil ? "添加本地项目" : "编辑项目", subtitle: "服务目录支持相对路径，留空沿用项目目录")
            labeledField("项目名称", text: $draft.name)
            DirectoryInputField(title: "项目工作目录", directory: $draft.directory)
            HStack(alignment: .firstTextBaseline) {
                Text("服务配置").font(.caption.weight(.semibold))
                Spacer()
                Button { draft.services.append(ProjectServiceDraft()) } label: { Label("添加服务", systemImage: "plus") }
                    .buttonStyle(StackSecondaryButtonStyle())
                    .controlSize(.small)
            }
            VStack(spacing: 9) {
                ForEach($draft.services) { $service in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(service.name.isEmpty ? "服务" : service.name).font(.caption.weight(.semibold))
                            Spacer()
                            if draft.services.count > 1 {
                                Button { draft.services.removeAll { $0.id == service.id } } label: { Image(systemName: "trash") }
                                    .buttonStyle(StackIconButtonStyle())
                                    .controlSize(.small)
                            }
                        }
                        HStack(spacing: 8) {
                            labeledField("服务名称", text: $service.name)
                            labeledField("启动命令", text: $service.command)
                        }
                        DirectoryInputField(
                            title: "启动目录（可选）",
                            directory: $service.directory,
                            placeholder: "留空使用项目工作目录",
                            defaultDirectory: draft.directory,
                            pickerTitle: "选择服务启动目录"
                        )
                        labeledField("访问地址（可选）", text: $service.url)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.07)))
                }
            }
            HStack {
                Spacer()
                Button("保存项目", action: onSave).buttonStyle(StackPrimaryButtonStyle()).controlSize(.small)
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}

private struct DirectoryInputField: View {
    let title: String
    @Binding var directory: String
    var placeholder: String? = nil
    var defaultDirectory: String = ""
    var pickerTitle: String = "选择项目工作目录"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder ?? title, text: $directory)
                    .textFieldStyle(StackInputFieldStyle())
                    .accessibilityLabel(title)
                Button(action: chooseDirectory) {
                    Label("选择目录", systemImage: "folder")
                }
                .buttonStyle(StackSecondaryButtonStyle())
                .controlSize(.small)
                .fixedSize()
                .help(pickerTitle)
                .accessibilityLabel(pickerTitle)
            }
        }
    }

    private func chooseDirectory() {
        let editorWindow = NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.title = pickerTitle
        panel.prompt = "选择目录"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        let baseDirectory = WorkingDirectory.normalizedOverride(defaultDirectory)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        // Start at the service override, then the project, then the home
        // directory when the user is still typing an invalid path.
        for candidate in [WorkingDirectory.resolve(directory, projectDirectory: baseDirectory),
                          WorkingDirectory.resolve(nil, projectDirectory: baseDirectory)] {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue {
                panel.directoryURL = candidate
                break
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
        // MenuBarExtra may hide when the picker takes focus. Return to the
        // existing editor so both selection and cancellation preserve the draft.
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct GitLabInlineEditor: View {
    @ObservedObject var draft: GitLabDraft
    let existingToken: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    private var isEditing: Bool { draft.id != nil }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (existingToken != nil || !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                Text("GL")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEditing ? "编辑 GitLab 实例" : "连接 GitLab")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text("连接后同步你有权限访问的项目和流水线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("取消", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(existingToken == nil ? .orange : .green)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name.isEmpty ? "新 GitLab 实例" : draft.name)
                        .font(.caption.weight(.semibold))
                    Text(existingToken == nil ? "尚未连接" : "已保存访问令牌")
                        .font(.caption2)
                        .foregroundStyle(existingToken == nil ? .orange : .green)
                }
                Spacer(minLength: 0)
                if !draft.host.isEmpty {
                    Text(draft.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("实例信息")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                compactField("显示名称", placeholder: "例如：公司 GitLab", text: $draft.name)
                compactField("实例地址", placeholder: "例如：https://gitlab.example.com", text: $draft.host)
                if let tokenURL = tokenCreationURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("还没有访问令牌？", systemImage: "questionmark.circle")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("创建时选择 read_api 权限，用于读取项目、流水线和作业日志。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            NSWorkspace.shared.open(tokenURL)
                        } label: {
                            Label("打开 Token 创建页", systemImage: "arrow.up.right.square")
                                .font(.caption2.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                    }
                    .padding(.top, 3)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.075)))

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("访问令牌")
                            .font(.caption.weight(.semibold))
                        Text("Access Token")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if existingToken != nil {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(existingToken == nil ? "glpat-••••••••" : "留空则保留当前令牌", text: $draft.token)
                    .textFieldStyle(StackInputFieldStyle())
                Label("令牌只保存到本机钥匙串，不会写入配置文件。", systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.075)))

            HStack {
                if !canSave {
                    Text(existingToken == nil ? "填写名称、地址和令牌后即可连接" : "填写名称和地址后即可保存")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(isEditing ? "保存修改" : "连接实例", action: onSave)
                    .buttonStyle(StackPrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(!canSave)
            }
        }
        .padding(15)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }

    private func compactField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 9) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(StackInputFieldStyle())
        }
    }

    private var tokenCreationURL: URL? {
        var value = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://\(value)" }
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.scheme = scheme
        components.path = "/" + ([basePath, "-", "user_settings", "personal_access_tokens"].filter { !$0.isEmpty }.joined(separator: "/"))
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

private struct GitHubInlineEditor: View {
    let isConnected: Bool
    @ObservedObject var oauth: GitHubOAuthController
    let onOAuthToken: (GitHubOAuthCredential) -> Void
    let onDisconnect: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            editorHeader(title: "管理 GitHub 授权", subtitle: "只使用浏览器 OAuth，不保存密码或 Personal Access Token")
            HStack(spacing: 9) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.caption.weight(.bold)).frame(width: 30, height: 30).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitHub 浏览器授权").font(.caption.weight(.semibold))
                    Text(isConnected ? "已连接，可读取仓库与 Actions" : "点击后将在浏览器中确认授权").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Button {
                        oauth.start(onToken: onOAuthToken)
                    } label: {
                        Label(oauth.isRunning ? "等待浏览器授权" : "浏览器授权", systemImage: "safari")
                    }
                    .buttonStyle(StackSecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(oauth.isRunning)
                    if oauth.verificationURL != nil {
                        Button("重新打开浏览器") { oauth.openBrowser() }
                            .buttonStyle(.plain)
                            .font(.caption2.weight(.medium))
                    .foregroundStyle(.teal)
                    }
                }
                if let code = oauth.verificationCode {
                    OAuthVerificationCodeCard(code: code, onCopy: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    })
                } else if let status = oauth.statusText {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle({
                            if case .failed = oauth.state { return Color.orange }
                            if case .authorized = oauth.state { return Color.green }
                            return Color.secondary
                        }())
                        .textSelection(.enabled)
                }
                Text("授权码只用于把浏览器里的 GitHub 授权和本机 StackHub 配对；授权完成后不会保存授权码。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.07)))
            HStack {
                if isConnected { Button("断开授权", action: onDisconnect).buttonStyle(StackSecondaryButtonStyle()).controlSize(.small) }
                Spacer()
                Button("取消", action: onCancel).buttonStyle(StackSecondaryButtonStyle()).controlSize(.small)
            }
        }
        .padding(13)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}

private struct OAuthVerificationCodeCard: View {
    let code: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("浏览器授权码", systemImage: "number.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.teal)
                Spacer()
                Button(action: onCopy) {
                    Label("复制验证码", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
            }
            Text(code)
                .font(.system(size: 27, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.teal.opacity(0.35), lineWidth: 1))
            HStack(spacing: 5) {
                Image(systemName: "safari")
                Text("如果 GitHub 页面要求输入，请填上面的验证码")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.62))
        }
        .padding(11)
        .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.teal.opacity(0.38), lineWidth: 1))
    }
}

private func editorHeader(title: String, subtitle: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
    }
}

private func labeledField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.caption2).foregroundStyle(.secondary)
        TextField(title, text: text).textFieldStyle(StackInputFieldStyle())
    }
}

struct SettingsEmptyRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 29, height: 29)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}

struct SettingsInfoCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(.teal)
                .frame(width: 29, height: 29)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}
