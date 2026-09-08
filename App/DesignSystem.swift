import SwiftUI
import CoreText
import CryptoKit
import Domain

enum Design {
    static let background = Color(hex: 0x0E0D0C)
    static let panel = Color(hex: 0x16140F)
    static let text = Color(hex: 0xF3EFE9)
    static let secondary = Color(hex: 0xA8A29E)
    static let muted = Color(hex: 0x6B655F)
    static let accent = Color(hex: 0xF0863A)
    static let green = Color(hex: 0x7BBF6A)
    static let amber = Color(hex: 0xE2B53C)
    static let red = Color(hex: 0xE05A4F)
    static func condensed(_ size: CGFloat, bold: Bool = true) -> Font { .custom(bold ? "BarlowCondensed-SemiBold" : "BarlowCondensed-Medium", size: size) }
    static func body(_ size: CGFloat, weight: String = "Regular") -> Font { .custom("Barlow-\(weight)", size: size) }
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1) }
}

private struct FocusRingScope: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var showsFocusRing: Bool {
        get { self[FocusRingScope.self] }
        set { self[FocusRingScope.self] = newValue }
    }
}
struct FocusTreatment: ViewModifier {
    @Environment(\.showsFocusRing) private var enabled
    let active: Bool
    var compact = false
    func body(content: Content) -> some View {
        content.overlay {
            if active && enabled {
                ZStack {
                    RoundedRectangle(cornerRadius: compact ? 12 : 13)
                        .stroke(Design.accent.opacity(0.55), lineWidth: 12).blur(radius: 22)
                    RoundedRectangle(cornerRadius: compact ? 12 : 13)
                        .stroke(Design.accent, lineWidth: compact ? 3 : 4)
                }.padding(compact ? -5 : -7).allowsHitTesting(false)
            }
        }
    }
}
extension View { func focusRing(_ active: Bool, compact: Bool = false) -> some View { modifier(FocusTreatment(active: active, compact: compact)) } }


struct Artwork: View {
    let url: URL?
    var fallbackURL: URL?
    var title = ""
    var placeholderID: GameID?
    var fit = false
    var transparent = false
    var fadeIn = false
    @State private var image: NSImage?
    private struct Request: Hashable { let url: URL?; let fallback: URL? }
    private var request: Request { .init(url: url, fallback: fallbackURL) }
    @State private var loadedRequest: Request?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !transparent {
                    if let placeholderID {
                        let byte = Array(SHA256.hash(data: Data("\(placeholderID.source):\(placeholderID.value)".utf8)))[0]
                        Color(hue: Double(byte) / 255, saturation: 0.22, brightness: 0.21)
                    } else { Color(hex: 0x2A2623) }
                }
                if let displayed = loadedRequest == request ? image : ArtworkCache.shared.cachedImage(for: url, fallbackURL: fallbackURL) {
                    if fallbackURL != nil && displayed.size.width > displayed.size.height {
                        // Preserve the full landscape image. The tile owns the title overlay
                        // shown on highlight, just as it does for portrait covers.
                        Image(nsImage: displayed).resizable().scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .transition(.opacity)
                    } else {
                        Image(nsImage: displayed).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: fit ? .leading : .center)
                            .transition(.opacity)
                    }
                } else if !title.isEmpty {
                    Text(title).font(Design.condensed(36)).multilineTextAlignment(.center).padding(20)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: request) {
            image = ArtworkCache.shared.cachedImage(for: url, fallbackURL: fallbackURL); loadedRequest = request
            guard image == nil else { return }
            let result = await ArtworkCache.shared.image(for: url, fallbackURL: fallbackURL)
            guard !Task.isCancelled else { return }
            withAnimation(fadeIn ? .easeInOut(duration: 0.25) : nil) { image = result }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(Design.condensed(22)).tracking(2.64).foregroundStyle(Design.secondary).frame(height: 22) }
}
struct Glyph: View {
    let text: String
    var body: some View {
        ButtonSymbol(text: text, size: 20)
            .frame(minWidth: text.count > 1 ? 20 : 36, minHeight: 36)
            .padding(.horizontal, text.count > 1 ? 10 : 0)
            .overlay(Capsule().stroke(Design.text, lineWidth: 2))
    }
}

/// Face buttons use optically balanced vector artwork. Font characters have unrelated em-boxes:
/// the previous hollow Circle and Square rendered much smaller than Cross and Triangle.
struct ButtonSymbol: View {
    let text: String
    var size: CGFloat = 20
    var body: some View {
        if let button = PlayStationFaceButton(rawValue: text) {
            PlayStationButtonShape(button: button)
                .stroke(style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
                .accessibilityLabel(button.name)
        } else {
            Text(text).font(Design.body(text.count > 1 ? min(15, size) : size, weight: "SemiBold"))
        }
    }
}
enum PlayStationFaceButton: String {
    case cross = "✕", circle = "○", square = "□", triangle = "△"
    var name: String { switch self { case .cross: "Cross"; case .circle: "Circle"; case .square: "Square"; case .triangle: "Triangle" } }
}
private struct PlayStationButtonShape: Shape {
    let button: PlayStationFaceButton
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        var path = Path()
        switch button {
        case .cross:
            path.move(to: point(0.12, 0.12)); path.addLine(to: point(0.88, 0.88))
            path.move(to: point(0.88, 0.12)); path.addLine(to: point(0.12, 0.88))
        case .circle: path.addEllipse(in: rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.05))
        case .square: path.addRect(rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12))
        case .triangle:
            path.move(to: point(0.5, 0.06)); path.addLine(to: point(0.975, 0.89)); path.addLine(to: point(0.025, 0.89)); path.closeSubpath()
        }
        return path
    }
}
struct LegendItem: View {
    let glyph: String
    let title: String
    var body: some View { HStack(spacing: 10) { Glyph(text: glyph); Text(title).font(Design.body(22, weight: "Medium")) } }
}
struct ActionButton: View {
    let title: String
    var primary = false
    var detail: String? = nil
    var focused = false
    var large = false
    var reducedMotion = false
    var systemImage: String? = nil
    var iconOnly = false
    var highlighted = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 24, weight: .medium)) }
                if !iconOnly { Text(title).font(Design.condensed(large ? 38 : 26, bold: primary)) }
                if let detail { Text(detail).font(Design.body(22, weight: "Medium")).opacity(0.8) }
            }
                .foregroundStyle(primary ? Color(hex: 0x1A1210) : highlighted ? Design.accent : Design.text)
                .padding(.horizontal, iconOnly ? 0 : large ? 44 : 22).frame(width: iconOnly ? 60 : nil, height: large ? 84 : 60)
                .background(primary ? Design.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? .clear : Design.text.opacity(0.2), lineWidth: 2))
                .focusRing(focused)
                .scaleEffect(focused && !reducedMotion ? 1.04 : 1)
        }.buttonStyle(.plain).accessibilityLabel(title)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

