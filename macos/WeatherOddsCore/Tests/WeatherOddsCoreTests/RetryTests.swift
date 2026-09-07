import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("Retry-After parsing")
struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("delta-seconds is honored")
    func deltaSeconds() {
        #expect(RetryAfterHeader.delay("120", at: now) == 120)
        #expect(RetryAfterHeader.delay("  900  ", at: now) == 900)
    }

    @Test("HTTP-date forms are resolved against the reference date")
    func httpDates() {
        #expect(
            RetryAfterHeader.delay("Fri, 15 Jan 2027 08:15:00 GMT", at: now) == 900
        )
        #expect(
            RetryAfterHeader.delay("Friday, 15-Jan-27 08:15:00 GMT", at: now) == 900
        )
        #expect(RetryAfterHeader.delay("Fri Jan 15 08:15:00 2027", at: now) == 900)
    }

    @Test("Absent, malformed, and elapsed values fall back to local policy")
    func unusableValues() {
        #expect(RetryAfterHeader.delay(nil, at: now) == nil)
        #expect(RetryAfterHeader.delay("", at: now) == nil)
        #expect(RetryAfterHeader.delay("soon", at: now) == nil)
        #expect(RetryAfterHeader.delay("-120", at: now) == nil)
        #expect(RetryAfterHeader.delay("12.5", at: now) == nil)
        // Zero would mean retry immediately, which the widget never should.
        #expect(RetryAfterHeader.delay("0", at: now) == nil)
        #expect(RetryAfterHeader.delay("Fri, 15 Jan 2027 07:59:00 GMT", at: now) == nil)
    }
}

@Suite("Retry backoff policy")
struct RetryPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Consecutive failures double the delay up to the documented cap")
    func exponentialBackoffToCap() {
        let policy = RetryPolicy(jitter: { 0 })
        let expected: [TimeInterval] = [
            30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60,
            6 * 60 * 60, 6 * 60 * 60, 6 * 60 * 60,
        ]
        for (index, delay) in expected.enumerated() {
            #expect(policy.delay(forConsecutiveFailures: index + 1) == delay)
        }
        #expect(policy.delay(forConsecutiveFailures: 500) == RetryPolicy.maximumDelay)
        // A corrupt counter must not produce a shorter delay than one failure.
        #expect(policy.delay(forConsecutiveFailures: 0) == RetryPolicy.baseDelay)
    }

    @Test("Jitter subtracts a bounded fraction and keeps delays ordered")
    func jitterStaysBounded() {
        let full = RetryPolicy(jitter: { 1 })
        #expect(full.delay(forConsecutiveFailures: 1) == 30 * 60 * 0.8)
        #expect(full.delay(forConsecutiveFailures: 5) == RetryPolicy.maximumDelay * 0.8)

        var previous: TimeInterval = 0
        let varying = RetryPolicy(jitter: { Double.random(in: 0..<1) })
        for failures in 1...4 {
            let delay = varying.delay(forConsecutiveFailures: failures)
            let capped = min(
                RetryPolicy.baseDelay * pow(2, Double(failures - 1)),
                RetryPolicy.maximumDelay
            )
            #expect(delay > previous)
            #expect(delay <= capped)
            #expect(delay >= capped * (1 - RetryPolicy.jitterFraction))
            previous = delay
        }
    }

    @Test("Retry-After overrides backoff, even beyond the local cap")
    func retryAfterWins() {
        let policy = RetryPolicy(jitter: { 0 })
        let beyondCap = policy.nextAttempt(
            at: now,
            consecutiveFailures: 1,
            httpFailure: UpstreamHTTPFailure(statusCode: 429, retryAfterHeader: "43200")
        )
        #expect(beyondCap == now.addingTimeInterval(12 * 60 * 60))
        #expect(beyondCap > now.addingTimeInterval(RetryPolicy.maximumDelay))

        // An absurd value is still bounded so the widget cannot be parked.
        let absurd = policy.nextAttempt(
            at: now,
            consecutiveFailures: 1,
            httpFailure: UpstreamHTTPFailure(statusCode: 429, retryAfterHeader: "9999999")
        )
        #expect(absurd == now.addingTimeInterval(RetryPolicy.maximumRetryAfter))

        let malformed = policy.nextAttempt(
            at: now,
            consecutiveFailures: 2,
            httpFailure: UpstreamHTTPFailure(statusCode: 429, retryAfterHeader: "later")
        )
        #expect(malformed == now.addingTimeInterval(60 * 60))
    }

    @Test("A record written in the future is ignored rather than parking the widget")
    func clockChangeIsIgnored() {
        let state = RetryState(
            key: "02108-imperial",
            consecutiveFailures: 3,
            recordedAt: now.addingTimeInterval(60 * 60),
            nextAttemptAfter: now.addingTimeInterval(2 * 60 * 60)
        )
        #expect(state.activeDeadline(at: now) == nil)
        #expect(state.failureCount(at: now) == 0)

        // A deadline further out than any legitimate Retry-After is clamped.
        let runaway = RetryState(
            key: "02108-imperial",
            consecutiveFailures: 1,
            recordedAt: now,
            nextAttemptAfter: now.addingTimeInterval(400 * 60 * 60)
        )
        #expect(
            runaway.activeDeadline(at: now)
                == now.addingTimeInterval(RetryPolicy.maximumRetryAfter)
        )
    }
}

