import CoreLocation
import Foundation

/// The address-lookup boundary: one query in, matches out. The production implementation asks
/// Apple's geocoder; tests inject a fake so the judging logic is exercised without the network.
protocol AddressGeocoder: Sendable {
    /// Forward-geocode `address`, giving up after `timeout` seconds. Throws `LocationLookupError`
    /// on a timeout, a denial, or a failure; an address with no match returns an empty array.
    func geocode(address: String, timeout: TimeInterval) async throws -> [GeocodedPlace]
}

/// Apple's geocoder. Needs no Reminders or Location Services permission — it only asks
/// CoreLocation to resolve an address — and it never writes anything. On the deadline it cancels
/// the request and reports a timeout (`runGeocode`, remctl-bridge.swift:669).
struct CoreLocationGeocoder: AddressGeocoder {
    func geocode(address: String, timeout: TimeInterval) async throws -> [GeocodedPlace] {
        try await GeocodeRequest().run(address: address, timeout: timeout)
    }
}

/// One in-flight `CLGeocoder` request. CoreLocation delivers its completion on the main queue, so
/// the request lives on the main actor and every resumption of the continuation happens there —
/// the awaiting command runs on the cooperative pool and never blocks that queue.
@MainActor
private final class GeocodeRequest {
    private let geocoder = CLGeocoder()
    private var continuation: CheckedContinuation<[GeocodedPlace], Error>?

    nonisolated init() {}

    func run(address: String, timeout: TimeInterval) async throws -> [GeocodedPlace] {
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.timeOut(after: timeout)
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            geocoder.geocodeAddressString(address) { placemarks, error in
                // Reduce CoreLocation's non-Sendable results to values before leaving the handler.
                let places = (placemarks ?? []).compactMap(GeocodedPlace.init(placemark:))
                let failure = error.map(GeocodeFailure.init(error:))
                Task { @MainActor in self.finish(places: places, failure: failure) }
            }
        }
    }

    private func finish(places: [GeocodedPlace], failure: GeocodeFailure?) {
        guard let continuation else { return }   // the deadline already answered
        self.continuation = nil
        if let error = failure?.lookupError {
            continuation.resume(throwing: error)
        } else if failure != nil {
            continuation.resume(returning: [])   // "no result" is an empty match list, not a failure
        } else {
            continuation.resume(returning: places)
        }
    }

    private func timeOut(after timeout: TimeInterval) {
        guard let continuation else { return }
        self.continuation = nil
        geocoder.cancelGeocode()
        continuation.resume(throwing: LocationLookupError(
            code: "location_lookup_timeout",
            message: "Geocoding did not finish within \(Int(timeout)) seconds."))
    }
}

/// A CoreLocation failure reduced to a Sendable value, with the bridge's code mapping.
private struct GeocodeFailure: Sendable {
    enum Kind: Sendable { case noResult, network, denied, cancelled, other }
    let kind: Kind
    let description: String

    init(error: Error) {
        description = error.localizedDescription
        guard let clError = error as? CLError else { kind = .other; return }
        switch clError.code {
        case .geocodeFoundNoResult, .geocodeFoundPartialResult: kind = .noResult
        case .network: kind = .network
        case .denied: kind = .denied
        case .geocodeCanceled: kind = .cancelled
        default: kind = .other
        }
    }

    /// nil when the geocoder simply found nothing, which is a result rather than an error.
    var lookupError: LocationLookupError? {
        switch kind {
        case .noResult:
            return nil
        case .network:
            return LocationLookupError(code: "location_lookup_failed",
                                       message: "Apple's geocoder could not be reached: \(description)")
        case .denied:
            return LocationLookupError(code: "location_lookup_denied",
                                       message: "Geocoding was denied: \(description)")
        case .cancelled:
            return LocationLookupError(code: "location_lookup_timeout", message: "Geocoding was cancelled.")
        case .other:
            return LocationLookupError(code: "location_lookup_failed", message: "Geocoding failed: \(description)")
        }
    }
}

extension GeocodedPlace {
    /// Build a match from a placemark the way the upstream bridge built its payload
    /// (`placemarkPayload`, remctl-bridge.swift:636): a placemark without coordinates is dropped,
    /// blank fields are omitted, and the address joins street, town, area, postal code and country.
    init?(placemark: CLPlacemark) {
        guard let location = placemark.location else { return nil }
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let street = [placemark.subThoroughfare, placemark.thoroughfare].compactMap(nonEmpty).joined(separator: " ")
        let parts = [nonEmpty(street), placemark.locality, placemark.administrativeArea,
                     placemark.postalCode, placemark.country].compactMap(nonEmpty)
        self.init(
            name: nonEmpty(placemark.name),
            address: parts.isEmpty ? nil : parts.joined(separator: ", "),
            thoroughfare: nonEmpty(placemark.thoroughfare),
            areasOfInterest: placemark.areasOfInterest ?? [],
            postalCode: nonEmpty(placemark.postalCode),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            regionRadius: (placemark.region as? CLCircularRegion)?.radius)
    }
}
