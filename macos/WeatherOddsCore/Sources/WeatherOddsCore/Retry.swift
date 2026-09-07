import Foundation

/// HTTP-level detail from a failed upstream response.
///
/// This is captured before the body is decoded so a rate-limit response with a
/// non-JSON body still carries its status code and retry headers. The
/// `Retry-After` value is kept verbatim: resolving its HTTP-date form needs the
/// reference date used by the retry policy, not the moment the header arrived.
public struct UpstreamHTTPFailure: Codable, Equatable, Sendable {
    public let statusCode: Int
    public let retryAfterHeader: String?
    public let reason: String?

    public init(statusCode: Int, retryAfterHeader: String? = nil, reason: String? = nil) {
        self.statusCode = statusCode
        self.retryAfterHeader = retryAfterHeader
        self.reason = reason
    }

    /// Whether the upstream asked every caller to stop, not just this request.
    public var isRateLimited: Bool {
        statusCode == 429
    }
}

/// `Retry-After` parsing for both forms allowed by RFC 9110.
public enum RetryAfterHeader {
    /// Returns the delay the server asked for, or nil when it is absent,
    /// malformed, or already elapsed. A non-positive delay is treated as absent
    /// so the caller falls back to its own backoff instead of retrying at once.
    public static func delay(_ value: String?, at now: Date) -> TimeInterval? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }

        // delta-seconds is an unsigned integer; anything else is an HTTP-date.
        if trimmed.allSatisfy(\.isNumber), let seconds = Double(trimmed) {
            return seconds > 0 ? seconds : nil
        }

        guard let date = httpDate(trimmed) else { return nil }
        let delay = date.timeIntervalSince(now)
        return delay > 0 ? delay : nil
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // IMF-fixdate
            "EEEE, dd-MMM-yy HH:mm:ss zzz",    // obsolete RFC 850
            "EEE MMM d HH:mm:ss yyyy",         // obsolete asctime
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

/// Decides when a failed refresh may be attempted again.
///
/// Retries are always handed to WidgetKit as a timeline reload date; the
/// extension never sleeps or loops waiting for a deadline.
public struct RetryPolicy: Sendable {
    /// Delay after a single transient failure.
    public static let baseDelay: TimeInterval = 30 * 60
    /// Documented ceiling for locally computed backoff, matching the interval
    /// between successful refreshes.
    public static let maximumDelay: TimeInterval = 6 * 60 * 60
    /// Ceiling applied to a server-supplied `Retry-After`, which may exceed
    /// `maximumDelay` but must not park the widget indefinitely.
    public static let maximumRetryAfter: TimeInterval = 24 * 60 * 60
    /// Fraction of the computed delay that jitter may subtract. Subtracting
    /// keeps successive delays ordered and never exceeds the cap.
    public static let jitterFraction = 0.2
    /// Retry delay after a cancelled refresh, which records no failure state.
    public static let interruptedDelay: TimeInterval = 5 * 60

    /// Returns a value in `0..<1`. Injectable so tests are deterministic.
    private let jitter: @Sendable () -> Double

    public init(jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.jitter = jitter
    }

    /// Capped exponential backoff for the nth consecutive failure, where the
    /// first failure is 1.
    public func delay(forConsecutiveFailures failures: Int) -> TimeInterval {
        // Clamping the exponent keeps a corrupt or absurd counter finite.
        let exponent = min(max(failures, 1) - 1, 16)
        let capped = min(Self.baseDelay * pow(2, Double(exponent)), Self.maximumDelay)
        let fraction = min(max(jitter(), 0), 1)
        return capped * (1 - Self.jitterFraction * fraction)
    }

    /// The earliest permitted next attempt. A usable `Retry-After` wins over
    /// local backoff, including when it is longer than `maximumDelay`.
    public func nextAttempt(
        at now: Date,
        consecutiveFailures: Int,
        httpFailure: UpstreamHTTPFailure? = nil
    ) -> Date {
        if let requested = RetryAfterHeader.delay(httpFailure?.retryAfterHeader, at: now) {
            return now.addingTimeInterval(min(requested, Self.maximumRetryAfter))
        }
        return now.addingTimeInterval(delay(forConsecutiveFailures: consecutiveFailures))
    }
}

/// Durable cooldown state for one retry key.
///
/// `recordedAt` is retained so a clock change cannot leave a widget parked: a
/// record written in the future is ignored, and a deadline further out than
/// `RetryPolicy.maximumRetryAfter` is clamped.
public struct RetryState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let key: String
    public let consecutiveFailures: Int
    public let recordedAt: Date
    public let nextAttemptAfter: Date

    public init(
        schemaVersion: Int = RetryState.currentSchemaVersion,
        key: String,
        consecutiveFailures: Int,
        recordedAt: Date,
        nextAttemptAfter: Date
    ) {
        self.schemaVersion = schemaVersion
        self.key = key
        self.consecutiveFailures = consecutiveFailures
        self.recordedAt = recordedAt
        self.nextAttemptAfter = nextAttemptAfter
    }

    /// The deadline this record imposes at `now`, or nil when an attempt is
    /// permitted.
    public func activeDeadline(at now: Date) -> Date? {
        guard now >= recordedAt else { return nil }
        let deadline = min(
            nextAttemptAfter,
            recordedAt.addingTimeInterval(RetryPolicy.maximumRetryAfter)
        )
        return now < deadline ? deadline : nil
    }

    /// The failure count a following failure should build on. A record whose
    /// deadline has long passed still counts, so a persistently broken upstream
    /// does not restart at the base delay on every wake-up.
    public func failureCount(at now: Date) -> Int {
        now >= recordedAt ? consecutiveFailures : 0
    }
}

/// Why a refresh produced no forecast, and when the next attempt is permitted.
public struct ForecastUnavailable: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Suppressed by a durable cooldown before any request was made.
        case cooldown
        /// The upstream returned HTTP 429 for this or another configuration.
        case rateLimited
        /// Any other retryable failure, including transport errors.
        case transient
    }

    public let reason: Reason
    public let nextAttempt: Date
    public let consecutiveFailures: Int
    public let httpFailure: UpstreamHTTPFailure?
    public let message: String?

    public init(
        reason: Reason,
        nextAttempt: Date,
        consecutiveFailures: Int,
        httpFailure: UpstreamHTTPFailure? = nil,
        message: String? = nil
    ) {
        self.reason = reason
        self.nextAttempt = nextAttempt
        self.consecutiveFailures = consecutiveFailures
        self.httpFailure = httpFailure
        self.message = message
    }
}

extension ForecastUnavailable: LocalizedError {
    public var errorDescription: String? {
        switch reason {
        case .cooldown:
            "Forecast refresh is waiting for its next permitted attempt."
        case .rateLimited:
            "The forecast service asked callers to slow down."
        case .transient:
            message ?? "Forecast service is temporarily unavailable."
        }
    }
}
