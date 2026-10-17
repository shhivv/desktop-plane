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
                Text("\(model.liveCount) of \(m.settings.maxVMs) desktops running")
            } else {
                Text("Setup not finished")
            }
            if !m.sessions.isEmpty {
                Divider()
                ForEach(m.sessions) { s in
                    Menu(s.id) {
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
                VStack(spacing: 10) {
                    Text("Desktop Plane couldn't start").font(T.display(22))
                    Text(err).font(T.sans(13)).foregroundStyle(T.muted).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.showOnboarding {
                OnboardingView()
            } else {
                Dashboard()
            }
        }
        .appChrome()
    }
}

// MARK: dashboard

struct Dashboard: View {
    @EnvironmentObject var model: AppModel
    // DP_PANE=agents etc. opens a tab directly, for screenshots.
    @State private var pane: Pane = Pane.allCases.first { $0.rawValue.lowercased() == ProcessInfo.processInfo.environment["DP_PANE"] } ?? .desktops

    enum Pane: String, CaseIterable, Identifiable {
        case desktops = "Desktops", agents = "Agents", volumes = "Volumes", activity = "Activity", settings = "Settings"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(pane: $pane)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let e = model.lastError {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber).font(.system(size: 11))
                            Text(e).foregroundStyle(T.text).textSelection(.enabled)
                            Spacer()
                            Button("Dismiss") { model.lastError = nil }.buttonStyle(LinkButton())
                        }
                        .font(T.sans(13))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.amber.opacity(0.08)))
                    }
                    switch pane {
                    case .desktops: DesktopsPane()
                    case .agents: AgentsPane()
                    case .volumes: VolumesPane()
                    case .activity: ActivityPane()
                    case .settings: SettingsPane()
                    }
                }
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
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
            HStack(spacing: 10) {
                Mark(size: 16)
                Text("Desktop Plane").font(T.sans(14, .semibold))
                Spacer()
                ReachBadge()
            }
            .padding(.leading, 84)
            .padding(.trailing, 20)
            .frame(height: 50)
            HStack(spacing: 2) {
                ForEach(Dashboard.Pane.allCases) { p in
                    Tab(title: p.rawValue, active: p == pane) { pane = p }
                }
                Spacer()
            }
            .padding(.horizontal, 26)
            Rectangle().fill(T.border).frame(height: 1)
        }
        .background(Color.black.opacity(0.12))
    }
}

/// Where agents reach this Mac, at a glance.
private struct ReachBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let s = model.service?.settings {
            let mode = Reachability.mode(s)
            HStack(spacing: 7) {
                LED(on: true, color: mode == .local ? T.amber : T.led)
                Text(mode == .local ? "Only reachable from this Mac" : s.publicURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""))
                    .font(T.sans(12.5)).foregroundStyle(T.muted)
            }
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
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                Rectangle().fill(active ? T.text : .clear).frame(height: 1.5).padding(.horizontal, 10)
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String = "", @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(T.display(26))
                if !subtitle.isEmpty { Text(subtitle).font(T.sans(13.5)).foregroundStyle(T.muted) }
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
        PaneHeader(title: "Desktops", subtitle: "\(model.liveCount) of \(max) running") {
            Button { model.newDesktop() } label: {
                HStack(spacing: 6) {
                    if model.creating { ProgressView().controlSize(.mini) }
                    Text(model.creating ? "Starting…" : "New desktop")
                }
            }
            .buttonStyle(SecondaryButton())
            .disabled(model.liveCount >= max || model.creating)
        }
        if sessions.isEmpty {
            VStack(spacing: 0) {
                MacMini(width: 150, on: false).padding(.bottom, 26)
                Text("No desktops running").font(T.sans(15, .medium))
                Text("Desktops start when an agent asks for one.")
                    .font(T.sans(13.5)).foregroundStyle(T.muted).padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 72)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
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
                Color.black.opacity(0.4)
                if let vm = session.vm, session.state == .ready {
                    VMDisplay(vm: vm)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .onTapGesture(count: 2) { model.watch(session) }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    LED(on: true, color: color, pulse: session.state == .starting)
                    Text(statusLine).font(T.sans(13.5, .medium))
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(remaining).font(T.sans(12.5)).foregroundStyle(T.muted)
                    }
                }
                HStack(spacing: 8) {
                    Text(session.id).font(T.mono(11)).foregroundStyle(T.faint).textSelection(.enabled)
                    Spacer()
                    Button("Watch") { model.watch(session) }.buttonStyle(SecondaryButton()).disabled(session.vm == nil)
                    Button("Take control") { model.watch(session); model.toggleControl(session) }
                        .buttonStyle(SecondaryButton()).disabled(session.vm == nil)
                    Button("End") { model.stop(session) }.buttonStyle(SecondaryButton(destructive: true))
                }
            }
            .padding(14)
        }
        .background(T.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.border))
    }

    private var statusLine: String {
        switch session.state {
        case .starting: "Starting"
        case .ready: session.agentAttached ? "Agent connected" : "Ready"
        case .stopping: "Ending"
        case .stopped, .failed: "Ended"
        }
    }

    private var remaining: String {
        guard session.state == .ready else { return "" }
        let m = max(Int(session.expires.timeIntervalSinceNow / 60), 0)
        return m >= 60 ? "Ends in \(m / 60) h \(m % 60) min" : "Ends in \(m) min"
    }

    private var color: Color {
        switch session.state {
        case .ready: T.led
        case .starting, .stopping: T.amber
        case .stopped, .failed: T.faint
        }
    }
}

