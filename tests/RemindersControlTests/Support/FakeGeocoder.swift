import Foundation
@testable import RemindersControl

/// A geocoder that answers from a script instead of the network, and records what it was asked.
final class FakeGeocoder: AddressGeocoder, @unchecked Sendable {
    private let places: [GeocodedPlace]
    private let error: LocationLookupError?
    private(set) var queries: [String] = []
    private(set) var timeouts: [TimeInterval] = []

    init(places: [GeocodedPlace] = [], error: LocationLookupError? = nil) {
        self.places = places
        self.error = error
    }

    func geocode(address: String, timeout: TimeInterval) async throws -> [GeocodedPlace] {
        queries.append(address)
        timeouts.append(timeout)
        if let error { throw error }
        return places
    }
}

/// Upstream's fixture matches (tests/test_search_batch_location.py:338).
enum GeocodeFixtures {
    /// A street-sized match: one square in Rome.
    static let piazzaNavona = GeocodedPlace(
        name: "Piazza Navona", address: "Piazza Navona, Rome, Lazio, 00186, Italy",
        thoroughfare: "Piazza Navona", postalCode: "00186",
        latitude: 41.8978252, longitude: 12.4732402, regionRadius: 70.7)

    /// A whole city: one best guess with a region several kilometers wide.
    static let rome = GeocodedPlace(
        name: "Rome", address: "Rome, Lazio, Italy",
        latitude: 41.8893, longitude: 12.4935, regionRadius: 38253.2)

    /// Apple's best guess for a street it did not find.
    static let rykneldCourt = GeocodedPlace(
        name: "1 Rykneld Court, Main Street", address: "1 Rykneld Court, Alfreton, England, DE55 7BQ, United Kingdom",
        thoroughfare: "Rykneld Court", postalCode: "DE55 7BQ",
        latitude: 53.0978252, longitude: -1.3832402, regionRadius: 70.7)

    /// A street name thousands of Italian towns share.
    static let viaRoma = GeocodedPlace(
        name: "Via Roma 1", address: "Via Roma 1, Viterbo, Lazio, 00046, Italy",
        thoroughfare: "Via Roma", postalCode: "00046",
        latitude: 41.7, longitude: 12.6, regionRadius: 70.7)
}
