import Testing
import Foundation
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// LocationLookupTests – the address-lookup judgement and the `location-lookup`
// command. Pure: every geocoder answer comes from FakeGeocoder, nothing is written.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct PersonalPlaceLabelTests {

    @Test("personal labels are refused whatever their punctuation or spacing")
    func labelsRefused() {
        #expect(isPersonalPlaceLabel("Home"))
        #expect(isPersonalPlaceLabel("my house!"))
        #expect(isPersonalPlaceLabel("  My   Office  "))
        #expect(isPersonalPlaceLabel("current location."))
        #expect(isPersonalPlaceLabel("GYM"))
    }

    @Test("real addresses and near-misses are not personal labels")
    func addressesAllowed() {
        #expect(!isPersonalPlaceLabel("Apple Park"))
        #expect(!isPersonalPlaceLabel("homes"))
        #expect(!isPersonalPlaceLabel("1 Home Street"))
        #expect(!isPersonalPlaceLabel(""))
    }
}

@Suite struct GeocodedCandidateTests {

    @Test("a thoroughfare with a small region is street-precise")
    func streetPrecision() {
        let candidate = geocodedCandidate(GeocodeFixtures.piazzaNavona)
        #expect(candidate.precision == .street)
        #expect(candidate.regionRadius == 70.7)
        #expect(candidate.name == "Piazza Navona")
        #expect(candidate.latitude == 41.8978252)
    }

    @Test("a region wider than 1000 m is an area whatever else the match carries")
    func areaPrecisionFromRadius() {
        #expect(geocodedCandidate(GeocodeFixtures.rome).precision == .area)
        let wideStreet = GeocodedPlace(thoroughfare: "Via Roma", latitude: 1, longitude: 2, regionRadius: 1000.1)
        #expect(geocodedCandidate(wideStreet).precision == .area)
    }

    @Test("exactly 1000 m still counts as precise")
    func boundaryRadiusIsPrecise() {
        let place = GeocodedPlace(thoroughfare: "Via Roma", latitude: 1, longitude: 2, regionRadius: 1000)
        #expect(geocodedCandidate(place).precision == .street)
    }

    @Test("a named point of interest or a region without a street is place-precise")
    func placePrecision() {
        let interest = GeocodedPlace(name: "Apple Park", areasOfInterest: ["Apple Park"], latitude: 1, longitude: 2)
        #expect(geocodedCandidate(interest).precision == .place)
        let region = GeocodedPlace(name: "Somewhere", latitude: 1, longitude: 2, regionRadius: 120)
        #expect(geocodedCandidate(region).precision == .place)
    }

    @Test("a match with no street, interest or region is an area")
    func bareMatchIsArea() {
        let bare = GeocodedPlace(name: "Lazio", latitude: 1, longitude: 2)
        let candidate = geocodedCandidate(bare)
        #expect(candidate.precision == .area)
        #expect(candidate.regionRadius == nil)
    }

    @Test("the region radius is reported to 0.1 m")
    func radiusRounded() {
        let place = GeocodedPlace(thoroughfare: "Via Roma", latitude: 1, longitude: 2, regionRadius: 70.7412)
        #expect(geocodedCandidate(place).regionRadius == 70.7)
        let wider = GeocodedPlace(thoroughfare: "Via Roma", latitude: 1, longitude: 2, regionRadius: 70.77)
        #expect(geocodedCandidate(wider).regionRadius == 70.8)
    }

    @Test("the JSON shape omits the fields the match does not carry")
    func candidateJSON() {
        let json = geocodedCandidate(GeocodeFixtures.rome).json.serialized(indent: nil, ensureAscii: false)
        #expect(json == #"{"name": "Rome", "address": "Rome, Lazio, Italy", "latitude": 41.8893, "longitude": 12.4935, "precision": "area", "regionRadius": 38253.2}"#)
        let bare = geocodedCandidate(GeocodedPlace(latitude: 1.5, longitude: -2.5))
        #expect(bare.json.serialized(indent: nil, ensureAscii: false)
            == #"{"latitude": 1.5, "longitude": -2.5, "precision": "area"}"#)
    }
}

