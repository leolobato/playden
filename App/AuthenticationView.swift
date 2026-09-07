import SwiftUI
import CoreImage.CIFilterBuiltins

struct AuthenticationView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            LinearGradient(colors: [Design.accent.opacity(0.06), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            SectionLabel(text: "Your Steam library").offset(x: 96, y: 60)
            VStack(alignment: .leading, spacing: 34) {
                Text(model.authScreen == .qr ? "Your games.\nReady for the big screen." : model.authScreen == .credentials ? "Sign in to Steam" : "One more step").font(Design.condensed(72))
                Text(model.authScreen == .qr ? "Scan the code with Steam on your phone, then approve Big Screen to bring your library here." : model.authScreen == .credentials ? "Use your Steam account name and password. You may also need a Steam Guard code." : model.authMessage)
                    .font(Design.body(30)).foregroundStyle(Design.secondary).lineSpacing(8)
                if let error = model.authError {
                    Label(error, systemImage: "exclamationmark.circle").font(Design.body(24)).foregroundStyle(Design.amber).fixedSize(horizontal: false, vertical: true)
                }
                if model.authScreen != .credentials {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(model.authenticationActions.enumerated()), id: \.offset) { index, title in
                            ActionButton(title: title, primary: index == 0, focused: model.authIndex == index, large: index == 0, reducedMotion: model.reducedMotion) {
                                model.authIndex = index; model.activateAuthentication()
                            }
                        }
                    }.padding(.top, 18)
                }
            }.frame(width: 760, alignment: .leading).offset(x: 96, y: 240)
            if model.authScreen == .qr {
                VStack(spacing: 30) {
                    QRCodeView(url: model.authQR).frame(width: 560, height: 560)
                    HStack(spacing: 14) {
                        if model.authError == nil { ProgressView().controlSize(.small).tint(Design.accent) }
                        Text(model.authMessage).font(Design.body(24, weight: "Medium"))
                    }
                }.offset(x: 1110, y: 190)
            } else if model.authScreen == .credentials {
                VStack(spacing: 22) {
                    ForEach(Array(model.authenticationActions.enumerated()), id: \.offset) { index, title in
                        Button { model.authIndex = index; model.activateAuthentication() } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(title).font(Design.condensed(30))
                                    if index < 2 {
                                        Text(index == 0 ? (model.accountNameDraft.isEmpty ? "Enter account name" : model.accountNameDraft) : (model.passwordDraft.isEmpty ? "Enter password" : String(repeating: "•", count: min(20, model.passwordDraft.count))))
                                            .font(Design.body(26)).foregroundStyle(Design.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if index < 2 { Image(systemName: "pencil").font(.system(size: 26)).foregroundStyle(Design.secondary) }
                            }.padding(28).frame(width: 760, height: index < 2 ? 134 : 84)
                                .background(index == 2 ? Design.accent.opacity(0.2) : Design.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                .focusRing(model.authIndex == index)
                        }.buttonStyle(.plain)
                    }
                }.offset(x: 1000, y: 240)
            } else {
                VStack(spacing: 28) {
                    Image(systemName: model.authScreen == .guardCode ? "lock.shield" : "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 156, weight: .ultraLight)).foregroundStyle(Design.accent)
                    if model.authError == nil { ProgressView().controlSize(.large).tint(Design.accent) }
                    Text(model.authScreen == .guardCode ? "Steam Guard" : "Waiting for confirmation").font(Design.condensed(36))
                }.frame(width: 760, height: 520).offset(x: 1000, y: 240)
            }
            HStack(spacing: 30) {
                LegendItem(glyph: model.playStationGlyphs ? "✕" : "A", title: "Select")
                LegendItem(glyph: model.playStationGlyphs ? "○" : "B", title: "Back")
            }.offset(x: 96, y: 986)
        }.frame(width: 1920, height: 1080)
    }
}
private struct QRCodeView: View {
    let url: URL?
    @State private var qr: NSImage?
    var body: some View {
        ZStack {
            Design.text
            if let qr {
                Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().padding(36)
            } else {
                Image(systemName: "qrcode").font(.system(size: 160, weight: .ultraLight)).foregroundStyle(Design.background.opacity(0.16))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 16))
            .task(id: url) {
                qr = nil
                guard let url else { return }
                let filter = CIFilter.qrCodeGenerator()
                filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
                guard let output = filter.outputImage,
                      let bitmap = CIContext().createCGImage(output, from: output.extent) else { return }
                qr = NSImage(cgImage: bitmap, size: .zero)
            }
    }
}
