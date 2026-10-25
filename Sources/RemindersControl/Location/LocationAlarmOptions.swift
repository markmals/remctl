import Foundation

/// A `--location-address` turned into an alarm target, with what the result reports about it.
struct ResolvedLocation: Equatable {
    var query: String
    var title: String
    var address: String?
    var latitude: Double
    var longitude: Double
    var precision: LocationPrecision
    var radius: Double
    var proximity: String

    /// The `resolvedLocation` object `add --json` / `edit --json` append to their payload.
    var json: JSONValue {
        .object([
            ("query", .string(query)),
            ("title", .string(title)),
            ("address", address.map(JSONValue.string) ?? .null),
            ("latitude", .double(latitude)),
            ("longitude", .double(longitude)),
            ("precision", .string(precision.rawValue)),
            ("radius", .double(radius)),
            ("proximity", .string(proximity)),
            ("source", .string("geocoded")),
        ])
    }

    /// The one line human output adds for a geocoded alarm.
    var humanLine: String {
        "Location: \(safeDisplay(address ?? title)) (\(coordinate(latitude)), \(coordinate(longitude)))\n"
    }
}

/// What `--location-address` produced: nothing to do, a match, or the failure that stops the
/// command before any write.
enum LocationResolution {
    case notRequested
    case resolved(ResolvedLocation)
    case failure(WriteOutcome)
}

/// The location-alarm options `add` and `edit` share: one validation, one address lookup.
enum LocationAlarmInput {

    /// Collapse `--location-address` and its hidden `--address` alias into one value.
    /// Upstream makes `--address` a second spelling of the same argparse destination; passing both
    /// spellings is a mistake worth reporting rather than silently keeping one.
    static func address(_ locationAddress: String?, alias: String?) throws -> String? {
        if locationAddress != nil && alias != nil {
            throw CLIError("pass either --location-address or --address, not both.", code: "location_address_conflict")
        }
        return locationAddress ?? alias
    }

    /// Validate pairing, coordinate ranges and radius before the first write. Returns the
    /// structured failure for the coded refusals, throws `WriteError` for the plain ones, and nil
    /// when the input is usable (`validate_private_args`, remctl:4820).
    static func validate(
        latitude: Double?, longitude: Double?, radius: Double, address: String?, json: Bool
    ) throws -> WriteOutcome? {
        if address != nil, latitude != nil || longitude != nil {
            return failLocation(code: "location_address_conflict",
                                message: "Pass --location-address or --latitude/--longitude, not both.",
                                json: json)
        }
        guard latitude != nil || longitude != nil || address != nil else { return nil }
        if address == nil, latitude == nil || longitude == nil {
            throw WriteError("Location alarms require latitude and longitude", code: "invalid_location")
        }
        if let latitude, !(latitude.isFinite && (-90.0...90.0).contains(latitude)) {
            throw WriteError("--latitude must be between -90 and 90.", code: "invalid_location")
        }
        if let longitude, !(longitude.isFinite && (-180.0...180.0).contains(longitude)) {
            throw WriteError("--longitude must be between -180 and 180.", code: "invalid_location")
        }
        if !(radius.isFinite && (1.0...LocationLimits.maxRadius).contains(radius)) {
            return failLocation(code: "invalid_location_radius",
                                message: "--radius must be between 1 and \(Int(LocationLimits.maxRadius)) meters.",
                                json: json)
        }
        return nil
    }

    /// Turn `--location-address` into coordinates. Any status but `resolved` — and every lookup
    /// error — stops the command, so nothing is created or changed
    /// (`resolve_location_address_or_die`, remctl:5030).
    static func resolve(
        address: String?, title: String?, radius: Double, proximity: Proximity,
        geocoder: AddressGeocoder, json: Bool
    ) async -> LocationResolution {
        guard let address else { return .notRequested }
        let result: LocationLookupResult
        do {
            result = try await lookupLocation(query: address, geocoder: geocoder)
        } catch let error as LocationLookupError {
            return .failure(failLocation(code: error.code, message: error.message, json: json))
        } catch {
            return .failure(failLocation(code: "location_lookup_failed",
                                         message: "Geocoding failed: \(error)", json: json))
        }
        guard result.status == .resolved, let match = result.location else {
            return .failure(failLocation(
                code: "location_\(result.status.rawValue)", message: locationLookupMessage(result), json: json,
                query: result.query, candidates: result.candidates, reason: result.reason))
        }
        let resolvedTitle = (title?.isEmpty == false) ? title! : (match.name ?? match.address ?? result.query)
        return .resolved(ResolvedLocation(
            query: result.query, title: resolvedTitle, address: match.address,
            latitude: match.latitude, longitude: match.longitude, precision: match.precision,
            radius: radius, proximity: proximity.rawValue))
    }
}

/// Stop before any write, with a structured error under `--json` and the candidates listed under
/// the human error line (`fail_location`, remctl:4857). Exit 1.
func failLocation(
    code: String, message: String, json: Bool,
    query: String? = nil, candidates: [GeocodedCandidate]? = nil, reason: AddressMismatch? = nil
) -> WriteOutcome {
    if json {
        var pairs: [(String, JSONValue)] = [
            ("status", .string("error")),
            ("code", .string(code)),
            ("message", .string(message)),
        ]
        if let query { pairs.append(("query", .string(query))) }
        if let candidates { pairs.append(("candidates", .array(candidates.map(\.json)))) }
        if let reason { pairs.append(("reason", .string(reason.rawValue))) }
        return WriteOutcome(stderr: JSONValue.object(pairs).serialized(indent: nil, ensureAscii: false) + "\n",
                            exitCode: 1)
    }
    var out = "Error: \(message)\n"
    for candidate in candidates ?? [] { out += "  " + candidateLine(candidate) + "\n" }
    return WriteOutcome(stderr: out, exitCode: 1)
}

/// One reviewable match as the human output lists it: `<label> (lat, lon; precision)`.
func candidateLine(_ candidate: GeocodedCandidate) -> String {
    let label = candidate.address ?? candidate.name ?? "?"
    return "\(safeDisplay(label)) (\(coordinate(candidate.latitude, places: 5)), "
        + "\(coordinate(candidate.longitude, places: 5)); \(candidate.precision.rawValue))"
}

func coordinate(_ value: Double, places: Int = 6) -> String {
    String(format: "%.\(places)f", value)
}
