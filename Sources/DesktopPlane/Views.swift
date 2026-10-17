import PlaneHost
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let err = model.startError {
            Text("Not running: \(err)")
        } else if let m = model.manager {
            if model.imageStage == .ready {
                Text("\(model.liveCount) of \(m.settings.maxVMs) desktops in use")
            } else {
                Text("Setup not finished")
            }
            if !m.sessions.isEmpty {
                Divider()
                ForEach(m.sessions) { s in
                    Menu("\(s.id) · \(s.state.rawValue)") {
                        Button("Watch") { model.watch(s) }
                        Button("Take Control") { model.watch(s); model.toggleControl(s) }
                        Button("End", role: .destructive) { model.stop(s) }
                    }
                }
            }
        }
        Divider()
        Button("Open Desktop Plane…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        if let s = model.service {
            Button("Copy MCP URL") { model.copy(s.settings.mcpURL) }
            Button("Copy Claude Code Command") { model.copy(AgentSetup.command(.claude, s.settings)) }
        }
        Divider()
        Button("Quit (ends all desktops)") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let err = model.startError {
                VStack(spacing: 12) {
                    Mark(size: 34).opacity(0.5)
                    Text("Desktop Plane couldn't start").font(T.sans(18, .semibold))
                    Text(err).font(T.sans(13)).foregroundStyle(T.muted).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.showOnboarding {
                OnboardingView()
            } else {
                Dashboard()
            }
        }
        .blackChrome()
    }
}

// MARK: dashboard

struct Dashboard: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: Pane = .desktops

    enum Pane: String, CaseIterable, Identifiable {
        case desktops = "Desktops", agents = "Agents", volumes = "Volumes", activity = "Activity", settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(pane: $pane)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let e = model.lastError {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber)
                            Text(e).foregroundStyle(T.muted).textSelection(.enabled)
                            Spacer()
                            Button { model.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(GhostButton())
                        }
                        .font(T.sans(13))
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(T.amber.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.amber.opacity(0.25)))
                    }
                    switch pane {
                    case .desktops: DesktopsPane()
                    case .agents: AgentsPane()
                    case .volumes: VolumesPane()
                    case .activity: ActivityPane()
                    case .settings: SettingsPane()
                    }
                }
                .frame(maxWidth: 1080, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: Dashboard.Pane

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Mark(size: 18)
                Text("Desktop Plane").font(T.sans(14, .semibold))
                Text("/").foregroundStyle(T.borderStrong).font(T.sans(18))
                Text(Host.current().localizedName ?? "This Mac").font(T.sans(14)).foregroundStyle(T.muted)
                Spacer()
                StatusPill()
            }
            .padding(.leading, 84)
            .padding(.trailing, 24)
            .frame(height: 52)
            HStack(spacing: 4) {
                ForEach(Dashboard.Pane.allCases) { p in
                    Tab(title: p.rawValue, active: p == pane) { pane = p }
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            Rectangle().fill(T.border).frame(height: 1)
        }
    }
}

private struct Tab: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(T.sans(13.5, active ? .medium : .regular))
                    .foregroundStyle(active || hover ? T.text : T.muted)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hover && !active ? T.raised : .clear))
                Rectangle().fill(active ? T.text : .clear).frame(height: 2).padding(.horizontal, 8)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct StatusPill: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Dot(color: model.service == nil ? T.faint : T.green, pulse: model.service != nil)
            Text(model.service.map { $0.settings.mcpURL.replacingOccurrences(of: "http://", with: "") } ?? "Stopped")
                .font(T.mono(11.5)).foregroundStyle(T.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(Capsule().fill(T.surface))
        .overlay(Capsule().strokeBorder(T.border))
    }
}

private struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(T.sans(28, .semibold)).tracking(-0.8)
                Text(subtitle).font(T.sans(14)).foregroundStyle(T.muted)
            }
            Spacer()
            trailing
        }
    }
}

// MARK: desktops

