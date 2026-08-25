import Foundation
import Testing
@testable import WeatherOddsCore

@Suite("US zip code validation")
struct USZipCodeTests {
    @Test("Trims boundary whitespace and preserves leading zeroes")
    func normalization() throws {
        #expect(try USZipCode(" \t02108\n").rawValue == "02108")
    }

    @Test(
        "Rejects anything other than five ASCII digits",
        arguments: ["", " ", "2108", "021080", "0210A", "021 8", "02108-1234", "٠٢١٠٨"]
    )
    func invalidValues(value: String) {
        #expect(throws: GeocodeError.self) {
            try USZipCode(value)
        }
    }

    @Test("Decoding cannot bypass the validation invariant")
    func decodingValidates() throws {
        let valid = try JSONDecoder().decode(USZipCode.self, from: Data("\"02108\"".utf8))
        #expect(valid.rawValue == "02108")
        #expect(throws: GeocodeError.invalidPostalCode) {
            try JSONDecoder().decode(USZipCode.self, from: Data("\"../../\"".utf8))
        }
    }

    @Test("Separates configuration errors from retryable failures")
    func errorTaxonomy() {
        #expect(GeocodeError.emptyPostalCode.isInvalidConfiguration)
        #expect(GeocodeError.invalidPostalCode.isInvalidConfiguration)
        #expect(GeocodeError.noMatchingResult.isInvalidConfiguration)
        #expect(!GeocodeError.cancelled.isInvalidConfiguration)
        #expect(!GeocodeError.temporaryFailure.isInvalidConfiguration)
        #expect(GeocodeError.cancelled.isTemporary)
        #expect(GeocodeError.temporaryFailure.isTemporary)
    }

    @Test("Address matching requires a digit-delimited zip token")
    @MainActor
    func addressMatching() {
        #expect(USZipCodeGeocoder.address("Boston, MA 02108, United States", contains: "02108"))
        #expect(USZipCodeGeocoder.address("02108 Boston", contains: "02108"))
        #expect(!USZipCodeGeocoder.address("Boston, MA 102108", contains: "02108"))
        #expect(!USZipCodeGeocoder.address("Boston, MA 021080", contains: "02108"))
    }
}
