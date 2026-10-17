import AppKit
import SwiftUI

/// The app's look. Quiet warm graphite; the Mac mini's power light is the one bright thing,
/// and it means "running" wherever it appears.
enum T {
    static let bg = Color.black
    static let surface = Color(hex: 0x111110)
    static let raised = Color(hex: 0x1C1B1A)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.12)
    static let text = Color(hex: 0xEDEAE5)
    static let muted = Color(hex: 0x9D978E)
    static let faint = Color(hex: 0x6A655E)
    /// The power light, and the warm light it throws.
    static let led = Color(hex: 0xFFF1D6)
    static let lamp = Color(hex: 0xE9B872)
    static let green = Color(hex: 0x8CC98A)
    static let amber = Color(hex: 0xE3A857)
    static let red = Color(hex: 0xE0644C)

    // Type: SF Pro throughout, SF Mono only for what a person copies (commands, URLs, ids).
    // Scale: 32 / 20 / 15 / 13 / 11.5.
    static func display(_ size: CGFloat = 32) -> Font { .system(size: size, weight: .semibold) }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: buttons

struct PrimaryButton: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(large ? 14 : 13, .medium))
            .foregroundStyle(Color(hex: 0x1A1816))
            .padding(.horizontal, large ? 16 : 11)
            .frame(height: large ? 34 : 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.text.opacity(configuration.isPressed ? 0.82 : 1)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct SecondaryButton: ButtonStyle {
    var large = false
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(large ? 14 : 13, .medium))
            .foregroundStyle(destructive && hover ? T.red : T.text)
            .padding(.horizontal, large ? 16 : 11)
            .frame(height: large ? 34 : 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.2 : (hover ? 0.16 : 0.11))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct LinkButton: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(13))
            .foregroundStyle(hover ? T.text : T.muted)
            .underline(hover, color: T.muted)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct GhostButton: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hover ? T.text : T.muted)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

// MARK: surfaces

struct Panel<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(T.border))
    }
}

/// A line to copy: a command, a URL, a header.
struct Terminal: View {
    let text: String
    var label = ""
    var display: String?
    /// Shrink to fit rather than cut the middle out.
    var fit = false
    /// False where the text can't be pasted, such as into a VM with no shared clipboard.
    var copyable = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if !label.isEmpty { Text(label).font(T.sans(12.5)).foregroundStyle(T.faint).frame(width: 50, alignment: .leading) }
            Text(display ?? text).font(T.mono(12)).foregroundStyle(T.text)
                .lineLimit(1).truncationMode(.middle).minimumScaleFactor(fit ? 0.75 : 1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if copyable { CopyButton(text: text) }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.border))
    }
}

/// Several lines to copy, such as a config file snippet.
struct CodeBlock: View {
    let text: String
    var display: String?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(display ?? text).font(T.mono(12)).foregroundStyle(T.text).lineSpacing(4)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            CopyButton(text: text)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(T.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(T.border))
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Text(copied ? "Copied" : "Copy").font(T.sans(12.5, .medium))
        }
        .buttonStyle(GhostButton())
    }
}

/// The power light: on means running. `pulse` breathes it while something starts or waits.
struct LED: View {
    var on = true
    var color: Color = T.led
    var pulse = false
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(on ? color : Color.white.opacity(0.14))
            .frame(width: 6, height: 6)
            .shadow(color: on && color == T.led ? T.lamp.opacity(0.6) : .clear, radius: 3)
            .opacity(pulse && breathe ? 0.3 : 1)
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

/// The spare Mac: a Mac mini from a little above, its power light on or off. When the light
/// is on, it throws a little warm light on the desk.
struct MacMini: View {
    var width: CGFloat = 220
    var on = true

