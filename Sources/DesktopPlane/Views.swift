import PlaneHost
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let err = model.startError {
            Text("Not running: \(err)")
        } else if let m = model.manager {
            Text("\(model.liveCount) of \(m.settings.maxVMs) desktops in use")
            Text("Image: \(model.imageStage?.rawValue ?? "not built")")
            if !m.sessions.isEmpty {
                Divider()
                ForEach(m.sessions) { s in
                    Menu("\(s.id) · \(s.state.rawValue)") {
                        Button("Watch") { model.watch(s) }
                        Button("Stop", role: .destructive) { model.stop(s) }
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
            Button("Copy API URL") { model.copy(s.baseURL) }
            Button("Copy Admin Token") { model.copy(s.settings.adminToken) }
        }
        Divider()
        Button("Quit (stops all desktops)") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let err = model.startError {
                    Banner(text: err, color: .red)
                }
                if let err = model.lastError {
                    Banner(text: err, color: .orange)
                }
                ImageSection()
                SessionsSection()
                ConnectSection()
                SettingsSection()
                LogSection()
            }
            .padding(24)
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .textSelection(.enabled)
    }
}

struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ImageSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let stage = model.imageStage
        let b = model.builder
        Section(title: "Golden image") {
            Step(n: 1, title: "Install macOS", detail: "Downloads the latest macOS for this Mac (~17 GB) and installs it.",
                 done: stage != nil, enabled: !b.busy) {
                model.run { try await b.install() }
            }
            Step(n: 2, title: "Provision",
                 detail: "Opens the VM. Finish Setup Assistant, run  bash \"/Volumes/My Shared Files/install.sh\"  in Terminal, grant the two permissions it asks for, then shut the VM down.",
                 done: stage == .provisioned || stage == .ready, enabled: !b.busy && stage != nil) {
                model.run { try await b.provision() }
            }
            Step(n: 3, title: "Snapshot", detail: "Boots it locked down, checks the agent, and saves the state every desktop starts from.",
                 done: stage == .ready, enabled: !b.busy && (stage == .provisioned || stage == .ready)) {
                model.run { try await b.finalize() }
            }
            if b.busy || !b.status.isEmpty {
                HStack {
                    if b.busy { ProgressView().controlSize(.small) }
                    Text(b.status).foregroundStyle(.secondary)
                }
                if let p = b.progress { ProgressView(value: p) }
            }
        }
    }
}

struct Step: View {
    let n: Int
    let title: String
    let detail: String
    let done: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(n).circle")
                .foregroundStyle(done ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button(done ? "Redo" : "Start", action: action).disabled(!enabled)
        }
    }
}

struct SessionsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(title: "Desktops") {
            if let m = model.manager, !m.sessions.isEmpty {
                ForEach(m.sessions) { s in
                    HStack {
                        Circle().fill(color(s.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading) {
                            Text(s.id).font(.system(.body, design: .monospaced))
                            Text("\(s.state.rawValue) · \(s.bootMode) · expires \(s.expires.formatted(date: .omitted, time: .shortened)) · \(s.detail)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Watch") { model.watch(s) }.disabled(s.vm == nil)
                        Button("Take Control") { model.watch(s); model.toggleControl(s) }.disabled(s.vm == nil)
                        Button("Stop") { model.stop(s) }
                    }
                }
            } else {
                Text("No desktops running. Create one through the API.").foregroundStyle(.secondary)
            }
        }
    }

    func color(_ s: Session.State) -> Color {
        switch s {
        case .ready: .green
        case .starting: .yellow
        case .stopping: .orange
        case .stopped, .failed: .gray
        }
    }
}

struct ConnectSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(title: "Connect") {
            if let s = model.service {
                let create = """
                curl -s -X POST \(s.baseURL)/v1/sessions \\
                  -H "Authorization: Bearer $(pbpaste)" -d '{"ttl_seconds": 3600}'
                """
                Text("1. Copy the admin token, then create a desktop:").font(.callout)
                Code(create)
                Text("2. Point any MCP client at the returned mcp_url with the returned token:").font(.callout)
                Code("claude mcp add --transport http desk <mcp_url> --header \"Authorization: Bearer <token>\"")
                HStack {
                    Button("Copy Admin Token") { model.copy(s.settings.adminToken) }
                    Button("Copy API URL") { model.copy(s.baseURL) }
                    Spacer()
                    Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
                }
            }
        }
    }
}

struct Code: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct LogSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section(title: "Log") {
            ScrollView {
                Text(model.log.suffix(80).joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
        }
    }
}
