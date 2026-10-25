import ArgumentParser
import Foundation

let locationCommands: [ParsableCommand.Type] = [LocationLookupCmd.self]

struct LocationLookupCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "location-lookup",
        abstract: "Resolve an address to coordinates for a location alarm.",
        discussion: """
            Look up an address with Apple's geocoder and report the match. Read-only: nothing is \
            written, and no Reminders access is needed. add and edit use the same lookup for \
            --location-address.

            status is resolved (safe to use), ambiguous (several matches), imprecise (one match \
            covering a whole city or region), unconfirmed (a different street, or no town or \
            postal code; see reason), or not_found. Personal labels such as Home or Work are \
            refused: pass the real address and use --location-title for the label.
            """)

    @Argument(help: "Street address or place to look up") var query: String
    @Option(name: .long, help: "Seconds to wait for the geocoder, 1-30; 10 when omitted") var timeout: Int?
    @Flag(name: .long, help: "Emit machine-readable JSON instead of human output.") var json = false

    func run() async throws {
        WriteDispatch.emit(await Self.perform(
            query: query, timeout: timeout, json: json, geocoder: CoreLocationGeocoder()))
    }

    /// Testable core (no print/exit). Read-only: it opens neither the Reminders store nor EventKit
    /// (`cmd_location_lookup`, remctl:5064). An unusable status is a result, not an error: it
    /// prints on stdout and exits 0, so a caller can inspect the candidates.
    static func perform(
        query: String, timeout: Int? = nil, json: Bool, geocoder: AddressGeocoder
    ) async -> WriteOutcome {
        let seconds = timeout ?? Int(LocationLimits.geocodeTimeout)
        guard (1...30).contains(seconds) else {
            return failLocation(code: "invalid_timeout",
                                message: "--timeout must be between 1 and 30 seconds.", json: json)
        }
        let result: LocationLookupResult
        do {
            result = try await lookupLocation(query: query, timeout: TimeInterval(seconds), geocoder: geocoder)
        } catch let error as LocationLookupError {
            return failLocation(code: error.code, message: error.message, json: json)
        } catch {
            return failLocation(code: "location_lookup_failed", message: "Geocoding failed: \(error)", json: json)
        }
        if json { return .ok(lookupJSON(result).serialized(indent: 2, ensureAscii: false) + "\n") }
        if let match = result.location {
            return .ok("Resolved: \(safeDisplay(match.label))\n"
                + "Coordinates: \(coordinate(match.latitude)), \(coordinate(match.longitude)) "
                + "(\(match.precision.rawValue))\n")
        }
        var out = locationLookupMessage(result) + "\n"
        for candidate in result.candidates { out += "  " + candidateLine(candidate) + "\n" }
        return .ok(out)
    }

    /// `{query, candidates, status, reason?, location?, usable}` — upstream's key order.
    private static func lookupJSON(_ result: LocationLookupResult) -> JSONValue {
        var pairs: [(String, JSONValue)] = [
            ("query", .string(result.query)),
            ("candidates", .array(result.candidates.map(\.json))),
            ("status", .string(result.status.rawValue)),
        ]
        if let reason = result.reason { pairs.append(("reason", .string(reason.rawValue))) }
        if let location = result.location { pairs.append(("location", location.json)) }
        pairs.append(("usable", .bool(result.status == .resolved)))
        return .object(pairs)
    }
}
