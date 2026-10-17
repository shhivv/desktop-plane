import AppKit
import CoreText
import SwiftUI

/// The app's look, from the launch film: a spare Mac in a dark basement under one warm lamp.
/// Warm near-black, lamplight from above, and the Mac's power light as the one bright accent.
enum T {
    static let bg = Color(hex: 0x0F0D0B)
    static let surface = Color(hex: 0x16130F)
    static let raised = Color(hex: 0x1F1B16)
    static let border = Color(hex: 0x2A241E)
    static let borderStrong = Color(hex: 0x3B332B)
    static let text = Color(hex: 0xF2EBE1)
    static let muted = Color(hex: 0xA89C8C)
    static let faint = Color(hex: 0x6E6457)
    /// The bulb.
    static let lamp = Color(hex: 0xF2C27B)
    /// The power light: warm white with an amber halo.
    static let led = Color(hex: 0xFFF4E0)
    static let green = Color(hex: 0x9BD58A)
    static let amber = Color(hex: 0xF2B35B)
    static let red = Color(hex: 0xE5684F)

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .medium: "Geist-Medium"
        case .semibold: "Geist-SemiBold"
        case .bold, .heavy, .black: "Geist-Bold"
        default: "Geist-Regular"
        }
        return Fonts.ready ? .custom(name, fixedSize: size) : .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Fonts.ready ? .custom(weight == .regular ? "GeistMono-Regular" : "GeistMono-Medium", fixedSize: size)
            : .system(size: size, weight: weight, design: .monospaced)
    }

    /// Display headings.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        Fonts.ready ? .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", fixedSize: size)
            : .system(size: size, design: .serif)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Registers the bundled fonts (Contents/Resources/Fonts in the app, assets/fonts in a
/// checkout) for this process.
enum Fonts {
    nonisolated(unsafe) static var ready = false

    static func register() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../assets/fonts").standardized,
        ].compactMap { $0 }
        guard let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Geist-Regular.ttf").path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
        ready = NSFont(name: "Geist-Regular", size: 12) != nil && NSFont(name: "InstrumentSerif-Regular", size: 12) != nil
    }
}

// MARK: buttons

struct PrimaryButton: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(large ? 14 : 13, .medium))
            .foregroundStyle(T.bg)
            .padding(.horizontal, large ? 20 : 13)
            .frame(height: large ? 40 : 32)
            .background(Capsule().fill(T.text.opacity(configuration.isPressed ? 0.8 : 1)))
            .shadow(color: T.lamp.opacity(enabled && hover ? 0.45 : 0), radius: 14)
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.2), value: hover)
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
            .padding(.horizontal, large ? 20 : 13)
            .frame(height: large ? 40 : 32)
            .background(Capsule().fill(hover || configuration.isPressed ? T.raised : .clear))
            .overlay(Capsule().strokeBorder(T.borderStrong))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }
}

struct GhostButton: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(13, .medium))
            .foregroundStyle(hover ? T.text : T.muted)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

// MARK: surfaces

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(T.border))
    }
}

/// A command with a copy button, styled like a terminal line.
struct Terminal: View {
    let text: String
    var prompt = "$"
    var display: String?
    /// Shrink to fit rather than cut the middle out.
    var fit = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if !prompt.isEmpty { Text(prompt).foregroundStyle(T.lamp.opacity(0.8)) }
            Text(display ?? text).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .minimumScaleFactor(fit ? 0.7 : 1)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square").font(.system(size: 12))
            }
            .buttonStyle(GhostButton())
            .help("Copy")
        }
        .font(T.mono(12.5))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0B0908)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border))
    }
}

/// The power light. Glows when on; `pulse` breathes it, like a Mac mini asleep or starting.
struct LED: View {
    var on = true
    var color: Color = T.led
    var pulse = false
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(on ? color : T.borderStrong)
            .frame(width: 6, height: 6)
            .shadow(color: on ? T.lamp.opacity(breathe ? 0.3 : 0.9) : .clear, radius: 5)
            .shadow(color: on ? color.opacity(breathe ? 0.15 : 0.5) : .clear, radius: 2)
            .opacity(pulse && breathe ? 0.45 : 1)
            .onAppear {
                guard pulse else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
            }
    }
}

/// Small uppercase mono label, e.g. "STEP 02 / 05".
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(T.mono(11)).tracking(1.4).foregroundStyle(T.faint) }
}

/// One warm bulb above the window, and dust drifting through its light.
struct Lamplight: View {
    var height: CGFloat = 620

