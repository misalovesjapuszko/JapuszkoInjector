import Foundation
import UserNotifications

/// Local "this app expires soon" reminders.
enum Notifier {
    private static let prefix = "expiry."

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func schedule(apps: [AppRecord], selfExpiry: Date?) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            let old = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)

            var items: [(String, String, Date)] = apps.filter { !$0.isSelf }.map {
                ($0.id, $0.name, Date(timeIntervalSince1970: TimeInterval($0.expiresAt)))
            }
            if let s = selfExpiry { items.append(("__self__", "JapuszkoInjector", s)) }

            for (id, name, expiry) in items {
                for (tag, before, text) in [
                    ("24h", 24.0 * 3600, "expires in 24 hours"),
                    ("3h", 3.0 * 3600, "expires in 3 hours. Open JapuszkoInjector with the VPN on."),
                ] {
                    let fire = expiry.addingTimeInterval(-before)
                    guard fire > Date() else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = name
                    content.body = "\(name) \(text)"
                    content.sound = .default
                    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    center.add(UNNotificationRequest(identifier: "\(prefix)\(id).\(tag)", content: content, trigger: trigger))
                }
            }
        }
    }

    /// "Tap to open X" right after the injector closes itself.
    static func relaunch(_ name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Tap to start \(name)"
        content.body = "It runs inside JapuszkoInjector. Swipe it away in the app switcher to come back."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "relaunch", content: content, trigger: trigger))
    }

    static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
