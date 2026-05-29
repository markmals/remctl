import Testing
import Foundation
import GRDB
@testable import RemindersControl

// Shared fixture: one list + one reminder due "today" (Apple epoch offset) and one overdue
private func makeDateFixture(_ db: Database) throws {
    try db.execute(sql: """
    INSERT INTO ZREMCDBASELIST (Z_PK,Z_ENT,ZNAME,ZMARKEDFORDELETION) VALUES (10,3,'MyList',0);
    """)
}

@Suite struct TodayCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["today"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.hasPrefix("Nothing due today ("))
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["today", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsDueTodaySection() throws {
        // Insert a reminder due at start-of-today (Apple epoch)
        let now = Date()
        let cal = Calendar.current
        let todaySod = cal.startOfDay(for: now)
        // Due today: SOD + 2 hours = in today's window
        let dueToday = AppleEpoch.toTs(todaySod.addingTimeInterval(7200))

        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
            VALUES (1,'Buy milk',10,1,0,0,\(dueToday));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["today"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Due Today"))
        #expect(r.stdout.contains("Buy milk"))
        #expect(r.stdout.contains("1 total"))
    }

    @Test func noOverdueFlagExcludesOverdueItems() throws {
        let now = Date()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let overdueTs = AppleEpoch.toTs(yesterday)

        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
            VALUES (1,'Old task',10,1,0,0,\(overdueTs));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        // Without --no-overdue, it should show the overdue item
        let r1 = try CLIRunner.run(["today"], storeDir: dir)
        #expect(r1.stdout.contains("Overdue"))
        // With --no-overdue, empty
        let r2 = try CLIRunner.run(["today", "--no-overdue"], storeDir: dir)
        #expect(r2.stdout.hasPrefix("Nothing due today ("))
    }
}

@Suite struct UpcomingCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "Nothing due in the next 7 days\n")
    }

    @Test func invalidDaysValidation() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming", "0"], storeDir: dir)
        #expect(r.exit != 0)
        #expect(r.stderr.contains("Error: upcoming days must be between 1 and 3650"))
    }

    @Test func daysOver3650Fails() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming", "3651"], storeDir: dir)
        #expect(r.exit != 0)
        #expect(r.stderr.contains("Error: upcoming days must be between 1 and 3650"))
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedGroupsByDay() throws {
        let now = Date()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        let dueTs = AppleEpoch.toTs(tomorrow.addingTimeInterval(3600))

        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
            VALUES (1,'Future task',10,1,0,0,\(dueTs));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["upcoming", "7"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Upcoming (7 days):"))
        #expect(r.stdout.contains("Future task"))
        #expect(r.stdout.contains("1 upcoming"))
    }
}

@Suite struct OverdueCommandTests {
    @Test func emptyHumanMessage() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["overdue"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout == "No overdue reminders\n")
    }

    @Test func jsonEmptyArray() throws {
        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["overdue", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [Any]
        #expect(parsed?.isEmpty == true)
    }

    @Test func populatedShowsOverdueHeader() throws {
        let now = Date()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let overdueTs = AppleEpoch.toTs(yesterday)

        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
            VALUES (1,'Missed task',10,1,0,0,\(overdueTs));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["overdue"], storeDir: dir)
        #expect(r.exit == 0)
        #expect(r.stdout.contains("Overdue (1):"))
        #expect(r.stdout.contains("Missed task"))
        #expect(r.stdout.contains("1 overdue"))
    }

    @Test func jsonPopulatedHasIdField() throws {
        let now = Date()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
        let overdueTs = AppleEpoch.toTs(yesterday)

        let dir = try FixtureDB.tempStore { db in
            try FixtureDB.createRemindersSchema(db)
            try makeDateFixture(db)
            try db.execute(sql: """
            INSERT INTO ZREMCDREMINDER (Z_PK,ZTITLE,ZLIST,ZACCOUNT,ZCOMPLETED,ZMARKEDFORDELETION,ZDUEDATE)
            VALUES (5,'Missed',10,1,0,0,\(overdueTs));
            """)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try CLIRunner.run(["overdue", "--json"], storeDir: dir)
        #expect(r.exit == 0)
        let parsed = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [[String: Any]]
        #expect(parsed?.count == 1)
        #expect((parsed?.first?["id"] as? Int) == 5)
    }
}
