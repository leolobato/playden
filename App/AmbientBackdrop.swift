import SwiftUI

/// Decode before replacing the visible layer. SwiftUI retains the outgoing keyed layer during
/// its opacity transition, including when the user changes focus again during a fade.
struct AmbientBackdrop: View {
    let url: URL?
    let reducedMotion: Bool
    @State private var displayed: Frame?
    private struct Frame: Identifiable {
        let id: URL
        let image: NSImage
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(displayed.map { [$0] } ?? []) { frame in
                    Image(nsImage: frame.image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        .transition(.opacity)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .compositingGroup().blur(radius: 90).opacity(0.22)
        }.allowsHitTesting(false)
            .task(id: url) {
                guard let url, displayed?.id != url else { return }
                if displayed != nil && !reducedMotion {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                }
                guard let loaded = await ArtworkCache.shared.image(for: url), !Task.isCancelled else { return }
                withAnimation(reducedMotion || displayed == nil ? nil : .easeInOut(duration: 0.4)) {
                    displayed = Frame(id: url, image: loaded)
                }
            }
    }
}
