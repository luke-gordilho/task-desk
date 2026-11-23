import AppKit
import UserNotifications
import TaskCore

@MainActor
final class InboxNotifications: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var scheduled: Task<Void, Never>?
    private var delivering = false
    private var retryRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(scheduleDelivery),
            name: Notification.Name("com.movedot.taskdesk.inboxChanged"), object: nil)
        scheduleDelivery()
    }

    func applicationDidBecomeActive(_ notification: Notification) { scheduleDelivery() }

    @objc private func scheduleDelivery() {
        scheduled?.cancel()
        scheduled = Task {
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            await deliver()
        }
    }

    private func deliver() async {
        guard !delivering else { retryRequested = true; return }
        delivering = true
        defer {
            delivering = false
            if retryRequested { retryRequested = false; scheduleDelivery() }
        }
        do {
            let store = try TaskStore()
            var ids = try store.notificationIDs()
            guard !ids.isEmpty else { return }
            let center = UNUserNotificationCenter.current()
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            guard allowed else { return }
            ids = try store.notificationIDs()
            guard let latest = ids.last else { return }
            let content = UNMutableNotificationContent()
            content.title = "Task Desk Inbox"
            content.body = ids.count == 1 ? "1 new proposal is ready to review." : "\(ids.count) new proposals are ready to review."
            content.sound = .default
            content.threadIdentifier = "taskdesk-inbox"
            try await center.add(UNNotificationRequest(identifier: "inbox-\(latest)", content: content, trigger: nil))
            try store.markNotified(ids: ids)
        } catch {
            NSLog("Task Desk inbox notification failed: %@", error.localizedDescription)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        completion([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void) {
        Task { @MainActor in
            if let url = URL(string: "taskdesk://inbox") { NSWorkspace.shared.open(url) }
            completion()
        }
    }
}
