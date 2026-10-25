import Foundation

/// Limits shared by the location-alarm options, the address lookup and `location-lookup`.
/// Mirrors `LOCATION_MAX_RADIUS` / `GEOCODE_TIMEOUT_SECONDS` / `GEOCODE_MAX_PRECISE_RADIUS`
/// (remctl:4844).
enum LocationLimits {
    /// Largest region radius EventKit stores, in meters.
    static let maxRadius = 100_000.0
    /// Deadline for one address lookup, in seconds.
    static let geocodeTimeout: TimeInterval = 10
    /// A match whose region is wider than this covers a whole area, not a spot an alarm can use.
    static let maxPreciseRadius = 1_000.0
    /// Longest address the geocoder is asked about.
    static let maxAddressLength = 512
}

/// Words that name a place only the user knows. Geocoding them would pick some unrelated spot
/// that happens to share the name (`PERSONAL_PLACE_LABELS`, remctl:4848).
let personalPlaceLabels: Set<String> = [
    "home", "my home", "house", "my house", "my place", "work", "my work", "office", "my office",
    "school", "my school", "gym", "my gym", "here", "current location", "my location",
]

/// Street-type words that the geocoder and the user spell differently (`STREET_ABBREVIATIONS`,
/// remctl:4900).
let streetAbbreviations: [String: String] = [
    "st": "street", "str": "street", "ave": "avenue", "av": "avenue", "rd": "road",
    "blvd": "boulevard", "dr": "drive", "ln": "lane", "ct": "court", "pl": "place",
    "sq": "square", "hwy": "highway", "pkwy": "parkway",
]

/// One geocoder match, reduced to the fields RemCTL judges and reports. Mirrors the fields the
/// upstream bridge put in `placemarkPayload` (remctl-bridge.swift:636) that the judging logic reads.
struct GeocodedPlace: Equatable, Sendable {
    var name: String?
    /// `"<number> <street>, <locality>, <administrativeArea>, <postalCode>, <country>"`, skipping
    /// the parts the placemark does not carry.
    var address: String?
    var thoroughfare: String?
    var areasOfInterest: [String]
    var postalCode: String?
    var latitude: Double
    var longitude: Double
    /// Radius of the placemark's circular region in meters; nil when it has none.
    var regionRadius: Double?

    init(name: String? = nil, address: String? = nil, thoroughfare: String? = nil,
         areasOfInterest: [String] = [], postalCode: String? = nil,
         latitude: Double, longitude: Double, regionRadius: Double? = nil) {
        self.name = name
        self.address = address
        self.thoroughfare = thoroughfare
        self.areasOfInterest = areasOfInterest
        self.postalCode = postalCode
        self.latitude = latitude
        self.longitude = longitude
        self.regionRadius = regionRadius
    }
}

/// How tightly a match pins down a spot: a street address, a named place, or a whole area.
enum LocationPrecision: String, Sendable {
    case street, place, area
}

/// A geocoder match reduced to what the user reviews, with its precision.
struct GeocodedCandidate: Equatable, Sendable {
    var name: String?
    var address: String?
    var latitude: Double
    var longitude: Double
    var precision: LocationPrecision
    /// Region radius rounded to 0.1 m; nil when the match has no region.
    var regionRadius: Double?

    /// What a human reads in an error line: the full address, else the place name.
    var label: String { address ?? name ?? "" }

    var json: JSONValue {
        var pairs: [(String, JSONValue)] = []
        if let name { pairs.append(("name", .string(name))) }
        if let address { pairs.append(("address", .string(address))) }
        pairs.append(("latitude", .double(latitude)))
        pairs.append(("longitude", .double(longitude)))
        pairs.append(("precision", .string(precision.rawValue)))
        if let regionRadius { pairs.append(("regionRadius", .double(regionRadius))) }
        return .object(pairs)
    }
}

