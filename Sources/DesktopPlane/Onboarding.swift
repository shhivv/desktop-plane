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
            case .setup: "Set up"
            case .snapshot: "Snapshot"
            case .connect: "Connect"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            GridBackdrop().frame(height: 560)
            VStack(spacing: 0) {
                TopProgress(current: model.onboardingStep)
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
                .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.onboardingStep)
    }
}

/// Mark on the left, step segments across the top.
private struct TopProgress: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                Mark(size: 18)
                Text("Desktop Plane").font(T.sans(14, .semibold))
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingView.Step.allCases, id: \.self) { s in
                    VStack(alignment: .leading, spacing: 7) {
                        Capsule().fill(s.rawValue <= current.rawValue ? T.text : T.borderStrong).frame(height: 2)
                        Text(s.title).font(T.sans(11, s == current ? .medium : .regular))
                            .foregroundStyle(s == current ? T.text : T.faint)
                    }
                    .frame(width: 92)
                }
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, 32)
        .padding(.top, 14)
        .frame(height: 64)
    }
}

/// A step's column: eyebrow, title, subtitle, content, then actions.
private struct StepPage<Content: View, Actions: View>: View {
    let step: OnboardingView.Step
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: String(format: "Step %02d / %02d", step.rawValue + 1, OnboardingView.Step.allCases.count))
            Text(title).font(T.sans(40, .semibold)).tracking(-1.2).padding(.top, 14)
            Text(subtitle).font(T.sans(16)).foregroundStyle(T.muted).lineSpacing(4).padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)
            content.padding(.top, 36)
            Spacer(minLength: 24)
            HStack(spacing: 10) {
                ErrorLine()
                Spacer()
                actions
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.top, 56)
        .padding(.bottom, 40)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ErrorLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let e = model.lastError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(T.amber)
                Text(e).foregroundStyle(T.muted).lineLimit(3).textSelection(.enabled)
            }
            .font(T.sans(12.5))
        }
    }
}

// MARK: 1. welcome

private struct WelcomeStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let checks = HostCheck.all()
        StepPage(step: .welcome, title: "Desktops for your agents",
                 subtitle: "Throwaway macOS desktops that Claude Code, Codex or any MCP client can drive. Each is a fresh VM, sealed off from this Mac and your network, and deleted when the agent is done.") {
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(checks.enumerated()), id: \.element.id) { i, c in
                        CheckRow(check: c)
                        if i < checks.count - 1 { Rectangle().fill(T.border).frame(height: 1) }
                    }
                }
            }
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
        HStack(spacing: 14) {
            Image(systemName: check.ok ? "checkmark" : (check.blocking ? "xmark" : "exclamationmark"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(color.opacity(0.12)))
            Text(check.title).font(T.sans(14, .medium))
            Spacer()
            Text(check.detail).font(T.sans(13)).foregroundStyle(T.muted)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
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
                      detail: os.majorVersion >= 15 ? "Everything supported" : "Data volumes need macOS 15",
                      ok: os.majorVersion >= 15, blocking: false),
            HostCheck(id: "mem", title: "\(HostSettings.hostMemoryGB) GB memory",
                      detail: HostSettings.hostMemoryGB >= 16 ? "Two desktops at once" : "One desktop at a time",
                      ok: HostSettings.hostMemoryGB >= 16, blocking: false),
            HostCheck(id: "disk", title: "\(freeGB) GB free",
                      detail: freeGB >= 60 ? "Needs about 60 GB" : "Free up about 60 GB",
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
        StepPage(step: .install, title: "Install macOS",
                 subtitle: "Downloads the latest macOS this Mac supports, about 17 GB, and installs it into a new virtual disk. You can leave this running.") {
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
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(T.green)
                .frame(width: 22, height: 22).background(Circle().fill(T.green.opacity(0.12)))
            Text(text).font(T.sans(14, .medium))
        }
    }
}

struct ProgressRow: View {
    let status: String
    let progress: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status).font(T.sans(13)).foregroundStyle(T.muted)
                Spacer()
                if let progress { Text("\(Int(progress * 100))%").font(T.mono(12)).foregroundStyle(T.text) }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(T.border)
                    if let progress {
                        Capsule().fill(T.text).frame(width: max(4, g.size.width * progress))
                    } else {
                        Shimmer()
                    }
                }
            }
            .frame(height: 3)
        }
    }
}

/// Indeterminate bar: a short segment that slides across.
private struct Shimmer: View {
    @State private var x: CGFloat = -0.3
    var body: some View {
        GeometryReader { g in
            Capsule().fill(T.text).frame(width: g.size.width * 0.25).offset(x: g.size.width * x)
        }
        .clipShape(Capsule())
        .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { x = 1.05 } }
    }
}

// MARK: 3. setup (provision)

private struct SetupStep: View {
    @EnvironmentObject var model: AppModel

    static let command = #"bash "/Volumes/My Shared Files/install.sh""#

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            SetupInstructions().frame(width: 430)
            SetupScreen().frame(maxWidth: .infinity).padding(.top, 40)
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
        .padding(.bottom, 36)
    }
}