@Suite struct AddressMismatchTests {

    @Test("a match naming another street is a street mismatch")
    func streetMismatch() {
        #expect(addressMismatchReason(query: "Main Street 1", place: GeocodeFixtures.rykneldCourt) == .streetMismatch)
    }

    @Test("a street with no town is unconfirmed")
    func noTown() {
        #expect(addressMismatchReason(query: "Via Roma 1", place: GeocodeFixtures.viaRoma) == .noTown)
    }

    @Test("a town confirms the street, even when it repeats the street's name")
    func townConfirms() {
        #expect(addressMismatchReason(query: "Via Roma 1, Roma", place: GeocodeFixtures.viaRoma) == nil)
    }

    @Test("a postal code confirms the town without naming it")
    func postalCodeConfirms() {
        #expect(addressMismatchReason(query: "Via Roma 1 00046", place: GeocodeFixtures.viaRoma) == nil)
        // The match's own postal code is folded and stripped of spaces before the comparison.
        let spaced = GeocodedPlace(name: "Via Roma 1", thoroughfare: "Via Roma", postalCode: "00 046",
                                   latitude: 1, longitude: 2, regionRadius: 70)
        #expect(addressMismatchReason(query: "Via Roma 1 00046", place: spaced) == nil)
        #expect(addressMismatchReason(query: "Via Roma 1 00047", place: spaced) == .noTown)
    }

    @Test("abbreviations match the spelled-out street type")
    func abbreviationsMatch() {
        let mainSt = GeocodedPlace(name: "1 Main St", thoroughfare: "Main St", latitude: 1, longitude: 2, regionRadius: 70)
        #expect(addressMismatchReason(query: "Main Street 1, Springfield", place: mainSt) == nil)
        #expect(addressMismatchReason(query: "Main St 1", place: mainSt) == .noTown)
    }

    @Test("accents and case do not break the comparison")
    func accentsFold() {
        let eglise = GeocodedPlace(name: "1 Rue de l'Eglise", thoroughfare: "Rue de l'Eglise",
                                   latitude: 1, longitude: 2, regionRadius: 70)
        #expect(addressMismatchReason(query: "1 RUE DE L'ÉGLISE, Paris", place: eglise) == nil)
        #expect(addressMismatchReason(query: "1 Rue de l'Église", place: eglise) == .noTown)
    }

    @Test("a point of interest the user typed confirms the match")
    func areasOfInterestConfirm() {
        let park = GeocodedPlace(name: "Apple Park Visitor Center", areasOfInterest: ["Apple Park"],
                                 latitude: 1, longitude: 2, regionRadius: 70)
        #expect(addressMismatchReason(query: "Apple Park, Cupertino", place: park) == nil)
        #expect(addressMismatchReason(query: "Apple Park", place: park) == .noTown)
        #expect(addressMismatchReason(query: "Googleplex", place: park) == .streetMismatch)
    }

    @Test("house numbers never count as the town")
    func houseNumbersIgnored() {
        #expect(addressMismatchReason(query: "Via Roma 1 2 3", place: GeocodeFixtures.viaRoma) == .noTown)
    }
}

@Suite struct LookupLocationTests {

    @Test("no match is not_found")
    func notFound() async throws {
        let geocoder = FakeGeocoder()
        let result = try await lookupLocation(query: "Nowhere at all", geocoder: geocoder)
        #expect(result.status == .notFound)
        #expect(result.candidates.isEmpty)
        #expect(result.location == nil)
        #expect(geocoder.queries == ["Nowhere at all"])
    }

