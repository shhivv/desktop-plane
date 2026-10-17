import PlaneHost
import SwiftUI
import Virtualization

/// First run on the spare Mac: check it, build the golden image, make it reachable, and connect
/// the agents on the person's own computer. Each step knows from the image's stage and the
/// settings whether it is done, so quitting halfway picks up where it left off.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel

    enum Step: Int, CaseIterable {
        case welcome, install, setup, snapshot, reach, connect
        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .install: "Install macOS"
            case .setup: "Set up"
            case .snapshot: "Snapshot"
            case .reach: "Network"
            case .connect: "Connect"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopProgress(current: model.onboardingStep)
            Group {
                switch model.onboardingStep {
                case .welcome: WelcomeStep()
                case .install: InstallStep()
                case .setup: SetupStep()
                case .snapshot: SnapshotStep()
                case .reach: ReachStep()
                case .connect: ConnectStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: model.onboardingStep)
    }
}

/// The mark on the left, the steps across the top right.
private struct TopProgress: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Mark(size: 16)
                Text("Desktop Plane").font(T.sans(14, .semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingView.Step.allCases, id: \.self) { s in
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(s.rawValue <= current.rawValue ? T.text : Color.white.opacity(0.1)).frame(height: 2)
                        Text(s.title).font(T.sans(11.5, s == current ? .medium : .regular))
                            .foregroundStyle(s == current ? T.text : T.faint)
                    }
                    .frame(width: 78)
                }
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 28)
        .padding(.top, 12)
        .frame(height: 60)
    }
}

/// A step's column: title, subtitle, content, then actions at the bottom.
private struct StepPage<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(T.display(34)).padding(.top, 4)
            Text(subtitle).font(T.sans(15)).foregroundStyle(T.muted).lineSpacing(3).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            content.padding(.top, 28)
            Spacer(minLength: 16)
            HStack(spacing: 10) {
                ErrorLine()
                Spacer()
                actions
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(.top, 40)
        .padding(.bottom, 32)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ErrorLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let e = model.lastError {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber).font(.system(size: 11))
                Text(e).foregroundStyle(T.muted).lineLimit(4).textSelection(.enabled)
            }
            .font(T.sans(12.5))
        }
    }
}

// MARK: 1. welcome

private struct WelcomeStep: View {
    @EnvironmentObject var model: AppModel
    @State private var lit = false

    var body: some View {
        let checks = HostCheck.all()
        StepPage(title: "Set up this Mac for computer use",
                 subtitle: "Agents on your computer, like Claude Code and Codex, can use this Mac to control macOS apps. Each task gets its own macOS virtual machine, which is deleted when the task ends.") {
            MacMini(width: 210, on: lit)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { lit = true } }
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { i, c in
                        CheckRow(check: c)
                        if i < checks.count - 1 { Rectangle().fill(T.border).frame(height: 1).padding(.leading, 44) }
                    }
                }
            }
            .padding(.top, 20)
        } actions: {
            Button("Get started") { model.onboardingStep = .install }
                .buttonStyle(PrimaryButton(large: true))
                .disabled(checks.contains { $0.blocking && !$0.ok })
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct CheckRow: View {
    let check: HostCheck
    var body: some View {
        let color = check.ok ? T.green : (check.blocking ? T.red : T.amber)
        HStack(spacing: 12) {
            Image(systemName: check.ok ? "checkmark" : (check.blocking ? "xmark" : "exclamationmark"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(check.title).font(T.sans(13.5, .medium))
            Spacer()
            Text(check.detail).font(T.sans(13)).foregroundStyle(T.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
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
            HostCheck(id: "cpu", title: "Apple silicon", detail: VZVirtualMachine.isSupported ? "Supported" : "macOS VMs need an M-series Mac",
                      ok: VZVirtualMachine.isSupported, blocking: true),
            HostCheck(id: "os", title: "macOS \(os.majorVersion).\(os.minorVersion)",
                      detail: os.majorVersion >= 15 ? "Supported" : "Volumes need macOS 15",
                      ok: os.majorVersion >= 15, blocking: false),
            HostCheck(id: "mem", title: "\(HostSettings.hostMemoryGB) GB memory",
                      detail: HostSettings.hostMemoryGB >= 16 ? "Two desktops at once" : "One desktop at a time",
                      ok: HostSettings.hostMemoryGB >= 16, blocking: false),
            HostCheck(id: "disk", title: "\(freeGB) GB free",
                      detail: freeGB >= 60 ? "About 60 GB needed" : "Free up about 60 GB",
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
                 subtitle: "Downloads macOS (about 17 GB) and installs it in a virtual machine.") {
            if b.busy {
                ProgressRow(status: b.status, progress: b.progress)
            } else if done {
                Done(text: "macOS is installed")
            }
        } actions: {
            if done {
                Button("Continue") { model.onboardingStep = .setup }
                    .buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { model.onboardingStep = .welcome }.buttonStyle(SecondaryButton(large: true)).disabled(b.busy)
                Button("Install macOS") { model.run { try await b.install() } }
                    .buttonStyle(PrimaryButton(large: true)).disabled(b.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct Done: View {
    let text: String
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(T.green)
            Text(text).font(T.sans(14, .medium))
        }
    }
}

struct ProgressRow: View {
    let status: String
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(status).font(T.sans(13)).foregroundStyle(T.muted)
                Spacer()
                if let progress { Text("\(Int(progress * 100))%").font(T.sans(13, .medium)).monospacedDigit() }
            }
            if let progress {
                ProgressView(value: progress).progressViewStyle(.linear).tint(T.text)
            } else {
                ProgressView().progressViewStyle(.linear).tint(T.text)
            }
        }
    }
}

// MARK: 3. setup (provision)

private struct SetupStep: View {
    static let command = #"bash "/Volumes/My Shared Files/install.sh""#

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            SetupInstructions().frame(width: 400)
            SetupScreen().frame(maxWidth: .infinity).padding(.top, 8)
        }
        .padding(.horizontal, 44)
        .padding(.top, 40)
        .padding(.bottom, 32)
    }
}

private struct SetupInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set up macOS").font(T.display(34)).padding(.top, 4)
            Text("Finish setting up the virtual machine. You only do this once.")
                .font(T.sans(14)).foregroundStyle(T.muted).lineSpacing(3).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 20) {
                Instruction(n: 1, title: "Finish Setup Assistant",
                            detail: "Create a local account. You can skip Apple Account, Location Services and Siri.")
                Instruction(n: 2, title: "Run the installer",
                            detail: "Open Terminal in the virtual machine and run:") {
                    Terminal(text: SetupStep.command, fit: true).padding(.top, 4)
                }
                Instruction(n: 3, title: "Give the agent permissions",
                            detail: "In System Settings, turn on Desktop Plane Agent under Accessibility and under Screen Recording.")
                Instruction(n: 4, title: "Shut down",
                            detail: "When the installer finishes, choose Shut Down from the Apple menu.")
            }
            .padding(.top, 28)
            Spacer(minLength: 16)
            ErrorLine()
        }
    }
}