private struct DesktopsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sessions = model.manager?.sessions ?? []
        let max = model.manager?.settings.maxVMs ?? 2
        PaneHeader(title: "Desktops", subtitle: "\(model.liveCount) of \(max) running · each one is deleted when it ends") {
            Button { model.newDesktop() } label: {
                HStack(spacing: 6) {
                    if model.creating { ProgressView().controlSize(.mini) } else { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    Text("New desktop")
                }
            }
            .buttonStyle(PrimaryButton())
            .disabled(model.liveCount >= max || model.creating)
        }
        if sessions.isEmpty {
            EmptyDesktops()
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                ForEach(sessions) { DesktopCard(session: $0) }
            }
        }
    }
}

private struct EmptyDesktops: View {
    var body: some View {
        VStack(spacing: 14) {
            Mark(size: 34).opacity(0.6)
            Text("No desktops running").font(T.sans(16, .medium))
            Text("Your agent starts one when it needs a screen. Ask it something like:")
                .font(T.sans(13.5)).foregroundStyle(T.muted)
            Terminal(text: "Start a desktop with Safari, open apple.com and tell me the headline.", prompt: "›")
                .frame(maxWidth: 660)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(T.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

private struct DesktopCard: View {
    @EnvironmentObject var model: AppModel
    let session: Session
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(Color(white: 0.02))
                if let vm = session.vm, session.state == .ready {
                    VMDisplay(vm: vm)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(session.state == .starting ? "Starting" : session.state.rawValue.capitalized)
                            .font(T.sans(12)).foregroundStyle(T.faint)
                    }
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .onTapGesture(count: 2) { model.watch(session) }
            Rectangle().fill(T.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Dot(color: color, pulse: session.state == .starting)
                    Text(session.id).font(T.mono(12.5, .medium))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(remaining).font(T.mono(11.5)).foregroundStyle(T.faint)
                    }
                }
                if !session.detail.isEmpty {
                    Text(session.detail).font(T.sans(12)).foregroundStyle(T.muted).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Watch") { model.watch(session) }.buttonStyle(SecondaryButton()).disabled(session.vm == nil)
                    Button("Take control") { model.watch(session); model.toggleControl(session) }
                        .buttonStyle(SecondaryButton()).disabled(session.vm == nil)
                    Spacer()
                    Button("End") { model.stop(session) }.buttonStyle(SecondaryButton(destructive: true))
                }
            }
            .padding(14)
        }
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? T.borderStrong : T.border))
        .onHover { hover = $0 }
    }

    private var remaining: String {
        let m = Int(session.expires.timeIntervalSinceNow / 60)
        guard session.state == .ready else { return session.state.rawValue }
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(max(m, 0))m left"
    }

    private var color: Color {
        switch session.state {
        case .ready: T.green
        case .starting: T.amber
        case .stopping: T.amber
        case .stopped, .failed: T.faint
        }
    }
}

// MARK: agents

private struct AgentsPane: View {
    @EnvironmentObject var model: AppModel
    @State private var reveal = false

    var body: some View {
        PaneHeader(title: "Agents", subtitle: "One MCP server that starts, drives and ends desktops") { EmptyView() }
        AgentsList()
        if let s = model.service {
            Block(title: "Endpoint", detail: "For any other MCP client. Streamable HTTP with a bearer token.") {
                Terminal(text: s.settings.mcpURL, prompt: "URL")
                Terminal(text: "Authorization: Bearer \(s.settings.adminToken)", prompt: "Header",
                         display: "Authorization: Bearer " + String(repeating: "•", count: 24))
            }
            Block(title: "Tools", detail: "What your agent can call.") {
                FlowTags(tags: ["desktop_create", "desktop_open", "desktop_screenshot", "desktop_list", "desktop_end",
                                "observe", "act", "type_text", "click_at", "press", "scroll_at", "commands", "run_command"])
            }
            Block(title: "From another Mac", detail: "Keep the API on this Mac and reach it over Tailscale, then set the public URL in Settings to the https address it prints.") {
                Terminal(text: "tailscale serve --bg \(s.settings.port)")
            }
        }
    }
}

private struct Block<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(T.sans(14, .medium))
                Text(detail).font(T.sans(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 260, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .padding(.top, 20)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
    }
}

private struct FlowTags: View {
    let tags: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(tags, id: \.self) { t in
                Text(t).font(T.mono(12)).foregroundStyle(T.text)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(T.surface))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.border))
            }
        }
    }
}

// MARK: volumes

