import AppKit
import SwiftUI

struct HostConnectionView: View {
    @ObservedObject var model: HostConnectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle(row.target.title, isOn: Binding(
                            get: { model.rows.first { $0.target == row.target }?.selected ?? false },
                            set: { model.select(row.target, selected: $0) }))
                            .toggleStyle(.checkbox)
                        Spacer()
                        Button("测试") { Task { await model.test(target: row.target) } }
                        directoryButton(row.path)
                    }
                    Text(row.status).font(.caption).foregroundStyle(.secondary)
                    pathText(row.path)
                    if let error = row.error { errorText(error) }
                    if row.tests != HostConnectionModel.TestResults() {
                        VStack(alignment: .leading, spacing: 4) {
                            layer("1. 本机 socket", row.tests.socket)
                            layer("2. 配置与 helper", row.tests.configuration)
                            layer("3. 真实宿主事件", row.tests.activity)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.vertical, 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("helper：\(model.helperStatus.title)").font(.caption).foregroundStyle(helperColor)
                pathText(model.discovery.installedHelper)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("DSH · 只读探测").font(.subheadline)
                if model.dshProfiles.isEmpty {
                    Text("未发现 profile").font(.caption).foregroundStyle(.secondary)
                    pathText(model.discovery.profilesDirectory)
                }
                ForEach(model.dshProfiles) { profile in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(profile.name)
                            Spacer()
                            Text(profile.status).foregroundStyle(.secondary)
                            directoryButton(profile.path)
                        }.font(.caption)
                        pathText(profile.path)
                        if let error = profile.error { errorText(error) }
                    }
                }
                if let error = model.discoveryError { errorText(error) }
                Text("请在 DSH 插件市场安装并启用 dsh-native-pet。此处仅探测，不修改 profile。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Codex 保存后仍需在 /hooks 或 Hooks 设置审核启用；Claude Code 需重启。配置目录优先使用应用进程的环境变量，GUI 不继承登录 shell 的环境。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("测试全部") { Task { await model.testAll() } }
                Button("重新探测") { model.reload() }
                Spacer()
                Button("保存") { model.save() }.buttonStyle(.borderedProminent)
            }
            if let message = model.saveMessage {
                Text(message).font(.caption).foregroundStyle(model.saveErrors.isEmpty ? Color.secondary : Color.red)
            }
        }
        .onAppear { model.reload() }
    }

    private func layer(_ title: String, _ result: HostConnectionModel.LayerResult) -> some View {
        Text("\(title)：\(result.title)")
            .font(.caption)
            .foregroundStyle(result.isFailure ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var helperColor: Color {
        switch model.helperStatus {
        case .bundledMissing, .unreadable: .red
        default: .secondary
        }
    }

    private func pathText(_ path: URL) -> some View {
        Text(path.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func errorText(_ error: String) -> some View {
        Text(error).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func directoryButton(_ path: URL) -> some View {
        Button("打开目录") { NSWorkspace.shared.selectFile(path.path, inFileViewerRootedAtPath: path.deletingLastPathComponent().path) }
            .disabled(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
            .help(path.deletingLastPathComponent().path)
    }
}