/// Why one precise match may still not be the place the user meant.
enum AddressMismatch: String, Sendable {
    case streetMismatch = "street_mismatch"
    case noTown = "no_town"
}

/// The verdict on a lookup: `resolved` is the only status an alarm may use.
enum LocationLookupStatus: String, Sendable {
    case resolved, ambiguous, imprecise, unconfirmed
    case notFound = "not_found"
}

/// A judged lookup. Mirrors the dict `lookup_location` returns (remctl:4937).
struct LocationLookupResult: Equatable, Sendable {
    var query: String
    /// At most five matches, in geocoder order.
    var candidates: [GeocodedCandidate]
    var status: LocationLookupStatus
    var reason: AddressMismatch?
    /// The single usable match; only set when `status == .resolved`.
    var location: GeocodedCandidate?
}

/// A lookup that never produced candidates to judge: bad input, or a geocoder that failed.
/// `code` is the `--json` error code; nothing is ever written in this case.
struct LocationLookupError: Error, Equatable, Sendable {
    let code: String
    let message: String
}

/// The words of an address, folded, with street-type abbreviations expanded so "Main St" and
/// "Main Street" compare equal (`_address_tokens`, remctl:4905).
func addressTokens(_ text: String) -> [String] {
    searchFold(text)
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map { streetAbbreviations[String($0)] ?? String($0) }
}

/// Whether the value names a place only the user knows ("Home", "my office!").
/// Punctuation is dropped and whitespace collapsed before the comparison
/// (`is_personal_place_label`, remctl:4870).
func isPersonalPlaceLabel(_ value: String) -> Bool {
    let stripped = value.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0.isWhitespace }
    let collapsed = stripped.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return personalPlaceLabels.contains(collapsed)
}

// MARK: - Judging one match

/// Reduce a geocoder match to what the user reviews, and say how precise it is.
///
/// Street addresses come back with a region of about 70 m. A city or region comes back as one
/// best guess with a region several kilometers wide, so the region size, not the number of
/// matches, is what exposes a vague query (`geocoded_candidate`, remctl:4875).
func geocodedCandidate(_ place: GeocodedPlace) -> GeocodedCandidate {
    let radius = (place.regionRadius?.isFinite == true) ? place.regionRadius : nil
    let precision: LocationPrecision
    if let radius, radius > LocationLimits.maxPreciseRadius {
        precision = .area
    } else if place.thoroughfare?.isEmpty == false {
        precision = .street
    } else if !place.areasOfInterest.isEmpty || radius != nil {
        precision = .place
    } else {
        precision = .area
    }
    return GeocodedCandidate(
        name: place.name, address: place.address,
        latitude: place.latitude, longitude: place.longitude,
        precision: precision,
        regionRadius: radius.map { ($0 * 10).rounded() / 10 })
}

/// Why one precise match may still not be the place the user meant.
///
/// Apple's geocoder returns its single best guess even for a street it did not find
/// ("Main Street 1" came back as Rykneld Court in England) or for a street name found in
/// thousands of towns ("Via Roma 1"). Returns `.streetMismatch` when the match names no street or
/// place the user typed, `.noTown` when the query gives nothing beyond the street and house
/// number, or nil (`address_mismatch_reason`, remctl:4909).
func addressMismatchReason(query: String, place: GeocodedPlace) -> AddressMismatch? {
    let available = tokenCounts(addressTokens(query))
    var named: [String: Int]?
    for field in [place.thoroughfare] + place.areasOfInterest.map(Optional.init) + [place.name] {
        let tokens = tokenCounts(addressTokens(field ?? "").filter { !startsWithDigit($0) })
        if !tokens.isEmpty, isContained(tokens, in: available) {
            named = tokens
            break
        }
    }
    guard let named else { return .streetMismatch }
    let postal = withoutWhitespace(searchFold(place.postalCode ?? ""))
    if !postal.isEmpty, withoutWhitespace(searchFold(query)).contains(postal) { return nil }
    // A query that adds nothing beyond the street and its house number names no town.
    let hasLeftover = available.contains { token, count in
        count > named[token, default: 0] && !startsWithDigit(token)
    }
    return hasLeftover ? nil : .noTown
}

