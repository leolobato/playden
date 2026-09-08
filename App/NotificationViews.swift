import SwiftUI

struct NotificationToasts: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            if model.controllerDisconnected && model.panel != .controllerTest {
                ToastCard(tone: .warning, title: "Controller disconnected",
                          detail: "Reconnect your controller to keep playing.")
                    .transition(transition)
            } else if let notification = model.visibleNotification {
                ToastCard(tone: notification.tone, title: notification.title,
                          detail: notification.detail, guidance: notification.guidance)
                    .id(notification.id).transition(transition)
            }
        }
        .frame(width: 560, height: 230)
        .allowsHitTesting(false)
        .animation(model.reducedMotion ? nil : .easeOut(duration: 0.2), value: model.visibleNotification?.id)
        .animation(model.reducedMotion ? nil : .easeOut(duration: 0.2), value: model.controllerDisconnected)
        .task(id: model.visibleNotification?.id) {
            guard !model.fixedClock, let id = model.visibleNotification?.id else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !Task.isCancelled else { return }
            model.expireNotification(id)
        }
    }

    private var transition: AnyTransition {
        model.reducedMotion ? .identity : .opacity.combined(with: .offset(y: 20))
    }
}

private struct ToastCard: View {
    var tone: LauncherNotification.Tone
    var title: String
    var detail: String
    var guidance: String? = nil
    private var color: Color {
        switch tone { case .success: Design.green; case .failure: Design.red; case .warning: Design.amber }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Design.condensed(24)).foregroundStyle(Design.text)
                Text(detail).font(Design.body(18)).foregroundStyle(Design.secondary).lineLimit(2)
                if let guidance { Text(guidance).font(Design.body(18, weight: "Medium")).foregroundStyle(Design.accent) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 18).padding(.horizontal, 22)
        .background(Design.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Design.text.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
    }
}
