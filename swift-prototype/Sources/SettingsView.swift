import AppKit
import Combine
import SwiftUI

@MainActor
struct ProjectServiceDraft: Identifiable {
    let id: String
    var name: String
    var command: String
    var url: String
    var directory: String
    /// An empty value means StackHub must not inspect or touch any port.
    /// Multiple ports use a comma, such as `3000, 5173`.
    var ports: String

    init(id: String = UUID().uuidString, name: String = "服务", command: String = "", url: String = "", directory: String = "", ports: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.url = url
        self.directory = directory
        self.ports = ports
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
        services = project?.services.map {
            ProjectServiceDraft(
                id: $0.id,
                name: $0.name,
                command: $0.command,
                url: $0.url,
                directory: $0.directory ?? "",
                ports: $0.ports.map(String.init).joined(separator: ", ")
            )
        }
            ?? [ProjectServiceDraft()]
    }
}

@MainActor
final class GitLabDraft: ObservableObject {
    let id: UUID?
    /// This is non-sensitive metadata persisted with the instance. It lets the
    /// editor preserve an existing token without reading Keychain to render.
    let hasExistingToken: Bool
    @Published var name: String
    @Published var host: String
    @Published var token: String = ""

    init(instance: GitLabInstance? = nil, hasExistingToken: Bool = false) {
        id = instance?.id
        self.hasExistingToken = hasExistingToken
        name = instance?.name ?? ""
        host = instance?.host ?? ""
    }
}

@MainActor
final class SettingsPanelState: ObservableObject {
    @Published var projectDraft: ProjectDraft?
    @Published var gitlabDraft: GitLabDraft?

    func beginNewProject() {
        projectDraft = ProjectDraft()
    }

    func beginEditProject(_ project: Project) {
        projectDraft = ProjectDraft(project: project)
    }

    func beginNewInstance() {
        gitlabDraft = GitLabDraft()
    }

    func beginEditInstance(_ instance: GitLabInstance, hasExistingToken: Bool) {
        gitlabDraft = GitLabDraft(instance: instance, hasExistingToken: hasExistingToken)
    }

    func cancelEditor() {
        projectDraft = nil
        gitlabDraft = nil
    }
}

