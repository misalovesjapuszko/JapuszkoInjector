import BackgroundTasks
import Foundation

enum BackgroundRefresh {
    static let identifier = "com.japuszko.injector.refresh"

    /// Ask iOS to wake us in a few hours. iOS decides when; the Shortcuts
    /// automation is the reliable path, this is the bonus one.
    static func schedule() {
        let req = BGAppRefreshTaskRequest(identifier: identifier)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }
}