// MARK: agents

private struct AgentsPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PaneHeader(title: "Agents", subtitle: "Connected in the last 10 minutes") { EmptyView() }
        Panel(padding: 0) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let agents = model.manager?.connectedAgents ?? []
                VStack(spacing: 0) {
                    if agents.isEmpty {
                        Text("No agents connected.")
                            .font(T.sans(13)).foregroundStyle(T.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(agents) { a in
                        HStack(spacing: 10) {
                            LED()
                            Text(AgentName.pretty(a.name)).font(T.sans(13.5, .medium))
                            Text(a.address.isEmpty || a.address == "127.0.0.1" ? "this Mac" : a.address)
                                .font(T.mono(11)).foregroundStyle(T.faint)
                            Spacer()
                            Text(a.desktops == 1 ? "1 desktop" : "\(a.desktops) desktops").font(T.sans(12.5)).foregroundStyle(T.muted)
                            Text(a.lastSeen, style: .relative).font(T.sans(12.5)).foregroundStyle(T.faint).frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 16).frame(height: 46)
                        if a.id != agents.last?.id { Rectangle().fill(T.border).frame(height: 1) }
                    }
                }
            }
        }
        Block(title: "Add a computer",
              detail: "Run this on the computer where you use Claude Code or Codex.") {
            ConnectInstructions()
        }
        Block(title: "Agents on this Mac", detail: "For Claude Code or Codex installed on this Mac.") {
            LocalAgents()
        }
    }
}

/// A titled section: a short description on the left, its content on the right.
private struct Block<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(T.sans(14, .medium))
                Text(detail).font(T.sans(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 240, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .padding(.top, 18)
        .overlay(alignment: .top) { Rectangle().fill(T.border).frame(height: 1) }
        .padding(.top, 6)
    }
}

/// Adds the plane to Claude Code or Codex on this same Mac.
private struct LocalAgents: View {
    @EnvironmentObject var model: AppModel
    @State private var installed: [AgentSetup.Agent: Bool] = [:]
    @State private var state: [AgentSetup.Agent: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                ForEach(AgentSetup.Agent.allCases, id: \.self) { a in item(a) }
            }
            if let e = state.values.first(where: { $0.hasPrefix("error:") }) {
                Text(String(e.dropFirst(6))).font(T.sans(12.5)).foregroundStyle(T.amber)
            }
        }
        .task {
            for a in AgentSetup.Agent.allCases {
                installed[a] = await AgentSetup.isInstalled(a)
                if installed[a] == true, let s = model.service?.settings, await AgentSetup.isConfigured(a, s) { state[a] = "added" }
            }
        }
    }

    @ViewBuilder private func item(_ a: AgentSetup.Agent) -> some View {
        switch (installed[a], state[a]) {
        case (nil, _):
            Text("Checking for \(a.title)…").font(T.sans(13)).foregroundStyle(T.faint)
        case (false?, _):
            Text("\(a.title) isn't installed").font(T.sans(13)).foregroundStyle(T.faint)
        case (_, "added"?):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(T.green)
                Text("Added to \(a.title)").font(T.sans(13))
            }
        default:
            Button(state[a] == "adding" ? "Adding…" : "Add to \(a.title)") { add(a) }
                .buttonStyle(SecondaryButton())
                .disabled(state[a] == "adding")
        }
    }

    private func add(_ a: AgentSetup.Agent) {
        guard let s = model.service?.settings else { return }
        state[a] = "adding"
        Task {
            do { _ = try await AgentSetup.install(a, s); state[a] = "added" } catch { state[a] = "error:" + error.localizedDescription }
        }
    }
}

