import Testing
import Foundation
import GRDB
@testable import RemindersControl

// ──────────────────────────────────────────────────────────────────────────────
// LocationAlarmTests – `add`/`edit` location alarms: coordinates, --location-address
// geocoding, and the refusals that must stop before the first write.
// ──────────────────────────────────────────────────────────────────────────────

@Suite struct LocationAlarmTests {
    /// Build a fixture store. `build` seeds rows on a fresh Reminders schema.
    private func store(_ build: (Database) throws -> Void) throws -> (RemindersStore, URL) {
        let dir = try FixtureDB.tempStore { db in try FixtureDB.createRemindersSchema(db); try build(db) }
        return (try RemindersStore.open(storeDir: dir), dir)
    }

    private func emptyStore() throws -> (RemindersStore, URL) { try store { _ in } }

    /// A store with a 'Work' list (id 10) and reminder pk 42 (ckid 'ABC', title 'T', in Work).
    private func withReminder() throws -> (RemindersStore, URL) {
        try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',10,1,0,0,'ABC')")
        }
    }

    private func createdWrite(_ m: MockWriter, sourceLocation: SourceLocation = #_sourceLocation) -> ReminderWrite? {
        guard m.calls.count == 1, case let .create(w) = m.calls[0] else {
            Issue.record("expected exactly one .create call, got \(m.calls)", sourceLocation: sourceLocation)
            return nil
        }
        return w
    }

    private func updatedWrite(_ m: MockWriter, sourceLocation: SourceLocation = #_sourceLocation) -> ReminderWrite? {
        guard m.calls.count == 1, case let .update(_, w) = m.calls[0] else {
            Issue.record("expected exactly one .update call, got \(m.calls)", sourceLocation: sourceLocation)
            return nil
        }
        return w
    }

    // MARK: - add with coordinates

    @Test("add writes a location alarm through EventKit, with no private write")
    func addCoordinates() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Add.perform(
            title: "Buy stamps", locationTitle: "Apple Park", latitude: 37.3349, longitude: -122.0090,
            radius: 200, proximity: .leaving, json: false, store: s, writer: m, private: mp)
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.location == LocationAlarmWrite(
            title: "Apple Park", latitude: 37.3349, longitude: -122.0090, radius: 200, proximity: "leaving"))
        #expect(mp.calls.isEmpty)
    }

    @Test("add defaults the radius to 100 m and the proximity to arriving")
    func addDefaults() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(title: "T", latitude: 0, longitude: 0, json: false,
                                  store: s, writer: m, private: MockPrivateWriter())
        #expect(createdWrite(m)?.location == LocationAlarmWrite(
            title: nil, latitude: 0, longitude: 0, radius: 100, proximity: "arriving"))
    }

    @Test("add refuses a latitude without a longitude")
    func addLatitudeWithoutLongitude() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = await WriteDispatch.perform {
            try await Add.perform(title: "T", latitude: 37.3, json: false, store: s, writer: m, private: MockPrivateWriter())
        }
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Location alarms require latitude and longitude\n")
        #expect(m.calls.isEmpty)
    }

    @Test("add range-checks coordinates and radius exactly like edit")
    func addRangeChecks() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let cases: [(Double, Double, Double, String)] = [
            (91, 0, 100, "Error: --latitude must be between -90 and 90.\n"),
            (.nan, 0, 100, "Error: --latitude must be between -90 and 90.\n"),
            (0, -180.5, 100, "Error: --longitude must be between -180 and 180.\n"),
            (0, 0, 0.5, "Error: --radius must be between 1 and 100000 meters.\n"),
            (0, 0, 100_001, "Error: --radius must be between 1 and 100000 meters.\n"),
            (0, 0, .nan, "Error: --radius must be between 1 and 100000 meters.\n"),
        ]
        for (latitude, longitude, radius, expected) in cases {
            let m = MockWriter()
            let out = await WriteDispatch.perform {
                try await Add.perform(title: "T", latitude: latitude, longitude: longitude, radius: radius,
                                      json: false, store: s, writer: m, private: MockPrivateWriter())
            }
            #expect(out.exitCode == 1)
            #expect(out.stderr == expected)
            #expect(m.calls.isEmpty)
        }
    }

    @Test("add accepts the extreme coordinates and the largest radius")
    func addRangeLimits() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", latitude: -90, longitude: 180, radius: 100_000,
                                        json: false, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 0)
        #expect(createdWrite(m)?.location?.radius == 100_000)
    }

    @Test("add reports an out-of-range radius as invalid_location_radius under --json")
    func addRadiusJSON() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(title: "T", latitude: 0, longitude: 0, radius: 100_001,
                                        json: true, store: s, writer: m, private: MockPrivateWriter())
        #expect(out.exitCode == 1)
        #expect(out.stderr == #"{"status": "error", "code": "invalid_location_radius", "message": "--radius must be between 1 and 100000 meters."}"# + "\n")
        #expect(m.calls.isEmpty)
    }

    // MARK: - add --location-address

    @Test("add geocodes the address and creates the reminder with the match")
    func addAddressResolved() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Add.perform(
            title: "Buy stamps", radius: 150, locationAddress: "Piazza Navona, Rome",
            json: false, store: s, writer: m, private: mp, geocoder: geocoder)
        #expect(out.exitCode == 0)
        #expect(geocoder.queries == ["Piazza Navona, Rome"])
        #expect(createdWrite(m)?.location == LocationAlarmWrite(
            title: "Piazza Navona", latitude: 41.8978252, longitude: 12.4732402,
            radius: 150, proximity: "arriving"))
        #expect(mp.calls.isEmpty)
        #expect(out.stdout == """
            Created: Buy stamps
            Location: Piazza Navona, Rome, Lazio, 00186, Italy (41.897825, 12.473240)

            """)
    }

    @Test("add --json reports the resolved location after the existing keys")
    func addAddressJSON() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); m.resultID = "EK-NEW"
        let out = try await Add.perform(
            title: "Buy stamps", locationAddress: "Piazza Navona, Rome", json: true,
            store: s, writer: m, private: MockPrivateWriter(),
            geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "created", "id": "EK-NEW", "title": "Buy stamps", "resolvedLocation": {"query": "Piazza Navona, Rome", "title": "Piazza Navona", "address": "Piazza Navona, Rome, Lazio, 00186, Italy", "latitude": 41.8978252, "longitude": 12.4732402, "precision": "street", "radius": 100.0, "proximity": "arriving", "source": "geocoded"}}"# + "\n")
    }

    @Test("an explicit --location-title survives the lookup")
    func addAddressKeepsTitle() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        _ = try await Add.perform(
            title: "T", locationTitle: "Office", locationAddress: "Piazza Navona, Rome",
            json: false, store: s, writer: m, private: MockPrivateWriter(),
            geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(createdWrite(m)?.location?.title == "Office")
    }

    @Test("a match without a name falls back to its address, then to the query")
    func addAddressTitleFallback() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        var nameless = GeocodeFixtures.piazzaNavona
        nameless.name = nil
        let m = MockWriter()
        _ = try await Add.perform(title: "T", locationAddress: "Piazza Navona, Rome", json: false,
                                  store: s, writer: m, private: MockPrivateWriter(),
                                  geocoder: FakeGeocoder(places: [nameless]))
        #expect(createdWrite(m)?.location?.title == "Piazza Navona, Rome, Lazio, 00186, Italy")

        var bare = nameless
        bare.address = nil
        let m2 = MockWriter()
        _ = try await Add.perform(title: "T", locationAddress: "Piazza Navona, Rome", json: false,
                                  store: s, writer: m2, private: MockPrivateWriter(),
                                  geocoder: FakeGeocoder(places: [bare]))
        #expect(createdWrite(m2)?.location?.title == "Piazza Navona, Rome")
    }

    @Test("an unusable lookup creates nothing and reports the status with its candidates")
    func addAddressUnusable() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        var second = GeocodeFixtures.piazzaNavona
        second.latitude = 45.0
        let cases: [(String, FakeGeocoder)] = [
            ("location_ambiguous", FakeGeocoder(places: [GeocodeFixtures.piazzaNavona, second])),
            ("location_imprecise", FakeGeocoder(places: [GeocodeFixtures.rome])),
            ("location_not_found", FakeGeocoder(places: [])),
            ("location_unconfirmed", FakeGeocoder(places: [GeocodeFixtures.rykneldCourt])),
            ("location_lookup_timeout", FakeGeocoder(error: LocationLookupError(code: "location_lookup_timeout", message: "slow"))),
            ("location_lookup_denied", FakeGeocoder(error: LocationLookupError(code: "location_lookup_denied", message: "no"))),
            ("location_lookup_failed", FakeGeocoder(error: LocationLookupError(code: "location_lookup_failed", message: "offline"))),
        ]
        for (code, geocoder) in cases {
            let m = MockWriter(); let mp = MockPrivateWriter()
            let out = try await Add.perform(title: "T", locationAddress: "Somewhere", json: true,
                                            store: s, writer: m, private: mp, geocoder: geocoder)
            #expect(out.exitCode == 1, "\(code)")
            #expect(out.stdout.isEmpty, "\(code)")
            #expect(out.stderr.contains(#""code": "\#(code)""#), "\(code): \(out.stderr)")
            #expect(m.calls.isEmpty, "\(code)")
            #expect(mp.calls.isEmpty, "\(code)")
        }
    }

    @Test("an unconfirmed lookup carries the query, candidates and reason")
    func addAddressUnconfirmedContext() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(
            title: "T", locationAddress: "Main Street 1", json: true, store: s, writer: m,
            private: MockPrivateWriter(), geocoder: FakeGeocoder(places: [GeocodeFixtures.rykneldCourt]))
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains(#""query": "Main Street 1""#))
        #expect(out.stderr.contains(#""candidates": [{"name": "1 Rykneld Court, Main Street""#))
        #expect(out.stderr.hasSuffix(#""reason": "street_mismatch"}"# + "\n"))
        #expect(m.calls.isEmpty)
    }

    @Test("human mode prints the candidates under the error line")
    func addAddressHumanCandidates() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Add.perform(
            title: "T", locationAddress: "Rome", json: false, store: s, writer: m,
            private: MockPrivateWriter(), geocoder: FakeGeocoder(places: [GeocodeFixtures.rome]))
        #expect(out.exitCode == 1)
        #expect(out.stderr == """
            Error: 'Rome' only matches a whole area (Rome, Lazio, Italy), not a spot a location alarm can use. \
            Pass a street address, or pass its coordinates if the area is really what you want.
              Rome, Lazio, Italy (41.88930, 12.49350; area)

            """)
        #expect(m.calls.isEmpty)
    }

    @Test("an address with coordinates is a conflict, refused before the lookup")
    func addAddressConflict() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Add.perform(
            title: "T", latitude: 41.9, longitude: 12.5, locationAddress: "Via Roma 1",
            json: true, store: s, writer: m, private: MockPrivateWriter(), geocoder: geocoder)
        #expect(out.exitCode == 1)
        #expect(out.stderr == #"{"status": "error", "code": "location_address_conflict", "message": "Pass --location-address or --latitude/--longitude, not both."}"# + "\n")
        #expect(geocoder.queries.isEmpty)
        #expect(m.calls.isEmpty)
    }

    @Test("an invalid radius stops add before the lookup")
    func addAddressInvalidRadius() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Add.perform(title: "T", radius: 0, locationAddress: "Via Roma 1", json: true,
                                        store: s, writer: m, private: MockPrivateWriter(), geocoder: geocoder)
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains(#""code": "invalid_location_radius""#))
        #expect(geocoder.queries.isEmpty)
        #expect(m.calls.isEmpty)
    }

    @Test("a personal label stops add with no write and no geocoder call")
    func addAddressPersonalLabel() async throws {
        let (s, dir) = try emptyStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        for label in ["Home", "my house!"] {
            let out = try await Add.perform(title: "T", locationAddress: label, json: true,
                                            store: s, writer: m, private: MockPrivateWriter(), geocoder: geocoder)
            #expect(out.exitCode == 1)
            #expect(out.stderr.contains(#""code": "location_label_not_address""#))
        }
        #expect(geocoder.queries.isEmpty)
        #expect(m.calls.isEmpty)
    }

    // MARK: - edit --location-address

    @Test("edit geocodes the address and updates the reminder with the match")
    func editAddressResolved() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Edit.perform(
            id: 42, proximity: .leaving, locationAddress: "Piazza Navona, Rome",
            json: false, store: s, writer: m, private: mp, geocoder: geocoder)
        #expect(out.exitCode == 0)
        #expect(updatedWrite(m)?.location == LocationAlarmWrite(
            title: "Piazza Navona", latitude: 41.8978252, longitude: 12.4732402,
            radius: 100, proximity: "leaving"))
        #expect(mp.calls.isEmpty)
        #expect(out.stdout == """
            Updated #42
            Location: Piazza Navona, Rome, Lazio, 00186, Italy (41.897825, 12.473240)

            """)
    }

    @Test("edit --json reports the resolved location after the existing keys")
    func editAddressJSON() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let out = try await Edit.perform(
            id: 42, locationAddress: "Piazza Navona, Rome", json: true, store: s, writer: m,
            private: MockPrivateWriter(), geocoder: FakeGeocoder(places: [GeocodeFixtures.piazzaNavona]))
        #expect(out.exitCode == 0)
        #expect(out.stdout == #"{"status": "updated", "id": 42, "title": "T", "resolvedLocation": {"query": "Piazza Navona, Rome", "title": "Piazza Navona", "address": "Piazza Navona, Rome, Lazio, 00186, Italy", "latitude": 41.8978252, "longitude": 12.4732402, "precision": "street", "radius": 100.0, "proximity": "arriving", "source": "geocoded"}}"# + "\n")
    }

    @Test("an unusable lookup changes nothing")
    func editAddressUnusable() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter(); let mp = MockPrivateWriter()
        let out = try await Edit.perform(
            id: 42, title: "New title", locationAddress: "Rome", json: true, store: s, writer: m,
            private: mp, geocoder: FakeGeocoder(places: [GeocodeFixtures.rome]))
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains(#""code": "location_imprecise""#))
        #expect(m.calls.isEmpty)   // the title edit never reached EventKit either
        #expect(mp.calls.isEmpty)
    }

    @Test("edit refuses an address together with coordinates")
    func editAddressConflict() async throws {
        let (s, dir) = try withReminder(); defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Edit.perform(
            id: 42, latitude: 1, longitude: 2, locationAddress: "Via Roma 1", json: false,
            store: s, writer: m, private: MockPrivateWriter(), geocoder: geocoder)
        #expect(out.exitCode == 1)
        #expect(out.stderr == "Error: Pass --location-address or --latitude/--longitude, not both.\n")
        #expect(geocoder.queries.isEmpty)
        #expect(m.calls.isEmpty)
    }

    @Test("--location-address and the hidden --address alias are one option")
    func addressAliasCollapses() throws {
        #expect(try LocationAlarmInput.address("A", alias: nil) == "A")
        #expect(try LocationAlarmInput.address(nil, alias: "B") == "B")
        #expect(try LocationAlarmInput.address(nil, alias: nil) == nil)
        #expect(throws: CLIError.self) { try LocationAlarmInput.address("A", alias: "B") }
    }

    @Test("a list move with subtasks refuses to carry an address lookup")
    func editAddressWithSubtaskMove() async throws {
        let (s, dir) = try store { db in
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (10,3,'Work',0,'CK-W')")
            try db.execute(sql: "INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (11,3,'Home',0,'CK-H')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER) VALUES (42,'T',10,1,0,0,'ABC')")
            try db.execute(sql: "INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZCKIDENTIFIER,ZPARENTREMINDER) VALUES (43,'Child',10,1,0,0,'DEF',42)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = MockWriter()
        let geocoder = FakeGeocoder(places: [GeocodeFixtures.piazzaNavona])
        let out = try await Edit.perform(
            id: 42, list: "Home", locationAddress: "Piazza Navona, Rome", json: true,
            store: s, writer: m, private: MockPrivateWriter(), geocoder: geocoder)
        #expect(out.exitCode == 1)
        #expect(out.stderr.contains("list_move_with_subtasks_conflicts_with_edits"))
        #expect(geocoder.queries.isEmpty)
        #expect(m.calls.isEmpty)
    }
}
