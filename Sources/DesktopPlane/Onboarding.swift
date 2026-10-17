import PlaneHost
import SwiftUI
import Virtualization

/// First run: check the Mac, build the golden image, connect an agent. One step on screen at a
/// time; each step knows from the image's stage whether it is done, so quitting halfway and
/// reopening the app picks up where it left off.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    enum Step: Int, CaseIterable {
        case welcome, install, setup, snapshot, connect
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .install: "Install macOS"
            case .setup: "Set up the desktop"
            case .snapshot: "Save the snapshot"
            case .connect: "Connect your agent"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Rail(current: model.onboardingStep)
                .frame(width: 230)
                .background(Color.primary.opacity(0.035))
            Divider()
            Group {
                switch model.onboardingStep {
                case .welcome: WelcomeStep()
                case .install: InstallStep()
                case .setup: SetupStep()
                case .snapshot: SnapshotStep()
                case .connect: ConnectStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: model.onboardingStep)
    }
}

/// The step list down the left side.
private struct Rail: View {
    let current: OnboardingView.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppGlyph(size: 28)
                Text("Desktop Plane").font(.headline)
            }
            .padding(.bottom, 28)
            ForEach(OnboardingView.Step.allCases, id: \.self) { step in
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(step.rawValue < current.rawValue ? Color.accentColor : .clear)
                            .strokeBorder(step.rawValue <= current.rawValue ? Color.accentColor : .secondary.opacity(0.4), lineWidth: 1.5)
                            .frame(width: 20, height: 20)
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(step.rawValue + 1)").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(step == current ? Color.accentColor : .secondary)
                        }
                    }
                    Text(step.title)
                        .fontWeight(step == current ? .semibold : .regular)
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                }
                .padding(.vertical, 9)
            }
            Spacer()
            Text("About 30 minutes, most of it waiting on the macOS download.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Shared layout for a step: title, subtitle, content, and the buttons at the bottom.
private struct StepPage<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 26, weight: .semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 620, alignment: .leading)
            content.padding(.top, 28)
            Spacer(minLength: 20)
            HStack {
                ErrorLine()
                Spacer()
                actions
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ErrorLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let e = model.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout).lineLimit(3).textSelection(.enabled)
        }
    }
}

// MARK: 1. welcome

private struct WelcomeStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let checks = HostCheck.all()
        StepPage(title: "Turn this Mac into desktops for your agents",
                 subtitle: "Desktop Plane runs throwaway macOS desktops that Claude Code, Codex or any MCP client can drive. Each one is a fresh VM, sealed off from this Mac and your network, and deleted when the agent is done.") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(checks) { c in
                    HStack(spacing: 12) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : (c.blocking ? "xmark.circle.fill" : "exclamationmark.circle.fill"))
                            .foregroundStyle(c.ok ? .green : (c.blocking ? .red : .orange))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).fontWeight(.medium)
                            Text(c.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } actions: {
            Button("Get Started") { model.onboardingStep = .install }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(checks.contains { $0.blocking && !$0.ok })
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct HostCheck: Identifiable {
    let id: String
    let title: String
    let detail: String
    let ok: Bool
    let blocking: Bool

    static func all() -> [HostCheck] {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let freeGB = Int((values?.volumeAvailableCapacityForImportantUsage ?? 0) >> 30)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            HostCheck(id: "cpu", title: "Apple silicon", detail: "macOS VMs need an M-series Mac.",
                      ok: VZVirtualMachine.isSupported, blocking: true),
            HostCheck(id: "os", title: "macOS \(os.majorVersion).\(os.minorVersion)",
                      detail: os.majorVersion >= 15 ? "Everything is supported, including data volumes." : "Works; data volumes need macOS 15.",
                      ok: os.majorVersion >= 15, blocking: false),
            HostCheck(id: "mem", title: "\(HostSettings.hostMemoryGB) GB memory",
                      detail: HostSettings.hostMemoryGB >= 16 ? "Room for two desktops at 8 GB each." : "One desktop at a time is best on this Mac.",
                      ok: HostSettings.hostMemoryGB >= 16, blocking: false),
            HostCheck(id: "disk", title: "\(freeGB) GB free",
                      detail: freeGB >= 60 ? "The image and macOS download take about 60 GB." : "Free up to about 60 GB for the image and the macOS download.",
                      ok: freeGB >= 60, blocking: freeGB < 40),
        ]
    }
}

