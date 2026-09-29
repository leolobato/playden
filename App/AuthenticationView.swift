import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct AuthenticationView: View {
    @Bindable var model: LibraryModel
    var body: some View {
        ZStack(alignment: .topLeading) {
            Design.background
            LinearGradient(colors: [Design.accent.opacity(0.06), .clear], startPoint: .topTrailing, endPoint: .bottomLeading)
            SectionLabel(text: model.onboarding ? "Set up · Step 3 of 5" : "Your \(storeName) library").offset(x: 96, y: 60)
            VStack(alignment: .leading, spacing: 34) {
                Text(title).font(Design.condensed(72))
                Text(message).font(Design.body(30)).foregroundStyle(Design.secondary).lineSpacing(8)
                if model.authScreen == .deviceCode, let prompt = model.authDeviceCode {
                    VStack(alignment: .leading, spacing: 12) {
                        // At a desk, the page opens in the browser with the code filled in.
                        Button { NSWorkspace.shared.open(prompt.completeURL) } label: {
                            Label(prompt.verificationURL.host.map { $0.replacingOccurrences(of: "www.", with: "") + prompt.verificationURL.path } ?? prompt.verificationURL.absoluteString,
                                  systemImage: "arrow.up.right.square")
                                .font(Design.body(28, weight: "Medium")).foregroundStyle(Design.accent)
                        }.buttonStyle(.plain).onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                            .help("Open the sign-in page in your browser")
                        HStack(alignment: .center, spacing: 24) {
                            Text(prompt.userCode).font(.system(size: 96, weight: .semibold, design: .monospaced)).kerning(12)
                                .textSelection(.enabled)
                                .accessibilityLabel("Code \(prompt.userCode.map(String.init).joined(separator: " "))")
                            Button {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt.userCode, forType: .string)
                                model.authMessage = "Code copied"
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 34)).foregroundStyle(Design.secondary)
                            }.buttonStyle(.plain).help("Copy the code")
                        }
                    }
                }
                if model.authScreen == .webLogin, let relay = model.authWebLogin?.relayURL {
                    // Away from the TV, the phone page also opens here, or its address can be sent to a phone.
                    HStack(alignment: .center, spacing: 20) {
                        Button { NSWorkspace.shared.open(relay) } label: {
                            Label(relay.absoluteString.replacingOccurrences(of: "http://", with: ""), systemImage: "arrow.up.right.square")
                                .font(Design.body(26, weight: "Medium")).foregroundStyle(Design.accent).lineLimit(1)
                        }.buttonStyle(.plain).onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                            .help("Open the sign-in page in your browser")
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(relay.absoluteString, forType: .string)
                            model.authMessage = "Address copied"
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 30)).foregroundStyle(Design.secondary)
                        }.buttonStyle(.plain).help("Copy the address")
                    }
                }
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
            if model.authScreen == .qr || model.authScreen == .deviceCode || model.authScreen == .webLogin {
                VStack(spacing: 30) {
                    QRCodeView(url: model.authQR).frame(width: 560, height: 560)
                    HStack(spacing: 14) {
                        if model.authError == nil { ProgressView().controlSize(.small).tint(Design.accent) }
                        Text(model.authMessage).font(Design.body(24, weight: "Medium"))
                    }
                    if model.authScreen == .deviceCode || model.authScreen == .webLogin, let expiry = model.authExpiresAt, model.authError == nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(expiry.timeIntervalSince(context.date)))
                            Text("\(model.authScreen == .webLogin ? "Page closes" : "Code expires") in \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                                .font(Design.body(22)).foregroundStyle(Design.secondary).monospacedDigit()
                        }
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
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "↵" : model.controllerConfirmGlyph, title: "Select")
                LegendItem(glyph: model.controllerName == nil || model.keyboardNavigation ? "ESC" : model.controllerBackGlyph, title: "Back")
            }.offset(x: 96, y: 986)
        }.frame(width: 1920, height: 1080)
    }
    private var storeName: String { model.accountName(model.authSourceID ?? model.primaryAccountID) }
    private var title: String {
        switch model.authScreen {
        case .qr: "Your games.\nReady to play."
        case .credentials: "Sign in to Steam"
        case .deviceCode, .webLogin: "Sign in to \(storeName)"
        default: "One more step"
        }
    }
    private var message: String {
        switch model.authScreen {
        case .qr: "Scan the code with Steam on your phone, then approve Playden to bring your library here."
        case .credentials: "Use your Steam account name and password. You may also need a Steam Guard code."
        case .deviceCode where model.authError == nil && model.authDeviceCode != nil:
            "Scan the code with your phone, or open this page and enter the code. Sign in and approve Playden. The page shows Fortnite branding; that’s expected."
        case .webLogin where model.authWebLogin?.relayURL != nil:
            "1. Scan the code with your phone.\n2. Sign in to \(storeName).\n3. Copy the address you land on and paste it into the Playden page."
        case .webLogin: "Sign in to \(storeName) in a window on this Mac, or copy the address you land on after signing in and paste it here."
        default: model.authMessage
        }
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