    @Test("one precise match that names the street and a town resolves")
    func resolved() async throws {
        let result = try await lookupLocation(
            query: "Piazza Navona, Rome", geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(result.status == .resolved)
        #expect(result.location?.latitude == 41.8978252)
        #expect(result.location?.precision == .street)
        #expect(result.reason == nil)
    }

    @Test("several matches are ambiguous")
    func ambiguous() async throws {
        var other = GeocodeFixtures.piazzaNavona
        other.latitude = 45.0
        let result = try await lookupLocation(
            query: "Piazza Navona", geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona, other]))
        #expect(result.status == .ambiguous)
        #expect(result.candidates.count == 2)
        #expect(result.location == nil)
    }

    @Test("at most five candidates are reported, and the message counts those")
    func candidatesCapped() async throws {
        let places = (0..<7).map { index -> GeocodedPlace in
            var place = GeocodeFixtures.piazzaNavona
            place.latitude = 41.0 + Double(index)
            return place
        }
        let result = try await lookupLocation(query: "Piazza Navona", geocoder: FakeGeocoder(places: places))
        #expect(result.status == .ambiguous)
        #expect(result.candidates.count == 5)
        #expect(locationLookupMessage(result).contains("matches 5 places"))
    }

    @Test("one city-sized match is imprecise")
    func imprecise() async throws {
        let result = try await lookupLocation(query: "Rome", geocoder: FakeGeocoder(places: [GeocodeFixtures.rome]))
        #expect(result.status == .imprecise)
        #expect(result.candidates.first?.precision == .area)
        #expect(locationLookupMessage(result).contains("only matches a whole area (Rome, Lazio, Italy)"))
    }

    @Test("a best guess for another street is unconfirmed")
    func unconfirmed() async throws {
        let result = try await lookupLocation(
            query: "Main Street 1", geocoder: FakeGeocoder(places: [GeocodeFixtures.rykneldCourt]))
        #expect(result.status == .unconfirmed)
        #expect(result.reason == .streetMismatch)
        #expect(locationLookupMessage(result).hasPrefix("'Main Street 1' came back as 1 Rykneld Court,"))
    }

    @Test("a street with no town is unconfirmed with the no_town reason")
    func unconfirmedNoTown() async throws {
        let result = try await lookupLocation(
            query: "Via Roma 1", geocoder: FakeGeocoder(places: [GeocodeFixtures.viaRoma]))
        #expect(result.status == .unconfirmed)
        #expect(result.reason == .noTown)
        #expect(locationLookupMessage(result).contains("names a street but no town"))
    }

    @Test("an empty query never reaches the geocoder")
    func emptyQuery() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        await #expect(throws: LocationLookupError(code: "location_address_required",
                                                  message: "Pass an address to look up.")) {
            try await lookupLocation(query: "   ", geocoder: geocoder)
        }
        #expect(geocoder.queries.isEmpty)
    }

    @Test("an address longer than 512 characters never reaches the geocoder")
    func addressTooLong() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        await #expect(throws: LocationLookupError(code: "location_address_too_long",
                                                  message: "Addresses are limited to 512 characters.")) {
            try await lookupLocation(query: String(repeating: "a", count: 513), geocoder: geocoder)
        }
        #expect(geocoder.queries.isEmpty)
        // 512 is accepted.
        let ok = try? await lookupLocation(query: String(repeating: "a", count: 512), geocoder: geocoder)
        #expect(ok?.status == .unconfirmed)
    }

    @Test("a personal label never reaches the geocoder")
    func personalLabel() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        do {
            _ = try await lookupLocation(query: "Home", geocoder: geocoder)
            Issue.record("expected a location_label_not_address error")
        } catch let error as LocationLookupError {
            #expect(error.code == "location_label_not_address")
            #expect(error.message.hasPrefix("'Home' names a place only you know"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(geocoder.queries.isEmpty)
    }

    @Test("geocoder failures surface with their own codes")
    func geocoderFailures() async {
        for error in [
            LocationLookupError(code: "location_lookup_timeout", message: "Geocoding did not finish within 10 seconds."),
            LocationLookupError(code: "location_lookup_denied", message: "Geocoding was denied: nope"),
            LocationLookupError(code: "location_lookup_failed", message: "Apple's geocoder could not be reached: offline"),
        ] {
            await #expect(throws: error) {
                try await lookupLocation(query: "Piazza Navona, Rome", geocoder: FakeGeocoder(error: error))
            }
        }
    }

    @Test("the query is trimmed and the timeout is passed to the geocoder")
    func trimsAndForwardsTimeout() async throws {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let result = try await lookupLocation(query: "  Piazza Navona, Rome \n", timeout: 3, geocoder: geocoder)
        #expect(result.query == "Piazza Navona, Rome")
        #expect(geocoder.queries == ["Piazza Navona, Rome"])
        #expect(geocoder.timeouts == [3])
    }
}