private struct VolumesPane: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var sizeGB = 10

    var body: some View {
        PaneHeader(title: "Volumes", subtitle: "Disks that outlive desktops, mounted at \(Volume.guestMountPoint)") { EmptyView() }
        if let m = model.manager {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    if m.volumes.isEmpty {
                        Text("No volumes yet. Use one to keep a browser profile, logins or files between desktops.")
                            .font(T.sans(13)).foregroundStyle(T.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    }
                    ForEach(m.volumes, id: \.id) { v in
                        HStack(spacing: 14) {
                            Image(systemName: "externaldrive").foregroundStyle(T.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.meta.name).font(T.sans(14, .medium))
                                Text("\(v.id) · \(v.meta.sizeGB) GB · \(ByteCountFormatter.string(fromByteCount: v.allocatedBytes, countStyle: .file)) used")
                                    .font(T.mono(11.5)).foregroundStyle(T.faint)
                            }
                            Spacer()
                            if let s = m.attachedSession(v.id) {
                                HStack(spacing: 6) { Dot(color: T.green); Text(s).font(T.mono(11.5)).foregroundStyle(T.muted) }
                            }
                            Button("Copy ID") { model.copy(v.id) }.buttonStyle(SecondaryButton())
                            Button("Delete") { model.run { try m.deleteVolume(v.id) } }
                                .buttonStyle(SecondaryButton(destructive: true)).disabled(m.attachedSession(v.id) != nil)
                        }
                        .padding(.horizontal, 18).frame(height: 64)
                        Rectangle().fill(T.border).frame(height: 1)
                    }
                    HStack(spacing: 12) {
                        TextField("Name", text: $name)
                            .textFieldStyle(.plain).font(T.sans(13))
                            .padding(.horizontal, 10).frame(width: 220, height: 32)
                            .background(RoundedRectangle(cornerRadius: 6).fill(T.bg))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.borderStrong))
                        Stepper(value: $sizeGB, in: 1...500) { Text("\(sizeGB) GB").font(T.mono(12.5)) }
                        Spacer()
                        Button("Create volume") {
                            let n = name.isEmpty ? nil : name
                            model.run { _ = try m.createVolume(name: n, sizeGB: sizeGB) }
                            name = ""
                        }
                        .buttonStyle(PrimaryButton())
                    }
                    .padding(.horizontal, 18).frame(height: 64)
                }
            }
        }
    }
}

// MARK: activity

private struct ActivityPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Activity", subtitle: "Sessions, network connections and errors") { EmptyView() }
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if model.log.isEmpty { Text("Nothing yet.").foregroundStyle(T.faint) }
                ForEach(Array(model.log.suffix(200).enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(color(line)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(T.mono(11.5))
            .textSelection(.enabled)
        }
    }

    private func color(_ line: String) -> Color {
        if line.contains(" ERROR ") { return T.red }
        if line.contains(" WARN ") { return T.amber }
        if line.contains("egress") { return T.faint }
        return T.muted
    }
}

// MARK: settings

private struct SettingsPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Settings", subtitle: "This Mac: \(HostSettings.hostCPUs) cores, \(HostSettings.hostMemoryGB) GB memory") { EmptyView() }
        Panel { SettingsSection() }
        Panel(padding: 0) {
            VStack(spacing: 0) {
                SettingRow(title: "Launch at login", detail: "Keep desktops available after a restart.") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                        .labelsHidden().toggleStyle(.switch).tint(T.green)
                }
                Rectangle().fill(T.border).frame(height: 1)
                SettingRow(title: "Golden image", detail: model.imageSummary) {
                    HStack(spacing: 8) {
                        Button("Redo snapshot") { model.run { try await model.builder.finalize() } }
                            .buttonStyle(SecondaryButton()).disabled(model.builder.busy)
                        Button("Set up again") { model.restartOnboarding() }
                            .buttonStyle(SecondaryButton()).disabled(model.builder.busy)
                    }
                }
                if model.builder.busy {
                    ProgressRow(status: model.builder.status, progress: model.builder.progress).padding(18)
                }
            }
        }
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(T.sans(14, .medium))
                Text(detail).font(T.sans(12.5)).foregroundStyle(T.muted)
            }
            Spacer()
            control
        }
        .padding(.horizontal, 18).frame(minHeight: 64)
    }
}
