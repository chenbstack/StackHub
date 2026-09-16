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
                Text("优先使用手动选择，其次读取项目版本文件，最后沿用 Shell 默认。修改后重启服务生效。")
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
                    .buttonStyle(StackIconButtonStyle())
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
            Picker(kind.title, selection: choice.mode) {
                ForEach(RuntimeMode.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.menu).controlSize(.small)
            if choice.wrappedValue.mode == .installed {
                Picker(L("已安装版本"), selection: choice.path) {
                    Text(L("请选择版本")).tag("")
                    let options = installations.filter { $0.kind == kind }
                    if !choice.wrappedValue.path.isEmpty, !options.contains(where: { $0.path == choice.wrappedValue.path }) {
                        Text(LF("当前路径：%@", choice.wrappedValue.path)).tag(choice.wrappedValue.path)
                    }
                    ForEach(options) { item in
                        Text("\(item.version) · \(item.path)").tag(item.path)
                    }
                }
                .pickerStyle(.menu).controlSize(.small)
            } else if choice.wrappedValue.mode == .custom {
                HStack(spacing: 6) {
                    TextField(L(kind == .java ? "JDK 主目录或 .jdk 目录" : "Node 可执行文件路径"), text: choice.path)
                        .textFieldStyle(StackInputFieldStyle())
                        .accessibilityLabel(LF("%@ 自定义路径", kind.title))
                    Button { choosePath(kind, choice: choice) } label: {
                        Image(systemName: "folder").frame(width: 24, height: 24)
                    }
                        .buttonStyle(StackIconButtonStyle())
                        .help(L("选择运行时路径"))
                        .accessibilityLabel(LF("选择 %@ 路径", kind.title))
                }
            }
            if let resolved = resolution?[kind] {
                if let runtime = resolved.installation {
                    Text("\(kind.title) \(runtime.version)").font(.caption.weight(.medium))
                    Text(runtime.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(LF("来源：%@", resolved.source)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    Text(LF("Shell 中未检测到 %@（仅在服务需要时配置）", kind.title))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
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