private struct SetupInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "Step 03 / 05")
            Text("Set up the desktop").font(T.sans(34, .semibold)).tracking(-1).padding(.top, 14)
            Text("A few clicks inside the VM that macOS only lets a person make. Once, and every desktop starts from the result.")
                .font(T.sans(14)).foregroundStyle(T.muted).lineSpacing(3).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 22) {
                Instruction(n: 1, title: "Finish Setup Assistant",
                            detail: "Create a local account. Skip Apple Account, Location Services and Siri.")
                Instruction(n: 2, title: "Run the installer",
                            detail: "Open Terminal in the VM (⌘ Space, Terminal) and type:") {
                    Terminal(text: SetupStep.command).padding(.top, 4)
                }
                Instruction(n: 3, title: "Allow two permissions",
                            detail: "Turn on Desktop Plane Agent under Accessibility and Screen Recording when System Settings opens.")
                Instruction(n: 4, title: "Shut down",
                            detail: "When the installer says Done, choose Shut Down from the Apple menu. The rest is automatic.")
            }
            .padding(.top, 32)
            Spacer(minLength: 16)
            ErrorLine()
        }
    }
}

private struct SetupScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.builder
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.02))
                if let vm = b.provisioningVM {
                    VMDisplay(vm: vm, interactive: true).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 12) {
                        Mark(size: 30).opacity(0.4)
                        Text("The VM appears here").font(T.sans(13)).foregroundStyle(T.faint)
                    }
                }
            }
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border))
            HStack(spacing: 10) {
                if b.provisioningVM != nil {
                    Dot(color: T.green, pulse: true)
                    Text("Running · click inside to type").font(T.sans(12.5)).foregroundStyle(T.muted)
                    Spacer()
                    Button("Open in window") { model.popOutProvisioning() }.buttonStyle(SecondaryButton())
                } else {
                    if b.busy { Text(b.status).font(T.sans(12.5)).foregroundStyle(T.muted) }
                    Spacer()
                    Button("Start the VM") { model.provision() }
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
        HStack(alignment: .top, spacing: 14) {
            Text(String(format: "%02d", n)).font(T.mono(12)).foregroundStyle(T.faint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
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
        StepPage(step: .snapshot, title: "Save the snapshot",
                 subtitle: "Boots the image locked down, checks the agent and its permissions, and saves the running machine. Desktops start from it in seconds.") {
            if b.busy {
                ProgressRow(status: b.status, progress: b.progress)
            } else if ready {
                Done(text: b.status.isEmpty ? "Snapshot saved" : b.status)
            }
        } actions: {
            if ready {
                Button("Continue") { model.onboardingStep = .connect }
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

// MARK: 5. connect

private struct ConnectStep: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        StepPage(step: .connect, title: "Connect your agent",
                 subtitle: "Add Desktop Plane once. Your agent can then start desktops, open apps, see the screen, click and type, and end the desktop when it's done.") {
            VStack(alignment: .leading, spacing: 28) {
                AgentsList()
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Then try")
                    Terminal(text: "Start a desktop with Safari, open apple.com and tell me the headline.", prompt: "›")
                }
            }
        } actions: {
            Button("Open dashboard") { model.finishOnboarding() }
                .buttonStyle(PrimaryButton(large: true)).keyboardShortcut(.defaultAction)
        }
    }
}

/// One row per supported agent, with a button that adds the plane to it. Used in onboarding
/// and on the dashboard.
struct AgentsList: View {
    @EnvironmentObject var model: AppModel
    @State private var installed: [AgentSetup.Agent: Bool] = [:]
    @State private var state: [AgentSetup.Agent: String] = [:]

    var body: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                ForEach(AgentSetup.Agent.allCases, id: \.self) { agent in
                    row(agent)
                    if agent != AgentSetup.Agent.allCases.last { Rectangle().fill(T.border).frame(height: 1) }
                }
            }
        }
        .task {
            for a in AgentSetup.Agent.allCases {
                installed[a] = await AgentSetup.isInstalled(a)
                if installed[a] == true, let s = model.service?.settings, await AgentSetup.isConfigured(a, s) { state[a] = "added" }
            }
        }
    }

    private func row(_ agent: AgentSetup.Agent) -> some View {
        HStack(spacing: 14) {
            Text(agent == .claude ? "✳" : "›_")
                .font(T.mono(14, .medium))
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(T.raised))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.border))
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title).font(T.sans(14, .medium))
                Text(subtitle(agent)).font(T.sans(12.5)).foregroundStyle(T.muted).lineLimit(2)
            }
            Spacer()
            Group {
                if state[agent] == "adding" {
                    ProgressView().controlSize(.small)
                } else if state[agent] == "added" {
                    HStack(spacing: 7) { Dot(color: T.green); Text("Connected").font(T.sans(13, .medium)) }
                } else {
                    Button("Add") { add(agent) }
                        .buttonStyle(PrimaryButton())
                        .disabled(installed[agent] != true || model.service == nil)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
    }

    private func subtitle(_ a: AgentSetup.Agent) -> String {
        if let s = state[a], s.hasPrefix("error:") { return String(s.dropFirst(6)) }
        switch installed[a] {
        case nil: return "Looking for \(a.rawValue)…"
        case false?: return "\(a.rawValue) isn't installed on this Mac"
        case true?: return state[a] == "added" ? "New \(a.rawValue) sessions have the desktop tools" : "Adds the desktop-plane MCP server"
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