private struct SetupScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.builder
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                if let vm = b.provisioningVM {
                    VMDisplay(vm: vm, interactive: true).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Text("The virtual machine appears here.").font(T.sans(13)).foregroundStyle(T.faint)
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.border))
            HStack(spacing: 10) {
                if b.provisioningVM != nil {
                    LED(pulse: true)
                    Text("Running. Click inside to type.").font(T.sans(12.5)).foregroundStyle(T.muted)
                    Spacer()
                    Button("Open in window") { model.popOutProvisioning() }.buttonStyle(SecondaryButton())
                } else {
                    if b.busy { Text(b.status).font(T.sans(12.5)).foregroundStyle(T.muted) }
                    Spacer()
                    Button("Start virtual machine") { model.provision() }
                        .buttonStyle(PrimaryButton(large: true)).disabled(b.busy)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(T.sans(13, .medium)).foregroundStyle(T.faint).frame(width: 12, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(T.sans(14, .medium))
                Text(detail).font(T.sans(13)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
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
        StepPage(title: "Save a snapshot",
                 subtitle: "Saves the set-up virtual machine so new desktops start in seconds.") {
            if b.busy {
                ProgressRow(status: b.status, progress: b.progress)
            } else if ready {
                Done(text: "Snapshot saved")
            }
        } actions: {
            if ready {
                Button("Continue") { model.onboardingStep = .reach }
                    .buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
            } else {
                Button("Back") { model.onboardingStep = .setup }.buttonStyle(SecondaryButton(large: true)).disabled(b.busy)
                Button(model.lastError == nil ? "Save snapshot" : "Try again") { model.run { try await b.finalize() } }
                    .buttonStyle(PrimaryButton(large: true)).disabled(b.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear {
            // Straight on from setup: nothing to decide here.
            if model.imageStage == .provisioned, !b.busy, model.lastError == nil { model.run { try await b.finalize() } }
        }
    }
}

// MARK: 5. reach

private struct ReachStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Turn on network access",
                 subtitle: "Choose how your computer connects to this Mac.") {
            ReachOptions()
        } actions: {
            Button("Back") { model.onboardingStep = .snapshot }.buttonStyle(SecondaryButton(large: true))
            Button("Continue") { model.onboardingStep = .connect }
                .buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
                .disabled(model.reachMode == .local)
        }
    }
}

/// Tailscale or the local network, with what each one means. Used in onboarding and Settings.
struct ReachOptions: View {
    @EnvironmentObject var model: AppModel
    @State private var tailnet: Reachability.Tailnet?
    @State private var checked = false
    @State private var working: Reachability.Mode?

    var body: some View {
        let mode = model.reachMode
        VStack(spacing: 10) {
            Option(selected: mode == .tailscale, title: "Tailscale", badge: "Recommended",
                   detail: tailscaleDetail) {
                if mode == .tailscale {
                    Text(model.service?.settings.publicURL ?? "").font(T.mono(11.5)).foregroundStyle(T.muted)
                } else if working == .tailscale {
                    ProgressView().controlSize(.small)
                } else if !Reachability.tailscaleInstalled {
                    Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
                        .buttonStyle(SecondaryButton())
                } else if checked && tailnet == nil {
                    Button("Open Tailscale") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
                        .buttonStyle(SecondaryButton())
                } else {
                    Button("Use Tailscale") { use(.tailscale) }.buttonStyle(PrimaryButton()).disabled(!checked)
                }
            }
            Option(selected: mode == .lan, title: "Same network",
                   detail: "Your computer must be on the same network. Traffic, including the access token, is not encrypted.") {
                if mode == .lan {
                    Text(model.service?.settings.publicURL ?? "").font(T.mono(11.5)).foregroundStyle(T.muted)
                } else {
                    Button("Use this network") { use(.lan) }.buttonStyle(SecondaryButton())
                }
            }
            if mode != .local {
                HStack {
                    Spacer()
                    Button("Turn off network access") { use(.local) }.buttonStyle(LinkButton())
                }
            }
        }
        .task { await refresh() }
    }

    private var tailscaleDetail: String {
        if !Reachability.tailscaleInstalled { return "Works from any network and encrypts traffic. Install Tailscale on this Mac and your computer, and sign in to the same account on both." }
        if checked && tailnet == nil { return "Tailscale is installed but not signed in." }
        return "Works from any network and encrypts traffic. Needs Tailscale on your computer too."
    }

    private func refresh() async {
        tailnet = await Reachability.tailnet()
        checked = true
    }

    private func use(_ m: Reachability.Mode) {
        guard let s = model.service?.settings else { return }
        working = m
        model.run {
            let n: HostSettings
            switch m {
            case .tailscale: n = try await Reachability.useTailscale(s)
            case .lan: n = Reachability.useLAN(s)
            case .local: n = await Reachability.useLocalOnly(s)
            }
            try model.service?.apply(n)
            working = nil
        }
        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); working = nil; await refresh() }
    }
}

