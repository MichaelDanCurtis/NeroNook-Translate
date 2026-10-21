import Foundation

/// The one error type of this module: a sentence the app can show as is.
public struct AudioProblem: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// So `error.localizedDescription` shows the message rather than a generic Foundation sentence.
extension AudioProblem: LocalizedError {
    public var errorDescription: String? { message }
}

/// Removes a NotificationCenter observer when released, so owners need no explicit teardown.
final class NotificationObservation {
    private let token: NSObjectProtocol

    /// Observes `name` from `object`, delivering on the main queue.
    init(_ name: Notification.Name, object: AnyObject?, handler: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main, using: handler)
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Signal levels for meters.
enum Levels {
    /// Root mean square of `samples` (linear), clamped to 0…1; 0 when there are no samples.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return min(1, (sum / Float(samples.count)).squareRoot())
    }
}