@Suite("Durable retry cooldowns")
struct RetryCooldownTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A recorded cooldown suppresses requests across new cache instances")
    func cooldownSurvivesRestart() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")

        let first = await timedOutRefresh(retryTestCache(root), zip: zip, at: now)
        let deadline = try #require(first?.nextAttempt)
        #expect(deadline == now.addingTimeInterval(RetryPolicy.baseDelay))

        // Every entry point re-reads the durable state, so an early timeline
        // reload or a restarted extension issues no further requests.
        for offset: TimeInterval in [0, 60, RetryPolicy.baseDelay - 1] {
            let cache = retryTestCache(root)
            let at = now.addingTimeInterval(offset)
            #expect(await cache.nextEligibleAttempt(for: zip, units: .imperial, at: at) == deadline)
            let blocked = await suppressedRefresh(cache, zip: zip, at: at)
            #expect(blocked?.reason == .cooldown)
            #expect(blocked?.nextAttempt == deadline)
        }

        #expect(
            await retryTestCache(root)
                .nextEligibleAttempt(for: zip, units: .imperial, at: deadline) == nil
        )
    }

    @Test("Consecutive failures lengthen the cooldown and recovery resets it")
    func backoffGrowsAndResets() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let cache = retryTestCache(root)
        var at = now
        let expected: [TimeInterval] = [30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60]

        for (index, delay) in expected.enumerated() {
            let failure = await timedOutRefresh(cache, zip: zip, at: at)
            #expect(failure?.consecutiveFailures == index + 1)
            #expect(failure?.nextAttempt == at.addingTimeInterval(delay))
            at = try #require(failure?.nextAttempt)
        }

        let recovered = retryTestForecast(zip: zip, fetchedAt: at)
        let result = try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: at) {
            ForecastRefreshResult(recovered)
        }
        #expect(result == recovered)
        #expect(await cache.retryState(for: zip, units: .imperial) == nil)
        #expect(await cache.nextEligibleAttempt(for: zip, units: .imperial, at: at) == nil)

        // The next failure starts over at the base delay.
        let after = at.addingTimeInterval(CachedForecast.refreshInterval)
        let restarted = await timedOutRefresh(cache, zip: zip, at: after)
        #expect(restarted?.consecutiveFailures == 1)
        #expect(restarted?.nextAttempt == after.addingTimeInterval(RetryPolicy.baseDelay))
    }

    @Test("HTTP 429 holds every ZIP and unit choice off until Retry-After")
    func rateLimitAppliesAcrossConfigurations() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let boston = try USZipCode("02108")
        let newYork = try USZipCode("10001")

        let limited = await #expect(throws: ForecastUnavailable.self) {
            try await retryTestCache(root).loadOrRefreshForecast(
                for: boston, units: .imperial, at: now
            ) {
                throw FetchError.httpFailure(
                    model: weatherNextModel,
                    failure: UpstreamHTTPFailure(
                        statusCode: 429,
                        retryAfterHeader: "Fri, 15 Jan 2027 08:15:00 GMT"
                    )
                )
            }
        }
        #expect(limited?.reason == .rateLimited)
        #expect(limited?.nextAttempt == now.addingTimeInterval(900))

        // A different ZIP and a different unit choice share the same upstream
        // quota, so neither may bypass the cooldown.
        for (zip, units) in [(newYork, Units.imperial), (boston, .metric), (newYork, .metric)] {
            let cache = retryTestCache(root)
            #expect(
                await cache.nextEligibleAttempt(for: zip, units: units, at: now)
                    == now.addingTimeInterval(900)
            )
            let blocked = await suppressedRefresh(cache, zip: zip, units: units, at: now)
            #expect(blocked?.reason == .cooldown)
            // The count belongs to the record that imposed the deadline, so a
            // configuration that has never failed still reports the shared one.
            #expect(blocked?.consecutiveFailures == 1)
        }

        // Recovery on one configuration clears the shared cooldown.
        let at = now.addingTimeInterval(900)
        let forecast = retryTestForecast(zip: newYork, fetchedAt: at)
        _ = try await retryTestCache(root).loadOrRefreshForecast(
            for: newYork, units: .imperial, at: at
        ) {
            ForecastRefreshResult(forecast)
        }
        #expect(
            await retryTestCache(root)
                .nextEligibleAttempt(for: boston, units: .imperial, at: at) == nil
        )
    }

    @Test("A rate-limited optional model keeps its forecast but records the cooldown")
    func optionalModelRateLimitIsRecorded() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let other = try USZipCode("10001")
        let cache = retryTestCache(root)
        let refresher = ForecastRefresher(client: EnsembleClient(loader: RetryTestLoader(
            responses: [
                weatherNextModel: .init(data: retryTestPayload(), statusCode: 200),
                ecmwfModel: .init(
                    data: Data("Too Many Requests".utf8),
                    statusCode: 429,
                    headerFields: ["Retry-After": "1800"]
                ),
            ]
        )))

        let forecast = try await cache.loadOrRefreshForecast(
            for: zip, units: .imperial, at: now
        ) {
            try await refresher.refresh(
                for: zip, location: retryTestLocation(), units: .imperial, at: self.now
            )
        }

        // The secondary model's failure degrades the forecast, never fails it.
        #expect(!forecast.summaries.isEmpty)
        #expect(forecast.ecmwfContributed == false)
        #expect(await cache.loadForecast(for: zip, units: .imperial) == forecast)

        // The primary succeeded, so only the shared rate limit survives.
        #expect(await cache.retryState(for: zip, units: .imperial) == nil)
        let deadline = now.addingTimeInterval(1800)
        #expect(
            await cache.nextEligibleAttempt(for: other, units: .metric, at: now) == deadline
        )
        let blocked = await suppressedRefresh(cache, zip: other, units: .metric, at: now)
        #expect(blocked?.nextAttempt == deadline)
    }

    @Test("A transient optional-model failure records nothing")
    func optionalModelTransientFailureIsNotRecorded() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let cache = retryTestCache(root)
        let refresher = ForecastRefresher(client: EnsembleClient(loader: RetryTestLoader(
            responses: [
                weatherNextModel: .init(data: retryTestPayload(), statusCode: 200),
                ecmwfModel: .init(data: Data("Bad Gateway".utf8), statusCode: 502),
            ]
        )))

        let forecast = try await cache.loadOrRefreshForecast(
            for: zip, units: .imperial, at: now
        ) {
            try await refresher.refresh(
                for: zip, location: retryTestLocation(), units: .imperial, at: self.now
            )
        }

        #expect(forecast.ecmwfContributed == false)
        #expect(await cache.nextEligibleAttempt(for: zip, units: .imperial, at: now) == nil)
    }

    @Test("Cancellation records no cooldown and leaves the cache untouched")
    func cancellationIsNotAFailure() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let cache = retryTestCache(root)
        let stale = retryTestForecast(
            zip: zip, fetchedAt: now.addingTimeInterval(-7 * 60 * 60)
        )
        try await cache.saveForecast(stale, for: zip, units: .imperial)

        await #expect(throws: CancellationError.self) {
            try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
                throw CancellationError()
            }
        }

        #expect(await cache.retryState(for: zip, units: .imperial) == nil)
        #expect(await cache.retryState(forKey: WeatherOddsCache.rateLimitKey) == nil)
        #expect(await cache.nextEligibleAttempt(for: zip, units: .imperial, at: now) == nil)
        // Usable stale data stays available for the failure timeline to show.
        #expect(await cache.loadForecast(for: zip, units: .imperial) == stale)
        #expect(stale.isUsableFallback(at: now, currentLocalDate: "2027-01-15"))
    }

    @Test("A cooldown does not hide a still-fresh forecast")
    func freshForecastOutranksCooldown() async throws {
        let root = retryTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = try USZipCode("02108")
        let cache = retryTestCache(root)
        let fresh = retryTestForecast(zip: zip, fetchedAt: now)
        try await cache.saveForecast(fresh, for: zip, units: .imperial)

        _ = await #expect(throws: ForecastUnavailable.self) {
            try await cache.loadOrRefreshForecast(
                for: try USZipCode("10001"), units: .imperial, at: now
            ) {
                throw FetchError.httpFailure(
                    model: weatherNextModel,
                    failure: UpstreamHTTPFailure(statusCode: 429, retryAfterHeader: "600")
                )
            }
        }

        let result = try await cache.loadOrRefreshForecast(for: zip, units: .imperial, at: now) {
            Issue.record("A fresh forecast needs no request")
            throw RetryTestError.unexpectedRequest
        }
        #expect(result == fresh)

    }
}

