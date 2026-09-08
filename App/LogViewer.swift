import SwiftUI
import AppKit
import Domain

struct LogViewer: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.gameName(gameID)).font(Design.condensed(40)).lineLimit(1)
                Text("· Logs").font(Design.condensed(40)).foregroundStyle(Design.secondary)
                Spacer()
                Text(model.logDocument.map { $0.kind.capitalized + " · " + $0.updatedAt.formatted(date: .abbreviated, time: .shortened) } ?? "No logs yet")
                    .font(Design.body(22)).foregroundStyle(Design.muted)
            }
            if let log = model.logDocument {
                LogTextScroll(text: log.text, identity: log.id, request: model.logScrollRequest) { fraction, canScroll in
                    model.logScrollFraction = fraction; model.logCanScroll = canScroll
                }.padding(26).background(Color(hex: 0x0A0908), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text("No installation or play-session logs yet.").font(Design.body(28))
                    Text("Logs will appear here after you install or play this game.").font(Design.body(24)).foregroundStyle(Design.secondary)
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(hex: 0x0A0908), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.logArchiveError { Text(error).font(Design.body(22)).foregroundStyle(Design.amber).lineLimit(2) }
            HStack(spacing: 28) {
                ActionButton(title: "Close", primary: true, focused: model.logActionIndex == 0, reducedMotion: model.reducedMotion) { model.panel = nil }
                if model.logDocument != nil && model.diagnosticArchive != nil {
                    ActionButton(title: "Reveal in Finder", focused: model.logActionIndex == 1, reducedMotion: model.reducedMotion) { model.revealLogFile() }
                }
                Spacer()
                if model.logCanScroll {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.controllerName == nil || model.keyboardNavigation ? "↑ ↓ Scroll · PgUp / PgDn Page" : "D-pad Scroll · L2 / R2 Page")
                            .font(Design.body(22)).foregroundStyle(Design.secondary)
                        Text(model.logScrollFraction <= 0 ? "Top" : model.logScrollFraction >= 0.999 ? "End of log" : "\(Int(model.logScrollFraction * 100))%")
                            .font(Design.body(20)).foregroundStyle(Design.muted).monospacedDigit()
                    }
                }
            }
        }.padding(40).frame(width: 1728, height: 864).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Native text layout keeps long tool lines wrapped and permits normal mouse selection/scrolling.
/// Controller commands scroll the same viewport; they never depend on a hidden keyboard focus.
struct LogTextScroll: NSViewRepresentable {
    let text: String
    let identity: UUID
    let request: LogScrollRequest
    let position: (Double, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> DiagnosticScrollView {
        let scroll = DiagnosticScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = false
        let text = NSTextView(frame: .zero)
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        text.textColor = NSColor(calibratedRed: 0.88, green: 0.87, blue: 0.84, alpha: 1)
        text.textContainerInset = .init(width: 4, height: 4)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scroll = scroll
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.didLayout = { [weak coordinator = context.coordinator] in coordinator?.scrolled() }
        return scroll
    }
    func updateNSView(_ scroll: DiagnosticScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.position = position
        guard let textView = scroll.documentView as? NSTextView else { return }
        let newDocument = coordinator.identity != identity
        if textView.string != text { textView.string = text; scroll.needsLayout = true }
        if newDocument { coordinator.identity = identity; coordinator.sequence = request.sequence; scroll.contentView.scroll(to: .zero) }
        if coordinator.sequence != request.sequence {
            coordinator.sequence = request.sequence
            scroll.layoutSubtreeIfNeeded()
            let maximum = max(0, textView.frame.height - scroll.contentView.bounds.height)
            let y = min(maximum, max(0, scroll.contentView.bounds.minY + request.points))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        coordinator.scrolled()
    }
    @MainActor final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        var identity: UUID?
        var sequence = 0
        var position: ((Double, Bool) -> Void)?
        private var lastFraction = -1.0
        private var lastCanScroll = false
        @objc func scrolled() {
            guard let scroll, let document = scroll.documentView else { return }
            let maximum = max(0, document.frame.height - scroll.contentView.bounds.height)
            let fraction = maximum > 1 ? min(1, max(0, scroll.contentView.bounds.minY / maximum)) : 0
            let canScroll = maximum > 1
            guard fraction != lastFraction || canScroll != lastCanScroll else { return }
            lastFraction = fraction; lastCanScroll = canScroll
            // Layout callbacks may arrive during SwiftUI's update; publish after that transaction.
            Task { @MainActor [weak self] in self?.position?(fraction, canScroll) }
        }
    }
}

final class DiagnosticScrollView: NSScrollView {
    var didLayout: (() -> Void)?
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView, let container = text.textContainer, let manager = text.layoutManager else { return }
        let width = contentSize.width
        text.setFrameSize(.init(width: width, height: max(text.frame.height, contentSize.height)))
        container.containerSize = .init(width: max(1, width - text.textContainerInset.width * 2), height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let height = max(contentSize.height, manager.usedRect(for: container).height + text.textContainerInset.height * 2)
        if text.frame.height != height { text.setFrameSize(.init(width: width, height: height)) }
        didLayout?()
    }
}
