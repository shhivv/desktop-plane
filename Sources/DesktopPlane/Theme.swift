import AppKit
import CoreText
import SwiftUI

/// The app's look: black, hairline borders, Geist type, white primary actions.
enum T {
    static let bg = Color.black
    static let surface = Color(white: 0.04)
    static let raised = Color(white: 0.08)
    static let border = Color(white: 0.13)
    static let borderStrong = Color(white: 0.2)
    static let text = Color(white: 0.93)
    static let muted = Color(white: 0.63)
    static let faint = Color(white: 0.42)
    static let green = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let amber = Color(red: 0.96, green: 0.65, blue: 0.14)
    static let red = Color(red: 0.93, green: 0.3, blue: 0.3)
    static let blue = Color(red: 0.2, green: 0.55, blue: 1)

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
}

/// Registers the bundled Geist fonts (Contents/Resources/Fonts in the app, assets/fonts in a
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
        ready = NSFont(name: "Geist-Regular", size: 12) != nil
    }
}

// MARK: buttons

struct PrimaryButton: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.sans(large ? 14 : 13, .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 40 : 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(T.text.opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.35)
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
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 40 : 32)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || configuration.isPressed ? T.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(T.borderStrong))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
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
            .background(RoundedRectangle(cornerRadius: 10).fill(T.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.border))
    }
}

/// A command with a copy button, styled like a terminal line.
struct Terminal: View {
    let text: String
    var prompt = "$"
    var display: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            if !prompt.isEmpty { Text(prompt).foregroundStyle(T.faint) }
            Text(display ?? text).foregroundStyle(T.text).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.border))
    }
}

struct Dot: View {
    let color: Color
    var pulse = false
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .background(Circle().fill(color.opacity(0.35)).frame(width: 14, height: 14).scaleEffect(pulse && on ? 1 : 0.5).opacity(pulse ? (on ? 0 : 1) : 0))
            .onAppear { if pulse { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } } }
    }
}

/// Small uppercase mono label, e.g. "STEP 02 / 05".
struct Eyebrow: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(T.mono(11)).tracking(1.2).foregroundStyle(T.faint) }
}

/// Faint grid that fades out, behind hero areas.
struct GridBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 48
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y <= size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        }
        .mask(RadialGradient(colors: [.white, .clear], center: .top, startRadius: 0, endRadius: 520))
        .allowsHitTesting(false)
    }
}

/// The mark: a window outline with a filled window offset behind it.
struct Mark: View {
    var size: CGFloat = 22
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.14).fill(T.text)
                .frame(width: size * 0.72, height: size * 0.56)
                .offset(x: size * 0.28, y: size * 0.06)
            RoundedRectangle(cornerRadius: size * 0.14).fill(T.bg)
                .frame(width: size * 0.72, height: size * 0.56)
                .offset(x: 0, y: size * 0.38)
            RoundedRectangle(cornerRadius: size * 0.14).strokeBorder(T.text, lineWidth: size * 0.08)
                .frame(width: size * 0.72, height: size * 0.56)
                .offset(x: 0, y: size * 0.38)
        }
        .frame(width: size, height: size, alignment: .topLeading)
    }
}

extension View {
    /// Black window chrome: dark scheme, black behind everything, the app's type.
    func blackChrome() -> some View {
        self.font(T.sans(13))
            .foregroundStyle(T.text)
            .tint(T.text)
            .preferredColorScheme(.dark)
            .background(T.bg.ignoresSafeArea())
    }
}