// MARK: volumes

private struct VolumesPane: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var sizeGB = 10

    var body: some View {
        PaneHeader(title: "Volumes", subtitle: "Storage that keeps its files after a desktop ends. It appears at \(Volume.guestMountPoint) in the desktop.") { EmptyView() }
        if let m = model.manager {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    if m.volumes.isEmpty {
                        Text("No volumes. Create one to keep files, browser profiles or logins between desktops.")
                            .font(T.sans(13)).foregroundStyle(T.muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    ForEach(m.volumes, id: \.id) { v in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(v.meta.name).font(T.sans(13.5, .medium))
                                Text("\(ByteCountFormatter.string(fromByteCount: v.allocatedBytes, countStyle: .file)) of \(v.meta.sizeGB) GB used")
                                    .font(T.sans(12.5)).foregroundStyle(T.muted)
                            }
                            Spacer()
                            if m.attachedSession(v.id) != nil {
                                HStack(spacing: 6) { LED(); Text("In use").font(T.sans(12.5)).foregroundStyle(T.muted) }
                            }
                            Button("Copy ID") { model.copy(v.id) }.buttonStyle(SecondaryButton())
                            Button("Delete") { model.run { try m.deleteVolume(v.id) } }
                                .buttonStyle(SecondaryButton(destructive: true)).disabled(m.attachedSession(v.id) != nil)
                        }
                        .padding(.horizontal, 16).frame(height: 58)
                        Rectangle().fill(T.border).frame(height: 1)
                    }
                    HStack(spacing: 12) {
                        TextField("New volume name", text: $name)
                            .textFieldStyle(.plain).font(T.sans(13))
                            .padding(.horizontal, 10).frame(width: 220, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.3)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(T.border))
                        Stepper(value: $sizeGB, in: 1...500) { Text("\(sizeGB) GB").font(T.sans(13)).monospacedDigit() }
                        Spacer()
                        Button("Create volume") {
                            let n = name.isEmpty ? nil : name
                            model.run { _ = try m.createVolume(name: n, sizeGB: sizeGB) }
                            name = ""
                        }
                        .buttonStyle(SecondaryButton())
                    }
                    .padding(.horizontal, 16).frame(height: 58)
                }
            }
        }
    }
}

// MARK: activity

private struct ActivityPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PaneHeader(title: "Activity") { EmptyView() }
        Panel(padding: 14) {
            VStack(alignment: .leading, spacing: 3) {
                if model.log.isEmpty { Text("No activity yet.").font(T.sans(13)).foregroundStyle(T.faint) }
                ForEach(Array(model.log.suffix(200).enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(color(line)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(T.mono(10.5))
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
        PaneHeader(title: "Settings") { EmptyView() }
        Block(title: "Network access", detail: "How your computer connects to this Mac.") { ReachOptions() }
        Block(title: "Desktops", detail: "This Mac has \(HostSettings.hostCPUs) cores and \(HostSettings.hostMemoryGB) GB of memory.") { SettingsSection() }
        Block(title: "macOS image", detail: model.imageSummary) {
            HStack(spacing: 8) {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                    .toggleStyle(.switch).controlSize(.small).font(T.sans(13))
                Spacer()
                Button("Save new snapshot") { model.run { try await model.builder.finalize() } }
                    .buttonStyle(SecondaryButton()).disabled(model.builder.busy)
                Button("Run setup again") { model.restartOnboarding() }
                    .buttonStyle(SecondaryButton()).disabled(model.builder.busy)
            }
            if model.builder.busy { ProgressRow(status: model.builder.status, progress: model.builder.progress) }
        }
    }
}
