import Foundation
import Domain

struct LauncherNotification: Identifiable, Equatable {
    enum Source: Equatable { case job(UUID), controller }
    enum Tone { case success, failure, warning }
    let id = UUID()
    var source: Source
    var tone: Tone
    var title: String
    var detail: String
    var guidance: String? = nil
}

extension LibraryModel {
    // Modal tasks and durable failures take priority. Keep pending notices until the player
    // can see them; a game running in front of the launcher must not consume their lifetime.
    var visibleNotification: LauncherNotification? {
        guard launcherActive, panel == nil, authScreen == nil, setupScreen == nil,
              !hasActiveSession, !exitOverlay, !showsSessionIssue,
              persistenceError == nil, syncError == nil, !controllerDisconnected else { return nil }
        return notifications.first
    }

    func enqueueNotification(_ notification: LauncherNotification) {
        notifications.removeAll { $0.source == notification.source }
        notifications.append(notification)
        // These are informational; job results and recovery actions remain in Downloads.
        if notifications.count > 8 { notifications.removeFirst(notifications.count - 8) }
    }

    func expireNotification(_ id: UUID) {
        // A cancelled view task cannot dismiss a newer notification or a hidden one.
        guard visibleNotification?.id == id else { return }
        notifications.removeAll { $0.id == id }
    }

    func receiveInstallNotifications(_ jobs: [JobRecord]) {
        let previous = notificationJobs
        notificationJobs = Dictionary(jobs.map { ($0.id, $0.state) }, uniquingKeysWith: { _, latest in latest })
        guard let previous else { return } // Restored history is not a new event.
        for job in jobs where previous[job.id] != job.state {
            guard job.state == .completed || job.state == .failed else { continue }
            let failed = job.state == .failed
            let title: String
            switch job.kind {
            case .install: title = failed ? "Installation failed" : "Download complete"
            case .repair: title = failed ? "Verification failed" : "Files verified"
            case .uninstall: title = failed ? "Removal failed" : "Game uninstalled"
            }
            let name = game(for: job).title
            enqueueNotification(.init(source: .job(job.id), tone: failed ? .failure : .success,
                title: title, detail: failed ? "\(name) · \(job.failure?.reason ?? "The operation could not finish.")" : name,
                guidance: failed ? "Open Downloads for Retry and View logs" : nil))
        }
    }

    func receiveControllerConnection(name: String?, playStation: Bool) {
        let previous = controllerName
        controllerName = name
        playStationGlyphs = name == nil || playStation
        if let name {
            controllerDisconnected = false
            if previous != name {
                enqueueNotification(.init(source: .controller, tone: .success,
                    title: "Controller connected", detail: name))
            }
        } else if previous != nil {
            controllerDisconnected = true
            notifications.removeAll { $0.source == .controller }
        }
    }
}