private struct Option<Trailing: View>: View {
    let selected: Bool
    let title: String
    var badge: String?
    let detail: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .strokeBorder(selected ? T.text : Color.white.opacity(0.2), lineWidth: selected ? 4.5 : 1)
                .frame(width: 15, height: 15)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(T.sans(14, .medium))
                    if let badge {
                        Text(badge).font(T.sans(11, .medium)).foregroundStyle(T.lamp)
                    }
                }
                Text(detail).font(T.sans(12.5)).foregroundStyle(T.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? T.raised : T.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? T.borderStrong : T.border))
    }
}

// MARK: 6. connect

private struct ConnectStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(title: "Add Desktop Plane to your agent",
                 subtitle: "Run this on the computer where you use Claude Code or Codex.") {
            ConnectInstructions()
        } actions: {
            Button("Done") { model.finishOnboarding() }
                .buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
        }
    }
}

/// The commands for the person's own computer, and a live line that turns on when an agent
/// connects. Used in onboarding and on the Agents tab.
struct ConnectInstructions: View {
    @EnvironmentObject var model: AppModel
    @State private var agent: AgentSetup.Agent = .claude

    var body: some View {
        if let s = model.service?.settings, model.reachMode == .local {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber).font(.system(size: 11))
                Text("Network access is off, so other computers can't connect. Turn it on in the previous step.")
                    .font(T.sans(13)).foregroundStyle(T.muted)
            }
        } else if let s = model.service?.settings {
            VStack(alignment: .leading, spacing: 16) {
                Choice(selection: $agent, options: AgentSetup.Agent.allCases.map { ($0, $0.title) })
                switch agent {
                case .claude:
                    CodeBlock(text: AgentSetup.command(.claude, s),
                              display: "claude mcp add --scope user --transport http desktop-plane \\\n  \(s.mcpURL) \\\n  --header \"Authorization: Bearer ••••••••\"")
                case .codex:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add this to ~/.codex/config.toml on your computer:").font(T.sans(13)).foregroundStyle(T.muted)
                        CodeBlock(text: AgentSetup.codexConfig(s),
                                  display: "[mcp_servers.desktop-plane]\nurl = \"\(s.mcpURL)\"\nhttp_headers = { Authorization = \"Bearer ••••••••\" }")
                    }
                }
                ConnectionLine()
            }
        }
    }
}

/// Waiting, then which agent connected and from where.
struct ConnectionLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let agents = model.manager?.connectedAgents ?? []
            HStack(spacing: 9) {
                if let a = agents.first {
                    LED()
                    Text("\(AgentName.pretty(a.name)) connected\(a.address.isEmpty || a.address == "127.0.0.1" ? " from this Mac" : " from \(a.address)")")
                        .font(T.sans(13, .medium))
                } else {
                    LED(on: true, color: T.faint, pulse: true)
                    Text("Waiting for a connection").font(T.sans(13)).foregroundStyle(T.muted)
                }
            }
            .padding(.top, 4)
        }
    }
}

enum AgentName {
    static func pretty(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("claude") { return "Claude Code" }
        if r.contains("codex") { return "Codex" }
        return raw.isEmpty ? "An agent" : raw
    }
}

// MARK: shared pieces

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
