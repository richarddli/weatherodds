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
    case invalidLocation
    case cancelled
    case temporaryFailure

    public var isInvalidConfiguration: Bool {
        switch self {
        case .emptyPostalCode, .invalidPostalCode, .noMatchingResult, .invalidLocation:
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
            "That location could not be found."
        case .invalidLocation:
            "Choose a city or postal code in the location picker."
        case .cancelled:
            "The location lookup was cancelled."
        case .temporaryFailure:
            "The location service is temporarily unavailable."
        }
    }
}

/// Stable place identity. Five-digit keys preserve existing ZIP cache filenames.
public struct LocationID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zip = try? USZipCode(value) {
            rawValue = zip.rawValue
        } else if value.hasPrefix("geonames:"),
                  let number = Int(value.dropFirst(9)), number > 0,
                  value == "geonames:\(number)" {
            rawValue = value
        } else {
            throw GeocodeError.invalidLocation
        }
    }

    public static func configured(selected: LocationID?, legacyZip: String?) throws -> LocationID? {
        if let selected { return selected }
        guard let legacyZip,
              !legacyZip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return try LocationID(USZipCode(legacyZip).rawValue)
    }

    public var geonamesID: Int? {
        rawValue.hasPrefix("geonames:") ? Int(rawValue.dropFirst(9)) : nil
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Value-type place shared by search, widget configuration, and durable cache.
public struct Location: Codable, Equatable, Sendable {
    public let id: LocationID
    public let displayName: String
    public let latitude: Double
    public let longitude: Double
    public let countryCode: String?
    public let postalCode: String?
    public let timeZoneIdentifier: String?
    public let utcOffsetSeconds: Int?

    public init(
        id: LocationID, displayName: String, latitude: Double, longitude: Double,
        countryCode: String? = nil, postalCode: String? = nil,
        timeZoneIdentifier: String? = nil, utcOffsetSeconds: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.latitude = latitude
        self.longitude = longitude
        self.countryCode = countryCode
        self.postalCode = postalCode
        self.timeZoneIdentifier = timeZoneIdentifier
        self.utcOffsetSeconds = utcOffsetSeconds
    }

    /// Compatibility initializer for the existing US geocoder.
    public init(
        zip: String, displayName: String, latitude: Double, longitude: Double,
        timeZoneIdentifier: String? = nil, utcOffsetSeconds: Int? = nil
    ) {
        self.init(
            id: try! LocationID(zip), displayName: displayName,
            latitude: latitude, longitude: longitude, countryCode: "US", postalCode: zip,
            timeZoneIdentifier: timeZoneIdentifier, utcOffsetSeconds: utcOffsetSeconds
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, zip, displayName, latitude, longitude, countryCode, postalCode
        case timeZoneIdentifier, utcOffsetSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyZip = try values.decodeIfPresent(String.self, forKey: .zip)
        let identifier = try values.decodeIfPresent(LocationID.self, forKey: .id)
            ?? LocationID(legacyZip ?? "")
        self.init(
            id: identifier,
            displayName: try values.decode(String.self, forKey: .displayName),
            latitude: try values.decode(Double.self, forKey: .latitude),
            longitude: try values.decode(Double.self, forKey: .longitude),
            countryCode: try values.decodeIfPresent(String.self, forKey: .countryCode)
                ?? (legacyZip == nil ? nil : "US"),
            postalCode: try values.decodeIfPresent(String.self, forKey: .postalCode) ?? legacyZip,
            timeZoneIdentifier: try values.decodeIfPresent(String.self, forKey: .timeZoneIdentifier),
            utcOffsetSeconds: try values.decodeIfPresent(Int.self, forKey: .utcOffsetSeconds)
        )
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude),
              !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw GeocodeError.invalidLocation }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(latitude, forKey: .latitude)
        try values.encode(longitude, forKey: .longitude)
        try values.encodeIfPresent(countryCode, forKey: .countryCode)
        try values.encodeIfPresent(postalCode, forKey: .postalCode)
        try values.encodeIfPresent(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        try values.encodeIfPresent(utcOffsetSeconds, forKey: .utcOffsetSeconds)
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