@Suite struct LocationLookupCommandTests {

    @Test("resolved --json reports the match, the location and usable")
    func resolvedJSON() async {
        let out = await LocationLookupCmd.perform(
            query: "Piazza Navona, Rome", json: true,
            geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(out.exitCode == 0)
        #expect(out.stdout == """
            {
              "query": "Piazza Navona, Rome",
              "candidates": [
                {
                  "name": "Piazza Navona",
                  "address": "Piazza Navona, Rome, Lazio, 00186, Italy",
                  "latitude": 41.8978252,
                  "longitude": 12.4732402,
                  "precision": "street",
                  "regionRadius": 70.7
                }
              ],
              "status": "resolved",
              "location": {
                "name": "Piazza Navona",
                "address": "Piazza Navona, Rome, Lazio, 00186, Italy",
                "latitude": 41.8978252,
                "longitude": 12.4732402,
                "precision": "street",
                "regionRadius": 70.7
              },
              "usable": true
            }

            """)
    }

    @Test("an unusable status is reported with usable false and exit 0")
    func impreciseJSON() async {
        let out = await LocationLookupCmd.perform(
            query: "Rome", json: true, geocoder: FakeGeocoder(places: [GeocodeFixtures.rome]))
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains(#""status": "imprecise""#))
        #expect(out.stdout.contains(#""usable": false"#))
        #expect(out.stdout.contains(#""precision": "area""#))
        #expect(!out.stdout.contains(#""location""#))
    }

    @Test("an unconfirmed status carries its reason before usable")
    func unconfirmedJSON() async {
        let out = await LocationLookupCmd.perform(
            query: "Via Roma 1", json: true, geocoder: FakeGeocoder(places: [GeocodeFixtures.viaRoma]))
        #expect(out.exitCode == 0)
        #expect(out.stdout.contains("\"status\": \"unconfirmed\",\n  \"reason\": \"no_town\",\n  \"usable\": false"))
    }

    @Test("human output prints the resolved address and six-decimal coordinates")
    func resolvedHuman() async {
        let out = await LocationLookupCmd.perform(
            query: "Piazza Navona, Rome", json: false,
            geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(out.exitCode == 0)
        #expect(out.stdout == """
            Resolved: Piazza Navona, Rome, Lazio, 00186, Italy
            Coordinates: 41.897825, 12.473240 (street)

            """)
    }

    @Test("human output lists the candidates under an unusable status, with five decimals")
    func unusableHuman() async {
        let out = await LocationLookupCmd.perform(
            query: "Rome", json: false, geocoder: FakeGeocoder(places: [GeocodeFixtures.rome]))
        #expect(out.exitCode == 0)
        #expect(out.stderr.isEmpty)
        #expect(out.stdout == """
            'Rome' only matches a whole area (Rome, Lazio, Italy), not a spot a location alarm can use. \
            Pass a street address, or pass its coordinates if the area is really what you want.
              Rome, Lazio, Italy (41.88930, 12.49350; area)

            """)
    }

    @Test("not_found says so and lists nothing")
    func notFoundHuman() async {
        let out = await LocationLookupCmd.perform(query: "Nowhere", json: false, geocoder: FakeGeocoder())
        #expect(out.exitCode == 0)
        #expect(out.stdout == "No place matches 'Nowhere'. Check the address, or pass --latitude and --longitude.\n")
    }

    @Test("a personal label is a structured error on stderr")
    func personalLabelError() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = await LocationLookupCmd.perform(query: "Home", json: true, geocoder: geocoder)
        #expect(out.exitCode == 1)
        #expect(out.stdout.isEmpty)
        #expect(out.stderr.hasPrefix(#"{"status": "error", "code": "location_label_not_address", "message": "'Home' names a place only you know"#))
        #expect(geocoder.queries.isEmpty)
    }

    @Test("a geocoder failure is a structured error")
    func lookupFailure() async {
        let out = await LocationLookupCmd.perform(
            query: "Piazza Navona", json: true,
            geocoder: FakeGeocoder(error: LocationLookupError(code: "location_lookup_timeout", message: "slow")))
        #expect(out.exitCode == 1)
        #expect(out.stderr == #"{"status": "error", "code": "location_lookup_timeout", "message": "slow"}"# + "\n")
    }

    @Test("the timeout must be 1-30 seconds and is refused before the lookup")
    func timeoutRange() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        for seconds in [0, 31, -1] {
            let out = await LocationLookupCmd.perform(
                query: "Piazza Navona, Rome", timeout: seconds, json: false, geocoder: geocoder)
            #expect(out.exitCode == 1)
            #expect(out.stderr == "Error: --timeout must be between 1 and 30 seconds.\n")
        }
        #expect(geocoder.queries.isEmpty)
        let json = await LocationLookupCmd.perform(
            query: "Piazza Navona, Rome", timeout: 99, json: true, geocoder: geocoder)
        #expect(json.stderr == #"{"status": "error", "code": "invalid_timeout", "message": "--timeout must be between 1 and 30 seconds."}"# + "\n")
    }

    @Test("the timeout reaches the geocoder, defaulting to ten seconds")
    func timeoutForwarded() async {
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        _ = await LocationLookupCmd.perform(query: "Piazza Navona, Rome", json: false, geocoder: geocoder)
        _ = await LocationLookupCmd.perform(query: "Piazza Navona, Rome", timeout: 30, json: false, geocoder: geocoder)
        #expect(geocoder.timeouts == [10, 30])
    }
}

@Suite struct LocationCompletionTests {

    @Test("every shell completes location-lookup and its options")
    func locationLookupCompleted() {
        #expect(CompletionScripts.zsh.contains("'location-lookup:Resolve an address to coordinates for a location alarm'"))
        #expect(CompletionScripts.zsh.contains("        location-lookup)\n"))
        #expect(CompletionScripts.bash.contains(" list-info location-lookup stats "))
        #expect(CompletionScripts.bash.contains(#"elif [ "$cmd" = "location-lookup" ]"#))
        #expect(CompletionScripts.fish.contains(#"-a location-lookup -d "Resolve an address to coordinates for a location alarm""#))
        #expect(CompletionScripts.fish.contains(#"__fish_seen_subcommand_from location-lookup" -l timeout"#))
    }

    @Test("every shell completes the location options on add and edit")
    func locationOptionsCompleted() {
        // zsh lists each command's options in its own case block.
        for block in ["        add)", "        edit)"] {
            guard let start = CompletionScripts.zsh.range(of: block),
                  let end = CompletionScripts.zsh.range(of: ";;", range: start.upperBound..<CompletionScripts.zsh.endIndex)
            else {
                Issue.record("no zsh block for \(block)")
                continue
            }
            let section = String(CompletionScripts.zsh[start.upperBound..<end.lowerBound])
            for option in ["--location-title", "--latitude", "--longitude", "--radius", "--proximity", "--location-address"] {
                #expect(section.contains(option), "zsh \(block) is missing \(option)")
            }
        }
        for line in ["--location-title --latitude --longitude --radius --proximity --location-address --url",
                     "--location-title --latitude --longitude --radius --proximity --location-address --title"] {
            #expect(CompletionScripts.bash.contains(line))
        }
        for command in ["add", "edit"] {
            #expect(CompletionScripts.fish.contains(
                #"-n "__fish_seen_subcommand_from \#(command)" -l location-address"#))
        }
    }
}
