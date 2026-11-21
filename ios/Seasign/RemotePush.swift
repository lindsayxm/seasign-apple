import UIKit

/// Receives what the app delegate hears about remote notifications.
/// `GoogleCalendarModel` is the one receiver.
@MainActor
protocol RemotePushReceiver: AnyObject {
    /// The app finished launching (in the foreground or, for a push, in the background).
    func launched()
    func registered(_ token: APNsDeviceToken)
    func registrationFailed()
    /// A remote notification; `type` is the payload's `type` key.
    func received(type: String?) async -> GooglePushOutcome
}

/// Hands the app delegate's callbacks to the receiver the app made at
/// start. The delegate and the app's models are made separately by SwiftUI,
/// in an order this does not rely on: a launch or a device token that comes
/// before the receiver is attached is passed on when it is.
@MainActor
final class RemotePushRelay {
    static let shared = RemotePushRelay()

    private weak var receiver: (any RemotePushReceiver)?
    private var didLaunch = false
    /// Memory only, until a receiver takes it.
    private var pendingToken: APNsDeviceToken?

    func attach(_ receiver: any RemotePushReceiver) {
        self.receiver = receiver
        if didLaunch { receiver.launched() }
        if let pendingToken {
            self.pendingToken = nil
            receiver.registered(pendingToken)
        }
    }

    func launched() {
        didLaunch = true
        receiver?.launched()
    }

    func registered(_ token: APNsDeviceToken) {
        guard let receiver else {
            pendingToken = token
            return
        }
        receiver.registered(token)
    }

    func registrationFailed() {
        receiver?.registrationFailed()
    }

    /// No receiver (the store would not open): nothing to fetch.
    func received(type: String?) async -> GooglePushOutcome {
        guard let receiver else { return .noData }
        return await receiver.received(type: type)
    }
}

/// The UIKit app delegate, for the remote-notification callbacks SwiftUI has
/// no other way to deliver. It asks for no notification permission: the
/// Worker sends background pushes only. Nothing here logs the device token
/// or the registration error.
final class SeasignAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        RemotePushRelay.shared.launched()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushRelay.shared.registered(APNsDeviceToken(deviceToken))
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Asked again when the app next opens. The error is not kept.
        RemotePushRelay.shared.registrationFailed()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let type = userInfo["type"] as? String
        Task { @MainActor in
            let outcome = await RemotePushRelay.shared.received(type: type)
            completionHandler(outcome.fetchResult)
        }
    }
}

extension GooglePushOutcome {
    var fetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: .newData
        case .noData: .noData
        case .failed: .failed
        }
    }
}