// MARK: 2. install

private struct InstallStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.builder
        let done = model.imageStage != nil && !b.busy
        StepPage(title: "Install macOS",
                 subtitle: "Downloads the latest macOS this Mac supports (about 17 GB) and installs it into a new virtual disk. You can leave this running and come back.") {
            VStack(alignment: .leading, spacing: 12) {
                if b.busy {
                    ProgressRow(status: b.status, progress: b.progress)
                } else if done {
                    Label("macOS is installed.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        } actions: {
            if done {
                Button("Continue") { model.onboardingStep = .setup }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Button("Install macOS") { model.run { try await b.install() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(b.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct ProgressRow: View {
    let status: String
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear)
                HStack {
                    Text(status)
                    Spacer()
                    Text("\(Int(progress * 100))%").monospacedDigit()
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 520)
    }
}

// MARK: 3. setup (provision)

private struct SetupStep: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    static let command = #"bash "/Volumes/My Shared Files/install.sh""#

    var body: some View {
        let b = model.builder
        let running = b.provisioningVM != nil
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Set up the desktop").font(.system(size: 26, weight: .semibold))
                Text("A few clicks inside the VM that macOS only lets a person make. You do this once; every desktop starts from the result.")
                    .foregroundStyle(.secondary).padding(.top, 6).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 18) {
                    Instruction(n: 1, title: "Finish Setup Assistant",
                                detail: "Create a local account with any name and password. Skip Apple Account, Location Services and Siri.")
                    Instruction(n: 2, title: "Run the installer in Terminal",
                                detail: "Open Terminal in the VM (Spotlight: ⌘ Space, type Terminal) and type:") {
                        HStack(spacing: 8) {
                            Text(Self.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .lineLimit(1).fixedSize()
                            Spacer(minLength: 0)
                            Button(copied ? "Copied" : "Copy") { model.copy(Self.command); copied = true }
                                .controlSize(.small)
                        }
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Instruction(n: 3, title: "Allow the two permissions",
                                detail: "The installer opens System Settings for Accessibility and Screen Recording. Turn on Desktop Plane Agent in both.")
                    Instruction(n: 4, title: "Shut down",
                                detail: "When the installer says Done, choose Shut Down from the Apple menu. Desktop Plane continues by itself.")
                }
                .padding(.top, 24)
                Spacer(minLength: 16)
                ErrorLine()
            }
            .frame(width: 360)

            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.85))
                    if let vm = b.provisioningVM {
                        VMDisplay(vm: vm, interactive: true).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "macwindow").font(.system(size: 40, weight: .light))
                            Text("The VM appears here").font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                if running {
                    HStack {
                        Text("Click inside the VM to type there.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open in Window") { model.popOutProvisioning() }.controlSize(.small)
                    }
                } else {
                    HStack {
                        if b.busy { ProgressView().controlSize(.small); Text(b.status).foregroundStyle(.secondary).font(.callout) }
                        Spacer()
                        Button("Start the VM") { model.provision() }
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(b.busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(32)
    }
}

private struct Instruction<Extra: View>: View {
    let n: Int
    let title: String
    let detail: String
    @ViewBuilder var extra: Extra

    init(n: Int, title: String, detail: String, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.n = n
        self.title = title
        self.detail = detail
        self.extra = extra()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                extra
            }
        }
    }
}

// MARK: 4. snapshot

private struct SnapshotStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.builder
        let ready = model.imageStage == .ready && !b.busy
        StepPage(title: "Save the snapshot",
                 subtitle: "Desktop Plane boots the image locked down, checks that the agent and its permissions work, and saves the running machine. Desktops start from this snapshot in seconds.") {
            VStack(alignment: .leading, spacing: 12) {
                if b.busy {
                    ProgressRow(status: b.status, progress: b.progress)
                } else if ready {
                    Label(b.status.isEmpty ? "Snapshot saved." : b.status, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } actions: {
            if ready {
                Button("Continue") { model.onboardingStep = .connect }
                    .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { model.onboardingStep = .setup }.disabled(b.busy)
                Button(model.lastError == nil ? "Save Snapshot" : "Try Again") { model.run { try await b.finalize() } }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(b.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            // Straight on from setup: nothing to decide here.
            if model.imageStage == .provisioned, !b.busy, model.lastError == nil { model.run { try await b.finalize() } }
        }
    }
}

// MARK: 5. connect

private struct ConnectStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Connect your agent",
                 subtitle: "Add Desktop Plane to your coding agent once. It can then start desktops, open apps, see the screen, click and type, and end the desktop when it is done.") {
            AgentsList()
        } actions: {
            Button("Done") { model.finishOnboarding() }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }
}

/// One row per supported agent, with a button that adds the plane to it. Used in onboarding
/// and on the dashboard.
struct AgentsList: View {
    @EnvironmentObject var model: AppModel
    @State private var installed: [AgentSetup.Agent: Bool] = [:]
    @State private var state: [AgentSetup.Agent: String] = [:]
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AgentSetup.Agent.allCases, id: \.self) { agent in
                HStack(spacing: 14) {
                    Image(systemName: agent == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.title).fontWeight(.medium)
                        Text(subtitle(agent)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Group {
                        if state[agent] == "adding" {
                            ProgressView().controlSize(.small)
                        } else if state[agent] == "added" {
                            Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Add") { add(agent) }
                                .buttonStyle(.borderedProminent)
                                .disabled(installed[agent] != true || model.service == nil)
                        }
                    }
                    .frame(width: 90, alignment: .trailing)
                }
            }
            if let s = model.service {
                Text("Then ask it, for example: “Start a desktop with Safari, open apple.com and tell me the headline.”")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                DisclosureGroup("Other MCP clients", isExpanded: $showManual) {
                    VStack(alignment: .leading, spacing: 8) {
                        CopyField(label: "URL", value: s.settings.mcpURL)
                        CopyField(label: "Header", value: "Authorization: Bearer \(s.settings.adminToken)", secret: true)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .task {
            for a in AgentSetup.Agent.allCases {
                installed[a] = await AgentSetup.isInstalled(a)
                if installed[a] == true, let s = model.service?.settings, await AgentSetup.isConfigured(a, s) { state[a] = "added" }
            }
        }
    }

    private func subtitle(_ a: AgentSetup.Agent) -> String {
        if let s = state[a], s.hasPrefix("error:") { return String(s.dropFirst(6)) }
        switch installed[a] {
        case nil: return "Looking for \(a.rawValue)…"
        case false?: return "\(a.rawValue) isn't installed on this Mac"
        case true?: return state[a] == "added" ? "Connected. New \(a.rawValue) sessions have the desktop tools." : "Adds the desktop-plane MCP server to your user config."
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

struct CopyField: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let value: String
    var secret = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Text(secret ? String(value.prefix(30)) + "…" : value)
                .font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Button(copied ? "Copied" : "Copy") { model.copy(value); copied = true }.controlSize(.small)
        }
        .padding(8)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: shared pieces

/// The app's mark: a window over a window, on an accent squircle.
struct AppGlyph: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 1), Color(red: 0.42, green: 0.25, blue: 0.95)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "macwindow.on.rectangle").font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.white))
    }
}

/// A live view of a VM's screen. Watch-only unless `interactive`.
struct VMDisplay: NSViewRepresentable {
    let vm: VZVirtualMachine
    var interactive = false

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = interactive
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = false }
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        let shield = Shield()
        shield.autoresizingMask = [.width, .height]
        shield.isHidden = interactive
        container.addSubview(shield)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        for v in nsView.subviews { v.frame = nsView.bounds }
        if let view = nsView.subviews.first as? VZVirtualMachineView, view.virtualMachine !== vm { view.virtualMachine = vm }
        nsView.subviews.last?.isHidden = interactive
    }

    final class Shield: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : self }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
    }
}
