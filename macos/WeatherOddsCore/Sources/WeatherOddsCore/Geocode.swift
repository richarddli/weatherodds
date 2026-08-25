import Foundation
import MapKit

/// A validated five-digit United States postal code.
public struct USZipCode: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw GeocodeError.emptyPostalCode
        }
        guard normalized.count == 5,
              normalized.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else {
            throw GeocodeError.invalidPostalCode
        }
        self.rawValue = normalized
    }

    public init(_ value: String) throws {
        try self.init(rawValue: value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Errors are split by whether changing configuration or retrying can fix them.
public enum GeocodeError: Error, Equatable, Sendable {
    case emptyPostalCode
    case invalidPostalCode
    case noMatchingResult
    case cancelled
    case temporaryFailure

    public var isInvalidConfiguration: Bool {
        switch self {
        case .emptyPostalCode, .invalidPostalCode, .noMatchingResult:
            true
        case .cancelled, .temporaryFailure:
            false
        }
    }

    public var isTemporary: Bool {
        !isInvalidConfiguration
    }
}

extension GeocodeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPostalCode:
            "Enter a five-digit US zip code."
        case .invalidPostalCode:
            "The zip code must contain exactly five digits."
        case .noMatchingResult:
            "That zip code could not be found in the United States."
        case .cancelled:
            "The location lookup was cancelled."
        case .temporaryFailure:
            "The location service is temporarily unavailable."
        }
    }
}

/// The value-type location that may safely leave the main actor and be cached.
public struct Location: Codable, Equatable, Sendable {
    public let zip: String
    public let displayName: String
    public let latitude: Double
    public let longitude: Double
    public let timeZoneIdentifier: String?
    public let utcOffsetSeconds: Int?

    public init(
        zip: String,
        displayName: String,
        latitude: Double,
        longitude: Double,
        timeZoneIdentifier: String? = nil,
        utcOffsetSeconds: Int? = nil
    ) {
        self.zip = zip
        self.displayName = displayName
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
    }
}

/// Resolves US zip codes through MapKit and converts results to Sendable values.
@MainActor
public struct USZipCodeGeocoder {
    public init() {}

    public func location(for value: String) async throws -> Location {
        let zip: USZipCode
        do {
            zip = try USZipCode(value)
        } catch let error as GeocodeError {
            throw error
        } catch {
            throw GeocodeError.invalidPostalCode
        }

        guard let request = MKGeocodingRequest(
            addressString: "\(zip.rawValue), United States"
        ) else {
            throw GeocodeError.temporaryFailure
        }
        request.preferredLocale = Locale(identifier: "en_US")

        let mapItems: [MKMapItem]
        do {
            mapItems = try await request.mapItems
        } catch is CancellationError {
            throw GeocodeError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw GeocodeError.cancelled
        } catch {
            if Task.isCancelled {
                throw GeocodeError.cancelled
            }
            throw GeocodeError.temporaryFailure
        }

        guard let item = mapItems.first(where: { mapItem in
            guard let representations = mapItem.addressRepresentations else {
                return false
            }
            let isUnitedStates = representations.region?.identifier == "US"
            let fullAddress = representations.fullAddress(
                includingRegion: true,
                singleLine: true
            )
            return isUnitedStates && fullAddress.map {
                Self.address($0, contains: zip.rawValue)
            } == true
        }) else {
            throw GeocodeError.noMatchingResult
        }

        let representations = item.addressRepresentations
        let displayName = Self.firstNonempty(
            representations?.cityWithContext,
            item.name,
            "US \(zip.rawValue)"
        )
        let timeZone = item.timeZone
        let coordinate = item.location.coordinate

        return Location(
            zip: zip.rawValue,
            displayName: displayName,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            timeZoneIdentifier: timeZone?.identifier,
            utcOffsetSeconds: timeZone?.secondsFromGMT()
        )
    }

    /// Match the zip as a token so a longer numeric identifier cannot pass.
    static func address(_ address: String, contains zip: String) -> Bool {
        var searchStart = address.startIndex

        while let range = address.range(of: zip, range: searchStart..<address.endIndex) {
            let precedingIsDigit = range.lowerBound > address.startIndex
                && address.unicodeScalars[
                    address.unicodeScalars.index(before: range.lowerBound)
                ].properties.numericType != nil
            let followingIsDigit = range.upperBound < address.endIndex
                && address.unicodeScalars[range.upperBound].properties.numericType != nil

            if !precedingIsDigit && !followingIsDigit {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    static func firstNonempty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        preconditionFailure("A nonempty fallback is required")
    }
}
