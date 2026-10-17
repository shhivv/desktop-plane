import AppKit
import Combine
import PlaneHost
import ServiceManagement
import SwiftUI
import Virtualization

@main
struct DesktopPlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    init() { Fonts.register() }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuBarIcon().environmentObject(model)
        }
        Window("Desktop Plane", id: "main") {
            MainView().environmentObject(model).frame(minWidth: 1040, minHeight: 680)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The menu bar icon. It appears at launch, so it also opens the setup window for a first run.
struct MenuBarIcon: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.liveCount > 0 ? "macwindow.on.rectangle" : "macwindow")
            .onAppear {
                let forced = ProcessInfo.processInfo.environment["DP_OPEN_WINDOW"] != nil
                if model.showOnboarding || forced {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.service?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var service: PlaneService?
    @Published var startError: String?
    @Published var log: [String] = []
    @Published var imageStage: VMImage.Stage?
    @Published var lastError: String?
    let builder: ImageBuilder
    private var windows: [String: VMWindow] = [:]
    private var subs: Set<AnyCancellable> = []

    init() {
        builder = ImageBuilder(name: HostSettings.load().image)
        builder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subs)
        builder.$provisioningVM.sink { [weak self] vm in self?.showProvisioning(vm) }.store(in: &subs)
        Log.shared.onLine = { line in
            Task { @MainActor in
                let m = AppModel.shared
                m.log.append(line)
                if m.log.count > 300 { m.log.removeFirst(m.log.count - 300) }
            }
        }
        refreshImage()
        resumeOnboarding()
        // For screenshots and design work: DP_STEP=welcome|install|setup|snapshot|connect.
        if let name = ProcessInfo.processInfo.environment["DP_STEP"],
           let step = OnboardingView.Step.allCases.first(where: { "\($0)" == name }) {
            onboardingForced = true
            onboardingStep = step
        }
    }

    var manager: SessionManager? { service?.manager }
    var liveCount: Int { manager?.sessions.filter { $0.state == .ready || $0.state == .starting }.count ?? 0 }

    func start() {
        do {
            let s = try PlaneService()
            try s.start()
            s.manager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subs)
            service = s
        } catch {
            startError = error.localizedDescription
        }
    }

    func refreshImage() { imageStage = VMImage.load(named: builder.name)?.meta.stage }

    func run(_ work: @escaping () async throws -> Void) {
        lastError = nil
        Task {
            do { try await work() } catch { lastError = error.localizedDescription }
            refreshImage()
        }
    }

    // MARK: onboarding

    @Published var onboardingStep: OnboardingView.Step = .welcome
    @Published var creating = false
    private static let onboardedKey = "onboarded"

    /// Shown until the image is ready and the person has been through the connect step.
    var showOnboarding: Bool {
        imageStage != .ready || !UserDefaults.standard.bool(forKey: Self.onboardedKey) || onboardingForced
    }
    @Published private var onboardingForced = false

    /// The step that matches the image's stage, for a first launch or a relaunch halfway through.
    func resumeOnboarding() {
        switch imageStage {
        case nil: onboardingStep = builder.busy ? .install : .welcome
        case .installed?: onboardingStep = builder.busy ? .install : .setup
        case .provisioned?: onboardingStep = .snapshot
        case .ready?: onboardingStep = .connect
        }
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        onboardingForced = false
        objectWillChange.send()
    }

    func restartOnboarding() {
        onboardingForced = true
        onboardingStep = .welcome
    }

    /// Boots the image for setup; moves on to the snapshot once the guest shuts down.
    func provision() {
        lastError = nil
        Task {
            do {
                try await builder.provision()
                refreshImage()
                onboardingStep = .snapshot
            } catch {
                lastError = error.localizedDescription
                refreshImage()
            }
        }
    }

    /// The setup VM in its own, larger window. The onboarding page keeps the steps.
    func popOutProvisioning() {
        guard let vm = builder.provisioningVM else { return }
        if let w = windows["provision"] { w.show(); return }
        let w = VMWindow(vm: vm, title: "Desktop Plane setup", interactive: true)
        w.onClose = { [weak self] in self?.windows.removeValue(forKey: "provision") }
        windows["provision"] = w
        w.show()
    }

    private func showProvisioning(_ vm: VZVirtualMachine?) {
        if vm == nil { windows.removeValue(forKey: "provision")?.window.close() }
    }

    var imageSummary: String {
        guard let img = VMImage.load(named: builder.name) else { return "Not built" }
        let m = img.meta
        return "macOS \(m.macOSBuild) · \(m.cpus ?? 0) CPUs · \(m.memoryGB ?? 0) GB · \(m.diskGB) GB disk · \(m.stage.rawValue)"
    }

    /// Starts a desktop from the app, for a person to look at or hand to an agent.
    func newDesktop() {
        guard let m = manager else { return }
        creating = true
        lastError = nil
        Task {
            do { _ = try await m.create(.init()) } catch { lastError = error.localizedDescription }
            creating = false
        }
    }

    func watch(_ s: Session) {
        if let w = windows[s.id] { w.show(); return }
        guard let vm = s.vm else { return }
        let w = VMWindow(vm: vm, title: "\(s.id) — watching (input blocked)", interactive: false)
        w.onClose = { [weak self] in self?.windows.removeValue(forKey: s.id) }
        windows[s.id] = w
        w.show()
    }

    func toggleControl(_ s: Session) {
        guard let w = windows[s.id] else { return }
        w.interactive.toggle()
        w.window.title = "\(s.id) — \(w.interactive ? "you have control" : "watching (input blocked)")"
    }

    func stop(_ s: Session) {
        windows.removeValue(forKey: s.id)?.window.close()
        Task { await manager?.destroy(s.id, reason: "stopped from the app") }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { lastError = "Launch at login: \(error.localizedDescription)" }
            objectWillChange.send()
        }
    }
}