    var body: some View {
        ZStack(alignment: .top) {
            RadialGradient(colors: [T.lamp.opacity(0.16), T.lamp.opacity(0.05), .clear],
                           center: .top, startRadius: 0, endRadius: height)
            Dust().mask(RadialGradient(colors: [.white, .clear], center: .top, startRadius: 0, endRadius: height * 0.8))
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }
}

/// A few motes that drift down slowly, as in the film.
private struct Dust: View {
    private static let motes: [(x: Double, y: Double, r: Double, speed: Double)] = (0..<36).map { i in
        var g = SplitMix(seed: UInt64(i) &* 2654435761)
        return (g.next(), g.next(), 0.6 + g.next() * 1.3, 0.004 + g.next() * 0.01)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for m in Self.motes {
                    let y = (m.y + t * m.speed).truncatingRemainder(dividingBy: 1)
                    let x = m.x + sin(t * 0.3 + m.y * 9) * 0.01
                    let p = CGPoint(x: x * size.width, y: y * size.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: m.r, height: m.r)),
                             with: .color(T.lamp.opacity(0.35 * (1 - y))))
                }
            }
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }
}

/// The spare Mac: a Mac mini seen from the front, its power light on or off.
struct MacMini: View {
    var width: CGFloat = 220
    var on = true

    var body: some View {
        let top = width * 0.2, front = width * 0.1
        VStack(spacing: 0) {
            // Top face in lamplight, seen from a little above: narrower at the back.
            TopFace()
                .fill(LinearGradient(colors: [Color(hex: 0x4A433B), Color(hex: 0x7A7166)], startPoint: .top, endPoint: .bottom))
                .overlay(TopFace().stroke(Color(hex: 0x8D8478).opacity(0.5), lineWidth: 0.5))
                .frame(width: width, height: top)
            // Front edge, in shadow, with the power light at the right.
            ZStack(alignment: .trailing) {
                UnevenRoundedRectangle(bottomLeadingRadius: front * 0.5, bottomTrailingRadius: front * 0.5)
                    .fill(LinearGradient(colors: [Color(hex: 0x2B2621), Color(hex: 0x171411)], startPoint: .top, endPoint: .bottom))
                LED(on: on).padding(.trailing, width * 0.07)
            }
            .frame(width: width, height: front)
        }
        .background(Ellipse().fill(.black.opacity(0.55)).frame(width: width * 1.1, height: front).blur(radius: 10).offset(y: (top + front) / 2))
    }

    private struct TopFace: Shape {
        func path(in r: CGRect) -> Path {
            let inset = r.width * 0.07, radius = r.height * 0.35
            var p = Path()
            p.move(to: CGPoint(x: r.minX + inset + radius, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - inset - radius, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX - inset + radius * 0.3, y: r.minY + radius * 0.6), control: CGPoint(x: r.maxX - inset, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + inset - radius * 0.3, y: r.minY + radius * 0.6))
            p.addQuadCurve(to: CGPoint(x: r.minX + inset + radius, y: r.minY), control: CGPoint(x: r.minX + inset, y: r.minY))
            p.closeSubpath()
            return p
        }
    }
}

/// One of the round agents from the film: a small white ball with two eyes.
struct AgentOrb: View {
    var size: CGFloat = 26
    var looking: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFFBF4), Color(hex: 0xCFC6B8)],
                                     center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.7))
            HStack(spacing: size * 0.16) {
                Capsule().fill(Color(hex: 0x1A1612)).frame(width: size * 0.1, height: size * 0.18)
                Capsule().fill(Color(hex: 0x1A1612)).frame(width: size * 0.1, height: size * 0.18)
            }
            .offset(x: size * 0.12 * looking, y: -size * 0.02)
        }
        .frame(width: size, height: size)
        .background(Ellipse().fill(.black.opacity(0.45)).frame(width: size * 0.9, height: size * 0.2).blur(radius: 2).offset(y: size * 0.55))
    }
}

/// The mark: the little Mac mini, power light on.
struct Mark: View {
    var size: CGFloat = 22
    var body: some View {
        MacMini(width: size * 1.3).frame(width: size * 1.3, height: size)
    }
}

extension View {
    /// Basement chrome: dark scheme, warm black behind everything, the app's type.
    func basementChrome() -> some View {
        self.font(T.sans(13))
            .foregroundStyle(T.text)
            .tint(T.lamp)
            .preferredColorScheme(.dark)
            .background(T.bg.ignoresSafeArea())
    }
}