/// A transient transport failure, expressed as one call so the type checker
/// does not have to solve the nested closures at every use site.
private func timedOutRefresh(
    _ cache: WeatherOddsCache,
    zip: USZipCode,
    units: Units = .imperial,
    at now: Date
) async -> ForecastUnavailable? {
    await #expect(throws: ForecastUnavailable.self) {
        try await cache.loadOrRefreshForecast(for: zip, units: units, at: now) {
            throw FetchError.requestFailed(model: weatherNextModel, code: .timedOut)
        }
    }
}

/// Asserts a request is suppressed by a durable cooldown rather than issued.
private func suppressedRefresh(
    _ cache: WeatherOddsCache,
    zip: USZipCode,
    units: Units = .imperial,
    at now: Date
) async -> ForecastUnavailable? {
    await #expect(throws: ForecastUnavailable.self) {
        try await cache.loadOrRefreshForecast(for: zip, units: units, at: now) {
            Issue.record("A cooldown must not permit another request")
            throw RetryTestError.unexpectedRequest
        }
    }
}

private enum RetryTestError: Error { case unexpectedRequest }

private func retryTestRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "WeatherOddsRetryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Jitter is pinned so every deadline in these tests is exact.
private func retryTestCache(_ root: URL) -> WeatherOddsCache {
    WeatherOddsCache(rootDirectory: root, retryPolicy: RetryPolicy(jitter: { 0 }))
}

