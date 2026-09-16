import AppKit
import SwiftUI

struct ServiceRuntimeEditor: View {
    @Binding var configuration: ServiceRuntimeConfiguration
    let directory: URL
    @State private var expanded = false
    @State private var refresh = 0
    @State private var installations: [RuntimeInstallation] = []
    @State private var resolution: ServiceRuntimeResolution?
    @State private var error: String?
    @State private var catalogError: String?
    @State private var checking = false
    @State private var scanning = false

    private struct Query: Hashable {
        let expanded: Bool
        let directory: URL
        let refresh: Int
        var configuration: ServiceRuntimeConfiguration = .init()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("修改后重启服务生效。")
                    .font(.caption2).foregroundStyle(.secondary)
                runtimeRow(.java, choice: $configuration.java)
                runtimeRow(.node, choice: $configuration.node)
                HStack(spacing: 6) {
                    if checking || scanning { ProgressView().controlSize(.mini) }
                    Text(checking || scanning ? L("正在检测运行环境…") : L("仅使用已安装版本，不自动下载"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { refresh += 1 } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                    }
                    .buttonStyle(PanelHeaderIconButtonStyle())
                    .help(L("重新检测运行环境"))
                    .accessibilityLabel(L("重新检测运行环境"))
                }
                if let error = error ?? catalogError {
                    Text(error).font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("运行环境").font(.caption.weight(.semibold))
        }
        .disclosureGroupStyle(RuntimeDisclosureStyle())
        .task(id: Query(expanded: expanded, directory: directory, refresh: refresh)) {
            guard expanded else { return }
            scanning = true
            catalogError = nil
            installations = []
            do {
                let found = try await ServiceRuntimeResolver().catalog(directory: directory)
                try Task.checkCancellation()
                installations = found
            } catch {
                guard !Task.isCancelled else { return }
                catalogError = error.localizedDescription
            }
            scanning = false
        }
        .task(id: Query(expanded: expanded, directory: directory, refresh: refresh, configuration: configuration)) {
            guard expanded else { return }
            checking = true
            error = nil
            resolution = nil
            do {
                // Wait for path typing to settle; an obsolete probe is cancelled.
                try await Task.sleep(for: .milliseconds(250))
                let resolved = try await ServiceRuntimeResolver().prepare(configuration: configuration, directory: directory)
                try Task.checkCancellation()
                resolution = resolved
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            checking = false
        }
    }

    private func runtimeRow(_ kind: RuntimeKind, choice: Binding<RuntimeChoice>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(kind.title)
                    .font(.caption.weight(.semibold))
                    .frame(width: 48, alignment: .leading)
                RuntimeSelect(
                    title: kind.title,
                    selection: Binding(get: { choice.wrappedValue.mode.rawValue }, set: {
                        guard let mode = RuntimeMode(rawValue: $0) else { return }
                        choice.wrappedValue.mode = mode
                    }),
                    options: RuntimeMode.allCases.map { .init(id: $0.rawValue, title: $0.label) }
                )
            }
            if choice.wrappedValue.mode == .installed {
                RuntimeSelect(title: L("已安装版本"), selection: choice.path,
                              options: installedOptions(kind, choice: choice.wrappedValue))
            } else if choice.wrappedValue.mode == .custom {
                HStack(spacing: 6) {
                    TextField(L(kind == .java ? "JDK 主目录或 .jdk 目录" : "Node 可执行文件路径"), text: choice.path)
                        .textFieldStyle(StackInputFieldStyle())
                        .accessibilityLabel(LF("%@ 自定义路径", kind.title))
                    Button { choosePath(kind, choice: choice) } label: {
                        Image(systemName: "folder").frame(width: 24, height: 24)
                    }
                        .buttonStyle(PanelHeaderIconButtonStyle())
                        .help(L("选择运行时路径"))
                        .accessibilityLabel(LF("选择 %@ 路径", kind.title))
                }
            }
            if let resolved = resolution?[kind] {
                if let runtime = resolved.installation {
                    HStack(spacing: 8) {
                        Text(runtime.version).font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Text(resolved.source).font(.caption2).foregroundStyle(.secondary)
                            .help(LF("来源：%@", resolved.source))
                    }
                    Text(runtime.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(runtime.path)
                } else {
                    Text(LF("Shell 中未检测到 %@（仅在服务需要时配置）", kind.title))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
    }

    private func installedOptions(_ kind: RuntimeKind, choice: RuntimeChoice) -> [RuntimeSelect.Option] {
        let found = installations.filter { $0.kind == kind }
        var options: [RuntimeSelect.Option] = [.init(id: "", title: L("请选择版本"))]
        if !choice.path.isEmpty, !found.contains(where: { $0.path == choice.path }) {
            options.append(.init(id: choice.path, title: L("当前路径"), detail: choice.path))
        }
        options += found.map { .init(id: $0.path, title: $0.version, detail: $0.path) }
        return options
    }

    private func choosePath(_ kind: RuntimeKind, choice: Binding<RuntimeChoice>) {
        let editorWindow = NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.title = LF("选择 %@ 路径", kind.title)
        panel.canChooseDirectories = kind == .java
        panel.canChooseFiles = kind == .node
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { choice.wrappedValue.path = url.path }
        editorWindow?.makeKeyAndOrderFront(nil)
    }
}

private struct RuntimeDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelHeaderIconButtonStyle())
            .accessibilityValue(L(configuration.isExpanded ? "已展开" : "已收起"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

/// Custom SwiftUI select surface; options never use the native macOS picker/menu.
private struct RuntimeSelect: View {
    struct Option: Identifiable {
        let id: String
        let title: String
        var detail: String? = nil
    }
    let title: String
    @Binding var selection: String
    let options: [Option]
    @State private var isPresented = false
    @State private var isHovered = false

    private var selected: Option? { options.first { $0.id == selection } }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                Text(selected?.title ?? L("请选择版本"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.white.opacity(isHovered || isPresented ? 0.09 : 0.045),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isPresented ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
        .accessibilityValue(selected?.title ?? "")
        .help(selected?.detail ?? selected?.title ?? title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ViewThatFits(in: .vertical) {
                optionsList.fixedSize(horizontal: false, vertical: true)
                ScrollView { optionsList }
                    .frame(height: 280)
            }
            .frame(width: 300)
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(red: 0.075, green: 0.09, blue: 0.135))
            .environment(\.colorScheme, .dark)
            .onExitCommand { isPresented = false }
        }
    }

    private var optionsList: some View {
        VStack(spacing: 3) {
            ForEach(options) { option in
                Button {
                    selection = option.id
                    isPresented = false
                } label: {
                    HStack(spacing: 9) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title).font(.caption)
                            if let detail = option.detail {
                                Text(detail).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .opacity(selection == option.id ? 1 : 0)
                    }
                    .padding(9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RuntimeOptionStyle(selected: selection == option.id))
                .help(option.detail ?? option.title)
            }
        }.padding(5)
    }
}

private struct RuntimeOptionStyle: ButtonStyle {
    let selected: Bool
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(Color.white.opacity(hovered || configuration.isPressed ? 0.10 : selected ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovered = $0 }
    }
}
