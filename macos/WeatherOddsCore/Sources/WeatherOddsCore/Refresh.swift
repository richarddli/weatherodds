import Foundation

/// A refreshed forecast plus any upstream rate limit seen while producing it.
///
/// The optional secondary model is accounted for separately: its failure must
/// not invalidate a good primary forecast, but a 429 it received still has to
/// reach the shared cooldown.
public struct ForecastRefreshResult: Sendable {
    public let forecast: CachedForecast
    public let rateLimit: UpstreamHTTPFailure?

    public init(_ forecast: CachedForecast, rateLimit: UpstreamHTTPFailure? = nil) {
        self.forecast = forecast
        self.rateLimit = rateLimit
    }
}

/// Fetches both ensemble models and combines them into one cacheable forecast.
///
/// The client is injectable, so retry and caching behavior stays independent of
/// the transport and can be exercised without network access.
public struct ForecastRefresher: Sendable {
    private let client: EnsembleClient

    public init(client: EnsembleClient = EnsembleClient()) {
        self.client = client
    }

    public func refresh(
        for zip: USZipCode,
        location: Location,
        units: Units,
        at now: Date
    ) async throws -> ForecastRefreshResult {
        async let weatherNext = client.fetchAndSummarize(
            model: weatherNextModel,
            latitude: location.latitude,
            longitude: location.longitude,
            units: units,
            maxDays: ensembleForecastDays
        )
        async let optionalECMWF = client.fetchAndSummarizeIfAvailable(
            model: ecmwfModel,
            latitude: location.latitude,
            longitude: location.longitude,
            units: units,
            maxDays: ensembleForecastDays
        )

        // Read the optional model first: it only throws on cancellation, and a
        // primary failure must not discard the rate limit it may have received.
        let ecmwf = try await optionalECMWF
        let primary: SummarizedEnsemble
        do {
            primary = try await weatherNext
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard let rateLimit = ecmwf.httpFailure,
                  rateLimit.isRateLimited,
                  (error as? FetchError)?.upstreamHTTPFailure?.isRateLimited != true
            else {
                throw error
            }
            // The primary model failed for an unrelated reason, so the 429 is
            // the more actionable signal and the one the shared cooldown needs.
            throw FetchError.httpFailure(model: ecmwfModel, failure: rateLimit)
        }

        let summaries = ecmwf.summary.map {
            crossCheck(primary.summaries, ecmwfDays: $0.summaries, units: units)
        } ?? primary.summaries

        return ForecastRefreshResult(
            CachedForecast(
                zip: zip,
                units: units,
                location: location,
                timeZoneIdentifier: primary.timezone,
                utcOffsetSeconds: primary.utcOffsetSeconds,
                fetchedAt: now,
                summaries: summaries,
                ecmwfContributed: ecmwf.summary != nil
            ),
            rateLimit: ecmwf.httpFailure?.isRateLimited == true ? ecmwf.httpFailure : nil
        )
    }
}
