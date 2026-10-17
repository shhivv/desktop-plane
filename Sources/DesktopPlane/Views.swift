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
                ContentUnavailableView("Desktop Plane couldn't start", systemImage: "exclamationmark.triangle", description: Text(err))
            } else if model.showOnboarding {
                OnboardingView()
            } else {
                Dashboard()
            }
        }
    }
}

// MARK: dashboard

struct Dashboard: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: Pane = .desktops

    enum Pane: String, CaseIterable, Identifiable {
        case desktops = "Desktops", agents = "Agents", volumes = "Volumes", activity = "Activity", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .desktops: "macwindow.on.rectangle"
            case .agents: "sparkles"
            case .volumes: "externaldrive"
            case .activity: "list.bullet.rectangle"
            case .settings: "gearshape"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? .desktops })) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
            .safeAreaInset(edge: .bottom) { StatusFooter().padding(14) }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let e = model.lastError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .textSelection(.enabled)
                    }
                    switch pane {
                    case .desktops: DesktopsPane()
                    case .agents: AgentsPane()
                    case .volumes: VolumesPane()
                    case .activity: ActivityPane()
                    case .settings: SettingsPane()
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(pane.rawValue)
        }
    }
}

private struct StatusFooter: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.service == nil ? .gray : .green).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.service == nil ? "Stopped" : "Serving").font(.caption).fontWeight(.medium)
                if let s = model.service {
                    Text(s.settings.mcpURL.replacingOccurrences(of: "http://", with: "")).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
        }
    }
}

private struct PaneHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: desktops

private struct DesktopsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sessions = model.manager?.sessions ?? []
        let max = model.manager?.settings.maxVMs ?? 2
        PaneHeader(title: "Desktops", subtitle: "\(model.liveCount) of \(max) in use · each one is deleted when it ends") {
            Button { model.newDesktop() } label: { Label("New Desktop", systemImage: "plus") }
                .disabled(model.liveCount >= max || model.creating)
        }
        if sessions.isEmpty {
            VStack(spacing: 12) {
                AppGlyph(size: 56).opacity(0.9)
                Text("No desktops running").font(.title3).fontWeight(.medium)
                Text("Your agent starts one when it calls desktop_create. You can also start one here to look around.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                ForEach(sessions) { DesktopCard(session: $0) }
            }
        }
    }
}

private struct DesktopCard: View {
    @EnvironmentObject var model: AppModel
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let vm = session.vm, session.state == .ready {
                    VMDisplay(vm: vm)
                } else {
                    ProgressView().controlSize(.small).tint(.white)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .onTapGesture(count: 2) { model.watch(session) }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(session.id).font(.system(.callout, design: .monospaced)).fontWeight(.medium)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(remaining).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !session.detail.isEmpty {
                    Text(session.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    Button("Watch") { model.watch(session) }.disabled(session.vm == nil)
                    Button("Take Control") { model.watch(session); model.toggleControl(session) }.disabled(session.vm == nil)
                    Spacer()
                    Button("End", role: .destructive) { model.stop(session) }
                }
                .controlSize(.small)
            }
            .padding(12)
        }
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }

    private var remaining: String {
        let m = Int(session.expires.timeIntervalSinceNow / 60)
        return session.state == .ready ? (m >= 60 ? "\(m / 60) h \(m % 60) min left" : "\(max(m, 0)) min left") : session.state.rawValue
    }

    private var color: Color {
        switch session.state {
        case .ready: .green
        case .starting: .yellow
        case .stopping: .orange
        case .stopped, .failed: .gray
        }
    }
}

// MARK: agents

private struct AgentsPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Agents", subtitle: "One MCP server that starts, drives and ends desktops") { EmptyView() }
        Card { AgentsList() }
        if let s = model.service {
            Card {
                Text("Tools your agent gets").fontWeight(.medium)
                Text("desktop_create, desktop_open, desktop_screenshot, desktop_list, desktop_end, plus the driver's observe, act, type_text, click_at and the rest. Driver tools take an optional desktop id.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Card {
                Text("From another Mac").fontWeight(.medium)
                Text("Keep the API on this Mac and reach it over Tailscale: run  tailscale serve --bg \(s.settings.port)  here, then set the public URL in Settings to the https address it prints. Agents elsewhere use that URL with the same token.")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
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
        PaneHeader(title: "Volumes", subtitle: "Disks that outlive desktops. One mounts at \(Volume.guestMountPoint) when a desktop asks for it.") { EmptyView() }
        if let m = model.manager {
            Card {
                if m.volumes.isEmpty {
                    Text("No volumes yet. Use one to keep a browser profile, logins or files between desktops.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(m.volumes, id: \.id) { v in
                    HStack {
                        Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.meta.name).fontWeight(.medium)
                            Text("\(v.id) · \(v.meta.sizeGB) GB · \(ByteCountFormatter.string(fromByteCount: v.allocatedBytes, countStyle: .file)) used · "
                                 + (m.attachedSession(v.id).map { "in use by \($0)" } ?? "free"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Copy ID") { model.copy(v.id) }.controlSize(.small)
                        Button("Delete", role: .destructive) { model.run { try m.deleteVolume(v.id) } }
                            .controlSize(.small).disabled(m.attachedSession(v.id) != nil)
                    }
                    if v.id != m.volumes.last?.id { Divider() }
                }
            }
            Card {
                HStack {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 200)
                    Stepper("\(sizeGB) GB", value: $sizeGB, in: 1...500)
                    Spacer()
                    Button("Create Volume") {
                        let n = name.isEmpty ? nil : name
                        model.run { _ = try m.createVolume(name: n, sizeGB: sizeGB) }
                        name = ""
                    }
                }
            }
        }
    }
}

// MARK: activity

private struct ActivityPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Activity", subtitle: "Sessions, network connections and errors, newest last") { EmptyView() }
        Card {
            Text(model.log.suffix(200).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: settings

private struct SettingsPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Settings", subtitle: "This Mac: \(HostSettings.hostCPUs) cores, \(HostSettings.hostMemoryGB) GB memory") { EmptyView() }
        Card { SettingsSection() }
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login").fontWeight(.medium)
                    Text("Keep desktops available after a restart.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })).labelsHidden().toggleStyle(.switch)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Golden image").fontWeight(.medium)
                    Text(model.imageSummary).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Redo Snapshot") { model.run { try await model.builder.finalize() } }.disabled(model.builder.busy)
                Button("Set Up Again…") { model.restartOnboarding() }.disabled(model.builder.busy)
            }
            if model.builder.busy { ProgressRow(status: model.builder.status, progress: model.builder.progress) }
        }
    }
}
