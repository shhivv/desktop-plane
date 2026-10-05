import PlaneHost
import SwiftUI

/// VM size and host settings. Same file and rules as `planed config`; either one can change
/// them and a running host picks the change up.
struct SettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = HostSettings.load()
    @State private var saved = HostSettings.load()
    @State private var error: String?

    var body: some View {
        Section(title: "Settings") {
            Text("This Mac: \(HostSettings.hostCPUs) cores, \(HostSettings.hostMemoryGB) GB memory")
                .font(.callout).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("CPUs per desktop")
                    Stepper("\(draft.cpusPerVM)", value: $draft.cpusPerVM, in: HostSettings.cpuRange)
                }
                GridRow {
                    Text("Memory per desktop")
                    Stepper("\(draft.memoryGBPerVM) GB", value: $draft.memoryGBPerVM, in: HostSettings.memoryRange)
                }
                GridRow {
                    Text("Disk size")
                    HStack {
                        Stepper("\(draft.diskGB) GB", value: $draft.diskGB, in: HostSettings.diskRange, step: 10)
                        Text("used when the image is installed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Running at once")
                    Picker("", selection: $draft.maxVMs) {
                        Text("1").tag(1)
                        Text("2 (macOS maximum)").tag(2)
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                GridRow {
                    Text("Session lifetime")
                    Stepper("\(draft.defaultTTLSeconds / 60) min", value: minutes(\.defaultTTLSeconds), in: 1...1440, step: 15)
                }
                GridRow {
                    Text("Idle timeout")
                    Stepper("\(draft.defaultIdleTimeoutSeconds / 60) min", value: minutes(\.defaultIdleTimeoutSeconds), in: 1...1440, step: 5)
                }
                GridRow {
                    Text("API")
                    HStack {
                        Picker("", selection: $draft.bindAddress) {
                            Text("This Mac only").tag("127.0.0.1")
                            Text("All networks").tag("0.0.0.0")
                        }
                        .labelsHidden().frame(width: 160)
                        Text("port")
                        TextField("", value: $draft.port, format: .number.grouping(.never)).frame(width: 70)
                    }
                }
            }

            ForEach(draft.warnings(), id: \.self) { Text("⚠︎ \($0)").font(.callout).foregroundStyle(.orange) }
            ForEach(draft.errors(), id: \.self) { Text($0).font(.callout).foregroundStyle(.red) }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            if draft.needsResnapshot(VMImage.load(named: draft.image)) {
                Text("CPU and memory apply to new desktops after you redo step 3 (Snapshot) above.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Revert") { draft = saved; error = nil }.disabled(!changed)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!changed || !draft.errors().isEmpty)
            }
        }
        .onReceive(model.objectWillChange) { _ in
            // Picks up `planed config` edits while nothing is being edited here.
            if !changed, let s = model.service?.settings, !Self.same(s, saved) { draft = s; saved = s }
        }
    }

    private var changed: Bool { !Self.same(draft, saved) }

    private func minutes(_ kp: WritableKeyPath<HostSettings, Int>) -> Binding<Int> {
        Binding(get: { draft[keyPath: kp] / 60 }, set: { draft[keyPath: kp] = $0 * 60 })
    }

    private func save() {
        error = nil
        do {
            if let service = model.service { try service.apply(draft) } else { try draft.save() }
            saved = draft
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func same(_ a: HostSettings, _ b: HostSettings) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return (try? enc.encode(a)) == (try? enc.encode(b))
    }
}