private func retryTestLocation() -> Location {
    Location(
        zip: "02108",
        displayName: "Boston, MA",
        latitude: 42.357,
        longitude: -71.063,
        timeZoneIdentifier: "America/New_York",
        utcOffsetSeconds: -18_000
    )
}

private func retryTestForecast(zip: USZipCode, fetchedAt: Date) -> CachedForecast {
    CachedForecast(
        zip: zip,
        units: .imperial,
        location: Location(
            zip: zip.rawValue,
            displayName: zip.rawValue,
            latitude: 42,
            longitude: -71,
            timeZoneIdentifier: "America/New_York",
            utcOffsetSeconds: -18_000
        ),
        timeZoneIdentifier: "America/New_York",
        utcOffsetSeconds: -18_000,
        fetchedAt: fetchedAt,
        summaries: [DaySummary(
            date: "2027-01-15",
            highMedian: 50,
            highP10: 45,
            highP90: 55,
            lowMedian: 35,
            lowP10: 30,
            lowP90: 40,
            spread: 10,
            rainProbability: 0.25,
            membersWet: 1,
            membersTotal: 4,
            amountMedian: 0.1,
            amountP90: 0.25,
            windMedianMax: 12,
            gustsP90: nil,
            cloudCover: 45,
            steps: 24,
            partial: false,
            rating: "Medium",
            points: 2
        )],
        ecmwfContributed: true
    )
}