    var body: some View {
        let top = width * 0.2, front = width * 0.095
        VStack(spacing: 0) {
            TopFace()
                .fill(LinearGradient(colors: [Color(hex: 0x3B3834), Color(hex: 0x5E5A54)], startPoint: .top, endPoint: .bottom))
                .overlay(TopFace().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .frame(width: width, height: top)
            ZStack(alignment: .trailing) {
                UnevenRoundedRectangle(bottomLeadingRadius: front * 0.55, bottomTrailingRadius: front * 0.55, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x262421), Color(hex: 0x191816)], startPoint: .top, endPoint: .bottom))
                Circle()
                    .fill(on ? T.led : Color.white.opacity(0.12))
                    .frame(width: max(3, width * 0.018), height: max(3, width * 0.018))
                    .shadow(color: on ? T.lamp.opacity(0.9) : .clear, radius: width * 0.02)
                    .padding(.trailing, width * 0.075)
            }
            .frame(width: width, height: front)
        }
        .background(alignment: .bottom) {
            ZStack {
                Ellipse().fill(.black.opacity(0.5)).frame(width: width * 1.05, height: front * 0.9).blur(radius: width * 0.03)
                Ellipse().fill(T.lamp.opacity(on ? 0.14 : 0)).frame(width: width * 0.5, height: front * 1.4)
                    .blur(radius: width * 0.06).offset(x: width * 0.32)
            }
            .offset(y: front * 0.55)
        }
        .animation(.easeInOut(duration: 0.6), value: on)
    }

    private struct TopFace: Shape {
        func path(in r: CGRect) -> Path {
            let taper = r.width * 0.06, radius = r.height * 0.4
            var p = Path()
            p.move(to: CGPoint(x: r.minX + taper + radius, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - taper - radius, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - taper + radius * 0.25, y: r.minY + radius * 0.55), control: CGPoint(x: r.maxX - taper, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + taper - radius * 0.25, y: r.minY + radius * 0.55))
            p.addQuadCurve(to: CGPoint(x: r.minX + taper + radius, y: r.minY), control: CGPoint(x: r.minX + taper, y: r.minY))
            p.closeSubpath()
            return p
        }
    }
}

/// The mark, small: this Mac, with its power light.
struct Mark: View {
    var size: CGFloat = 16
    var body: some View {
        Image(systemName: "macmini.fill")
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(T.text)
    }
}

extension View {
    func appChrome() -> some View {
        self.font(T.sans(13))
            .foregroundStyle(T.text)
            .tint(T.lamp)
            .preferredColorScheme(.dark)
            .background(T.bg.ignoresSafeArea())
    }
}

/// Pick one of a few options: separate buttons with room between them, the chosen one filled.
struct Choice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(T.sans(13, on ? .medium : .regular))
                        .foregroundStyle(on ? T.text : T.muted)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Color.white.opacity(0.11) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? T.borderStrong : T.border))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// How it fits together: agents on your computer, desktops on this Mac. A dot keeps travelling
/// from one to the other; it holds still when Reduce Motion is on.
struct HowItWorks: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            node(symbol: "laptopcomputer", title: "Your computer", detail: "Agents run here")
            ZStack(alignment: .leading) {
                Line().stroke(T.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .frame(height: 1)
                GeometryReader { g in
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { tl in
                        let (x, alpha) = position(tl.date)
                        Circle().fill(T.led).frame(width: 5, height: 5)
                            .shadow(color: T.lamp.opacity(0.8), radius: 3)
                            .offset(x: (g.size.width - 5) * x, y: -2)
                            .opacity(alpha)
                    }
                }
                .frame(height: 1)
            }
            .frame(maxWidth: 220)
            .padding(.top, 44)
            .padding(.horizontal, 12)
            node(symbol: "macmini", title: "This Mac", detail: "Desktops run here")
        }
        .frame(maxWidth: .infinity)
    }

    /// Where the dot is (0…1 along the line) and how visible: 1.8 s across, eased, fading in
    /// and out at the ends, then a short pause.
    private func position(_ date: Date) -> (CGFloat, Double) {
        if reduceMotion { return (0.5, 1) }
        let cycle = 2.4, travel = 1.8
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
        guard t < travel else { return (1, 0) }
        let p = t / travel
        let eased = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
        let alpha = min(1, min(p, 1 - p) * 6)
        return (CGFloat(eased), alpha)
    }

    private func node(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 42, weight: .ultraLight)).foregroundStyle(T.text)
                .frame(height: 56, alignment: .bottom)
            VStack(spacing: 2) {
                Text(title).font(T.sans(13, .medium))
                Text(detail).font(T.sans(12.5)).foregroundStyle(T.muted)
            }
        }
        .frame(width: 130)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            return p
        }
    }
}