private func tokenCounts(_ tokens: [String]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for token in tokens { counts[token, default: 0] += 1 }
    return counts
}

/// Multiset containment: every token occurs in `other` at least as often.
private func isContained(_ tokens: [String: Int], in other: [String: Int]) -> Bool {
    tokens.allSatisfy { other[$0.key, default: 0] >= $0.value }
}

private func startsWithDigit(_ token: String) -> Bool {
    token.first?.isNumber == true
}

private func withoutWhitespace(_ text: String) -> String {
    String(text.filter { !$0.isWhitespace })
}

// MARK: - The lookup

/// Geocode an address and judge the result. Nothing is written in any case.
///
/// The status is `resolved` (one precise match that names the street or place typed, in a town or
/// postal code the query gives), `ambiguous` (several matches), `imprecise` (one match that covers
/// a whole area), `unconfirmed` (one match RemCTL cannot tie to the query; `reason` says why), or
/// `notFound`. Bad input and geocoder failures throw a `LocationLookupError`
/// (`lookup_location`, remctl:4937).
func lookupLocation(
    query rawQuery: String,
    timeout: TimeInterval = LocationLimits.geocodeTimeout,
    geocoder: AddressGeocoder
) async throws -> LocationLookupResult {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
        throw LocationLookupError(code: "location_address_required", message: "Pass an address to look up.")
    }
    if query.count > LocationLimits.maxAddressLength {
        throw LocationLookupError(code: "location_address_too_long", message: "Addresses are limited to 512 characters.")
    }
    if isPersonalPlaceLabel(query) {
        throw LocationLookupError(
            code: "location_label_not_address",
            message: "\(WriteFormatting.pyRepr(query)) names a place only you know, so RemCTL will not guess "
                + "its address. Pass the street address or coordinates, and use --location-title to label it.")
    }
    let places = try await geocoder.geocode(address: query, timeout: timeout)
    let candidates = places.map(geocodedCandidate)
    var result = LocationLookupResult(
        query: query, candidates: Array(candidates.prefix(5)), status: .notFound, reason: nil, location: nil)
    if candidates.isEmpty {
        result.status = .notFound
    } else if candidates.count > 1 {
        result.status = .ambiguous
    } else if candidates[0].precision == .area {
        result.status = .imprecise
    } else if let reason = addressMismatchReason(query: query, place: places[0]) {
        result.status = .unconfirmed
        result.reason = reason
    } else {
        result.status = .resolved
        result.location = candidates[0]
    }
    return result
}

/// The sentence that explains an unusable lookup (`LOCATION_LOOKUP_MESSAGES` /
/// `location_lookup_message`, remctl:4999).
func locationLookupMessage(_ result: LocationLookupResult) -> String {
    let query = WriteFormatting.pyRepr(result.query)
    let label = result.candidates.first?.label ?? ""
    switch result.reason {
    case .streetMismatch:
        return "\(query) came back as \(label), which is not the street or place you typed. "
            + "Check the address, or pass --latitude and --longitude."
    case .noTown:
        return "\(query) names a street but no town, and many towns have one; Apple's geocoder picked \(label). "
            + "Add the town or postal code, or pass --latitude and --longitude."
    case nil:
        break
    }
    switch result.status {
    case .notFound:
        return "No place matches \(query). Check the address, or pass --latitude and --longitude."
    case .ambiguous:
        return "\(query) matches \(result.candidates.count) places. "
            + "Pass a fuller address, or the coordinates of the right one."
    case .imprecise:
        return "\(query) only matches a whole area (\(label)), not a spot a location alarm can use. "
            + "Pass a street address, or pass its coordinates if the area is really what you want."
    case .resolved, .unconfirmed:
        return ""
    }
}