private func retryTestPayload() -> Data {
    let object: [String: Any] = [
        "latitude": 42.25,
        "longitude": -71.25,
        "timezone": "America/New_York",
        "utc_offset_seconds": -18_000,
        "hourly_units": [
            "temperature_2m": "°F",
            "precipitation": "inch",
        ],
        "hourly": [
            "time": ["2027-01-15T00:00", "2027-01-15T06:00"],
            "temperature_2m": [40.0, 48.0],
            "temperature_2m_member01": [41.0, 49.0],
            "precipitation": [0.0, 0.1],
            "precipitation_member01": [0.0, 0.2],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

/// Answers per requested `models` parameter so the two ensemble requests can
/// be given different outcomes.
private struct RetryTestLoader: ForecastDataLoading {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int
        var headerFields: [String: String] = [:]
    }

    let responses: [String: Response]

    func data(forForecastRequest request: URLRequest) async throws -> (Data, URLResponse) {
        let model = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "models" }?.value
        guard let model, let response = responses[model] else {
            throw URLError(.unsupportedURL)
        }
        return (
            response.data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headerFields
            )!
        )
    }
}

@Suite("Combined model refresh")
struct ForecastRefresherTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("A 429 on the optional model survives an unrelated primary failure")
    func optionalRateLimitOutlivesPrimaryFailure() async throws {
        let refresher = ForecastRefresher(client: EnsembleClient(loader: RetryTestLoader(
            responses: [
                weatherNextModel: .init(data: Data("Bad Gateway".utf8), statusCode: 502),
                ecmwfModel: .init(
                    data: Data("Too Many Requests".utf8),
                    statusCode: 429,
                    headerFields: ["Retry-After": "1200"]
                ),
            ]
        )))

        let error = await #expect(throws: FetchError.self) {
            try await refresher.refresh(
                for: try USZipCode("02108"),
                location: retryTestLocation(),
                units: .imperial,
                at: self.now
            )
        }
        #expect(error?.upstreamHTTPFailure?.isRateLimited == true)
        #expect(error?.upstreamHTTPFailure?.retryAfterHeader == "1200")
    }

    @Test("Without a rate limit, the primary model's own failure is unchanged")
    func primaryFailureIsPreserved() async throws {
        let refresher = ForecastRefresher(client: EnsembleClient(loader: RetryTestLoader(
            responses: [
                weatherNextModel: .init(data: Data("Service Unavailable".utf8), statusCode: 503),
                ecmwfModel: .init(data: Data("Bad Gateway".utf8), statusCode: 502),
            ]
        )))

        let error = await #expect(throws: FetchError.self) {
            try await refresher.refresh(
                for: try USZipCode("02108"),
                location: retryTestLocation(),
                units: .imperial,
                at: self.now
            )
        }
        #expect(error == .httpFailure(
            model: weatherNextModel,
            failure: UpstreamHTTPFailure(statusCode: 503)
        ))
    }

    @Test("Both models succeeding cross-checks the summaries")
    func bothModelsContribute() async throws {
        let refresher = ForecastRefresher(client: EnsembleClient(loader: RetryTestLoader(
            responses: [
                weatherNextModel: .init(data: retryTestPayload(), statusCode: 200),
                ecmwfModel: .init(data: retryTestPayload(), statusCode: 200),
            ]
        )))

        let result = try await refresher.refresh(
            for: try USZipCode("02108"),
            location: retryTestLocation(),
            units: .imperial,
            at: now
        )
        #expect(result.forecast.ecmwfContributed)
        #expect(result.rateLimit == nil)
        #expect(result.forecast.fetchedAt == now)
        #expect(result.forecast.timeZoneIdentifier == "America/New_York")
        #expect(result.forecast.summaries.allSatisfy { $0.ecmwfAgrees == true })
    }
}