struct GameTile: View {
    let game: Game
    let focused: Bool
    var home = false
    var reducedMotion = false
    var subtitle: String? = nil
    var paused = false
    var job: JobRecord? = nil
    var running = false
    var verification: InstallFileVerification? = nil
    var transferProgress: Double { verification?.fraction ?? job?.displayProgress ?? 0.43 }
    var transferTitle: String { verification == nil ? (job?.statusTitle ?? (paused ? "Paused" : "Downloading")) : "Verifying file" }
    var width: CGFloat { home ? 213 : 210 }
    var height: CGFloat { home ? 320 : 315 }
    var showsDownloadMark: Bool { !running && game.status == .notInstalled && game.compatibility != .broken }
    var badge: (String, Color)? {
        if running { return ("Running", Design.green) }
        if game.status == .queued { return (job?.statusTitle ?? "Queued", job?.state == .failed ? Design.amber : Design.secondary) }
        if game.status == .driveDisconnected { return ("Drive disconnected", Design.amber) }
        if game.compatibility == .broken { return ("Broken", Design.red) }
        // The adopted tile design reserves compatibility badges for Broken.
        // Other ratings remain visible on game details and in the library filters.
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .bottomLeading) {
                Artwork(url: game.coverURL, fallbackURL: game.coverFallbackURL, title: game.title, placeholderID: game.id)
                if focused && !home {
                    LinearGradient(colors: [.clear, Design.background.opacity(0.92)], startPoint: .top, endPoint: .bottom).frame(height: 105)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.title).font(Design.condensed(24)).lineLimit(2)
                        Text(game.subtitle).font(Design.body(15)).foregroundStyle(Design.secondary)
                    }.padding(.trailing, showsDownloadMark ? 36 : 0).padding(14)
                }
                if game.status == .downloading {
                    VStack(spacing: 8) {
                        HStack { Text(transferTitle); Spacer(); if job == nil || job?.stage == .download { Text(transferProgress.formatted(.percent.precision(.fractionLength(0)))) } }.font(Design.body(16, weight: "SemiBold"))
                        ProgressTrack(value: transferProgress, height: 6)
                    }.padding(12).background(LinearGradient(colors: [.clear, Design.background.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                }
            }
            .frame(width: width, height: height).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if let badge {
                    HStack(spacing: 6) { Circle().fill(badge.1).frame(width: 8, height: 8); Text(badge.0).font(Design.body(16, weight: "SemiBold")) }
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Design.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 6)).padding(10)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsDownloadMark {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Design.text)
                        .frame(width: 30, height: 30)
                        .background(Design.background.opacity(0.8), in: Circle())
                        .overlay(Circle().strokeBorder(Design.text.opacity(0.5), lineWidth: 1.5))
                        .padding(10).accessibilityHidden(true)
                }
            }
            .focusRing(focused).scaleEffect(focused && !reducedMotion ? 1.08 : 1)
            if home && focused {
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title).font(Design.condensed(24))
                    Text(subtitle ?? game.subtitle).font(Design.body(16)).foregroundStyle(Design.secondary)
                }.lineLimit(1)
            }
        }.frame(width: width, height: home ? 400 : height, alignment: .topLeading)
            .animation(reducedMotion ? nil : .easeOut(duration: 0.18), value: focused)
    }
}

extension SessionOutcome {
    var displayTitle: String {
        switch self {
        case .clean: "Clean exit"
        case .crash: "Crashed"
        case .forced: "Force quit"
        case .launchFailed: "Did not start"
        case .interrupted: "Interrupted"
        }
    }
    var symbol: String {
        switch self {
        case .clean: "checkmark.circle"
        case .crash, .launchFailed: "exclamationmark.circle"
        case .forced: "stop.circle"
        case .interrupted: "questionmark.circle"
        }
    }
}
struct ProgressTrack: View {
    var value: Double
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            Capsule().fill(Design.text.opacity(0.2)).overlay(alignment: .leading) { Capsule().fill(Design.accent).frame(width: g.size.width * min(1, max(0, value))) }
        }.frame(height: height)
    }
}
extension Game {
    var knownSize: String? {
        let value = size.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["", "—", "–", "-"].contains(value) ? nil : value
    }
    var subtitle: String {
        switch status {
        case .queued: knownSize.map { "Queued · \($0)" } ?? "Queued"
        case .downloading: "43% · 38 MB/s"
        case .driveDisconnected: "Reconnect your games drive"
        case .notInstalled: knownSize.map { "Not installed · \($0)" } ?? "Not installed"
        case .installed: "\(hoursPlayed) h played"
        }
    }
}