struct CIConnectionsSection: View {
    @EnvironmentObject private var store: StackHubStore
    let onManageGitHub: () -> Void
    let onAddGitLab: () -> Void
    let onEditGitLab: (GitLabInstance) -> Void
    @State private var deletingInstance: GitLabInstance?
    private let connectionTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CI 连接").font(.subheadline.weight(.semibold))
                Spacer()
                Button(L("检测全部")) { store.checkCIConnections() }
                    .buttonStyle(StackSecondaryButtonStyle()).controlSize(.small)
            }
            githubConnection
            gitLabConnections
        }
        .alert("移除 GitLab 实例？", isPresented: Binding(get: { deletingInstance != nil }, set: { if !$0 { deletingInstance = nil } })) {
            Button("移除实例", role: .destructive) {
                if let instance = deletingInstance { store.removeInstance(instance) }
                deletingInstance = nil
            }
            Button("取消", role: .cancel) { deletingInstance = nil }
        } message: {
            Text("该实例的 Token 和缓存流水线也会从本机移除。")
        }
        .onAppear { store.setCIConnectionsVisible(true) }
        .onDisappear { store.setCIConnectionsVisible(false) }
        .onReceive(connectionTimer) { _ in store.checkCIConnectionsIfVisible() }
    }

    private var githubConnection: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption.weight(.bold))
                .frame(width: 31, height: 31)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("GitHub 授权").font(.caption.weight(.semibold))
                connectionLabel(.github)
            }
            Spacer()
            connectionIndicator(.github)
            connectionCheckButton(.github)
            Button(L(store.isGitHubConnected ? "管理" : "连接"), action: onManageGitHub)
                .buttonStyle(StackSecondaryButtonStyle())
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }

    private var gitLabConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GitLab 实例").font(.caption.weight(.semibold))
                    Text("支持 GitLab.com 和多个自建实例").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加", action: onAddGitLab)
                    .buttonStyle(StackSecondaryButtonStyle())
                    .controlSize(.small)
            }
            if store.instances.isEmpty {
                SettingsEmptyRow(icon: "shippingbox", title: "尚未添加 GitLab 实例", detail: "每个实例独立保存地址和 Token")
            } else {
                VStack(spacing: 0) {
                    ForEach(store.instances) { instance in
                        HStack(spacing: 9) {
                            connectionIndicator(.gitlab(instance.id))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(instance.name).font(.caption.weight(.semibold))
                                Text(instance.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                connectionLabel(.gitlab(instance.id))
                            }
                            Spacer(minLength: 2)
                            connectionCheckButton(.gitlab(instance.id))
                            Button { onEditGitLab(instance) } label: { Image(systemName: "pencil") }
                                .buttonStyle(StackIconButtonStyle()).controlSize(.small)
                            Button { deletingInstance = instance } label: { Image(systemName: "trash") }
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

    private func connectionColor(_ state: CIConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .checking: return .blue
        case .unauthorized, .forbidden: return .orange
        case .unreachable, .failed: return .red
        case .unchecked, .unconfigured: return .secondary
        }
    }

    @ViewBuilder
    private func connectionIndicator(_ source: CISource) -> some View {
        let status = store.connectionStatus(for: source)
        if status.state == .checking {
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        } else {
            Circle().fill(connectionColor(status.state)).frame(width: 8, height: 8)
        }
    }

    private func connectionLabel(_ source: CISource) -> some View {
        let status = store.connectionStatus(for: source)
        let duration = status.duration.map { " · \(Int(($0 * 1_000).rounded())) ms" } ?? ""
        let checked = status.checkedAt.map {
            LF("检测于 %@", DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium))
        }
        return Text(status.state.label + duration)
            .font(.caption2).foregroundStyle(connectionColor(status.state))
            .fixedSize(horizontal: false, vertical: true)
            .help([checked, status.detail].compactMap { $0 }.joined(separator: "\n"))
    }

    private func connectionCheckButton(_ source: CISource) -> some View {
        Button { store.checkCIConnection(source) } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(StackIconButtonStyle()).controlSize(.small)
            .disabled(store.connectionStatus(for: source).state == .checking)
            .help(L("重新检测连接"))
            .accessibilityLabel(L("重新检测连接"))
    }
}

struct CIInstanceManagementDetailView: View {
    let onManageGitHub: () -> Void
    let onAddGitLab: () -> Void
    let onEditGitLab: (GitLabInstance) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConfigurationDetailHeader(
                icon: "server.rack",
                title: "实例管理",
                subtitle: "管理 GitHub 授权和 GitLab 实例",
                onClose: onClose
            )
            OverlayScrollView {
                CIConnectionsSection(
                    onManageGitHub: onManageGitHub,
                    onAddGitLab: onAddGitLab,
                    onEditGitLab: onEditGitLab
                )
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .closesOnEscape(perform: onClose)
    }
}

struct ProjectEditorDetailView: View {
    @EnvironmentObject private var store: StackHubStore
    @ObservedObject var draft: ProjectDraft
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConfigurationDetailHeader(
                icon: "folder.badge.gearshape",
                title: draft.id == nil ? "添加项目" : "编辑项目",
                subtitle: "配置本地工作目录、服务和启动命令",
                onClose: onClose
            )
            OverlayScrollView {
                ProjectInlineEditor(draft: draft, onSave: saveProject, onCancel: onClose)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .closesOnEscape(perform: onClose)
    }

    private func saveProject() {
        let succeeded: Bool
        if let id = draft.id, let project = store.projects.first(where: { $0.id == id }) {
            succeeded = store.updateProject(project, name: draft.name, directory: draft.directory, services: draft.services)
        } else {
            succeeded = store.addProject(name: draft.name, directory: draft.directory, services: draft.services)
        }
        if succeeded { onClose() }
    }
}

struct GitHubAuthorizationDetailView: View {
    @EnvironmentObject private var store: StackHubStore
    @ObservedObject var oauth: GitHubOAuthController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConfigurationDetailHeader(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "GitHub 授权",
                subtitle: "连接后同步仓库、Actions 和作业日志",
                onClose: onClose
            )
            OverlayScrollView {
                GitHubInlineEditor(
                    isConnected: store.isGitHubConnected,
                    oauth: oauth,
                    onOAuthToken: { credential in
                        store.saveGitHubCredential(credential)
                        store.refreshCI()
                        onClose()
                    },
                    onDisconnect: {
                        store.disconnectGitHub()
                        onClose()
                    },
                    onCancel: onClose
                )
                .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .closesOnEscape(perform: onClose)
    }
}

struct GitLabInstanceDetailView: View {
    @EnvironmentObject private var store: StackHubStore
    @ObservedObject var draft: GitLabDraft
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ConfigurationDetailHeader(
                icon: "shippingbox",
                title: draft.id == nil ? "添加 GitLab 实例" : "编辑 GitLab 实例",
                subtitle: "实例地址和 Token 仅保存在本机",
                onClose: onClose
            )
            OverlayScrollView {
                GitLabInlineEditor(draft: draft, hasExistingToken: draft.hasExistingToken, onSave: saveGitLab, onCancel: onClose)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
        .closesOnEscape(perform: onClose)
    }

    private func saveGitLab() {
        let succeeded: Bool
        if let id = draft.id, let instance = store.instances.first(where: { $0.id == id }) {
            succeeded = store.updateInstance(instance, name: draft.name, host: draft.host, project: "", token: draft.token)
        } else {
            succeeded = store.addInstance(name: draft.name, host: draft.host, project: "", token: draft.token)
        }
        if succeeded { onClose() }
    }
}

private struct ConfigurationDetailHeader: View {
    let icon: String
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Button(action: onClose) {
                Label("返回", systemImage: "chevron.left")
            }
            .buttonStyle(StackSecondaryButtonStyle())
            .controlSize(.small)
            .accessibilityLabel("返回")

            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text(L(title)).font(.subheadline.weight(.semibold))
                Text(L(subtitle)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
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
                            Text(service.name.isEmpty ? L("服务") : service.name).font(.caption.weight(.semibold))
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
                        HStack(spacing: 8) {
                            labeledField("访问地址（可选）", text: $service.url)
                            labeledField("监听端口（可选，逗号分隔）", text: $service.ports)
                        }
                        Text("例如 3000, 5173；启动前会终止占用这些 TCP 端口的进程。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
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
            Text(L(title)).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(L(placeholder ?? title), text: $directory)
                    .textFieldStyle(StackInputFieldStyle())
                    .accessibilityLabel(L(title))
                Button(action: chooseDirectory) {
                    Label("选择目录", systemImage: "folder")
                }
                .buttonStyle(StackSecondaryButtonStyle())
                .controlSize(.small)
                .fixedSize()
                .help(L(pickerTitle))
                .accessibilityLabel(L(pickerTitle))
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
    let hasExistingToken: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    private var isEditing: Bool { draft.id != nil }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        hasExistingToken || !draft.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    Text(L(isEditing ? "编辑 GitLab 实例" : "连接 GitLab"))
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
                    .fill(hasExistingToken ? .green : .orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name.isEmpty ? L("新 GitLab 实例") : draft.name)
                        .font(.caption.weight(.semibold))
                    Text(L(hasExistingToken ? "已保存访问令牌" : "尚未连接"))
                        .font(.caption2)
                        .foregroundStyle(hasExistingToken ? .green : .orange)
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
                    if hasExistingToken {
                        Label("已保存", systemImage: "checkmark.circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                SecureField(hasExistingToken ? "留空则保留当前令牌" : "glpat-••••••••", text: $draft.token)
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
                    Text(L(hasExistingToken ? "填写名称和地址后即可保存" : "填写名称、地址和令牌后即可连接"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(L(isEditing ? "保存修改" : "连接实例"), action: onSave)
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
            Text(L(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            TextField(L(placeholder), text: text)
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
                    Text(L(isConnected ? "已连接，可读取仓库与 Actions" : "点击后将在浏览器中确认授权")).font(.caption2).foregroundStyle(.secondary)
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
            Text(L(title)).font(.subheadline.weight(.semibold))
            Text(L(subtitle)).font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
    }
}

private func labeledField(_ title: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(L(title)).font(.caption2).foregroundStyle(.secondary)
        TextField(L(title), text: text).textFieldStyle(StackInputFieldStyle())
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
                Text(L(title)).font(.caption.weight(.semibold))
                Text(L(detail)).font(.caption2).foregroundStyle(.secondary)
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
                Text(L(title)).font(.caption.weight(.semibold))
                Text(L(detail)).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.075)))
    }
}
