import Testing
import Foundation
@testable import RemindersControl

/// List targeting: stable-identifier matching, iCloud scoping and the ambiguity rules that
/// `EventKitWriter.findList` / `EventKitReader.calendars` apply (upstream c0db904, e2cbc6b, e6d2a7e).
@Suite struct ListTargetingTests {
    private func iCloudSource(_ id: String = "src-icloud", title: String = "iCloud") -> ReminderSourceDescriptor {
        ReminderSourceDescriptor(identifier: id, title: title, isCalDAV: true)
    }
    private func localSource() -> ReminderSourceDescriptor {
        ReminderSourceDescriptor(identifier: "src-local", title: "On My Mac", isCalDAV: false)
    }
    private func exchangeSource() -> ReminderSourceDescriptor {
        ReminderSourceDescriptor(identifier: "src-exchange", title: "Work Exchange", isCalDAV: true)
    }
    private func calendar(_ id: String, _ title: String, _ source: ReminderSourceDescriptor) -> ReminderCalendarDescriptor {
        ReminderCalendarDescriptor(identifier: id, title: title, source: source)
    }

    // MARK: - Identifier matching

    @Test func listIdPicksTheRightDuplicateTitle() throws {
        let calendars = [
            calendar("UUID-A", "Work", iCloudSource()),
            calendar("UUID-B", "Work", iCloudSource("src-icloud-2", title: "iCloud")),
        ]
        #expect(try ListTargeting.findListIndex(in: calendars, name: "Work", listId: "UUID-B", providers: [:]) == 1)
    }

    @Test func listIdAcceptsReminderKitURLForm() throws {
        let calendars = [calendar("UUID-A", "Work", iCloudSource())]
        let index = try ListTargeting.findListIndex(
            in: calendars, name: nil, listId: "x-apple-reminderkit://REMCDList/uuid-a", providers: [:])
        #expect(index == 0)
    }

    @Test func duplicateICloudTitlesAreAmbiguous() {
        let calendars = [
            calendar("UUID-A", "Work", iCloudSource()),
            calendar("UUID-B", "Work", iCloudSource("src-icloud-2", title: "iCloud")),
        ]
        #expect(throws: ListTargetingError("Multiple iCloud Reminders lists named Work; pass --list-id")) {
            try ListTargeting.findListIndex(in: calendars, name: "Work", listId: nil, providers: [:])
        }
    }

    @Test func titleMatchIgnoresNonICloudDuplicate() throws {
        let calendars = [
            calendar("UUID-LOCAL", "Work", localSource()),
            calendar("UUID-A", "Work", iCloudSource()),
        ]
        #expect(try ListTargeting.findListIndex(in: calendars, name: "Work", listId: nil, providers: [:]) == 1)
    }

    @Test func nonICloudOnlyMatchIsRejected() {
        let calendars = [calendar("UUID-LOCAL", "Work", localSource())]
        #expect(throws: ListTargetingError(
            "List Work is not in iCloud Reminders; remctl does not write non-iCloud Reminders accounts")) {
            try ListTargeting.findListIndex(in: calendars, name: "Work", listId: nil, providers: [:])
        }
    }

    @Test func listIdOnANonICloudListIsRejected() {
        let calendars = [calendar("UUID-LOCAL", "Work", localSource())]
        #expect(throws: ListTargetingError(
            "List UUID-LOCAL is not in iCloud Reminders; remctl only writes iCloud Reminders lists")) {
            try ListTargeting.findListIndex(in: calendars, name: nil, listId: "UUID-LOCAL", providers: [:])
        }
    }

    /// EventKit and ReminderKit identifiers have diverged across macOS releases, so an unmatched
    /// CKID must still resolve through a unique iCloud title.
    @Test func unknownListIdFallsBackToUniqueTitle() throws {
        let calendars = [calendar("EK-1", "Work", iCloudSource())]
        #expect(try ListTargeting.findListIndex(in: calendars, name: "Work", listId: "CK-UNKNOWN", providers: [:]) == 0)
    }

    @Test func unknownListIdWithoutNameIsAnError() {
        let calendars = [calendar("EK-1", "Work", iCloudSource())]
        #expect(throws: ListTargetingError("iCloud Reminders list not found for id: CK-UNKNOWN")) {
            try ListTargeting.findListIndex(in: calendars, name: nil, listId: "CK-UNKNOWN", providers: [:])
        }
    }

    @Test func duplicateIdentifiersAreAmbiguous() {
        let calendars = [
            calendar("EK-1", "Work", iCloudSource()),
            calendar("ek-1", "Work copy", iCloudSource()),
        ]
        #expect(throws: ListTargetingError("Multiple EventKit reminder lists match id EK-1")) {
            try ListTargeting.findListIndex(in: calendars, name: nil, listId: "EK-1", providers: [:])
        }
    }

    // MARK: - iCloud source identification

    @Test func iCloudSourceIsPickedOverLocalAndExchange() {
        var withLists = iCloudSource(); withLists.holdsReminderLists = true
        let sources = [localSource(), exchangeSource(), withLists]
        #expect(ListTargeting.newListSourceIndex(in: sources, defaultReminderSource: nil, providers: [:]) == 2)
    }

    @Test func noICloudSourceYieldsNil() {
        let sources = [localSource(), exchangeSource()]
        #expect(ListTargeting.newListSourceIndex(in: sources, defaultReminderSource: "src-local", providers: [:]) == nil)
    }

    /// An iCloud account exposes a calendar source and a Reminders source, both titled
    /// "iCloud" and both CalDAV; the calendar one rejects lists ("That account does not
    /// support reminders").
    @Test func calendarOnlyICloudSourceIsSkipped() {
        let calendars = iCloudSource("src-icloud-calendars")
        let reminders = ReminderSourceDescriptor(identifier: "src-icloud-reminders", title: "iCloud",
                                                 isCalDAV: true, holdsReminderLists: true)
        #expect(ListTargeting.newListSourceIndex(in: [calendars, reminders], defaultReminderSource: nil, providers: [:]) == 1)
    }

    /// A Reminders account with no lists yet still owns the default list's source.
    @Test func defaultReminderSourceWinsEvenWithoutLists() {
        let calendars = iCloudSource("src-icloud-calendars")
        let reminders = iCloudSource("src-icloud-reminders")
        #expect(ListTargeting.newListSourceIndex(in: [calendars, reminders],
                                                 defaultReminderSource: "src-icloud-reminders", providers: [:]) == 1)
        #expect(ListTargeting.newListSourceIndex(in: [calendars, reminders], defaultReminderSource: nil, providers: [:]) == nil)
    }

    /// Account IDs survive renaming; a renamed iCloud account no longer contains "iCloud".
    @Test func renamedICloudAccountIsRecognizedByProvider() {
        let renamed = ReminderSourceDescriptor(identifier: "ABC-123", title: "Personal", isCalDAV: true,
                                               holdsReminderLists: true)
        let providers = ["abc-123": ListTargeting.appleAccountProvider]
        #expect(ListTargeting.newListSourceIndex(in: [renamed], defaultReminderSource: nil, providers: providers) == 0)
        #expect(ListTargeting.newListSourceIndex(in: [renamed], defaultReminderSource: nil, providers: [:]) == nil)
    }

    /// A non-Apple account that merely says "iCloud" in its name is not iCloud when the
    /// account records are readable.
    @Test func providerMapOverridesMisleadingTitle() {
        let fake = ReminderSourceDescriptor(identifier: "XYZ-9", title: "iCloud Mirror", isCalDAV: true,
                                            holdsReminderLists: true)
        let providers = ["xyz-9": "com.apple.account.CalDAV"]
        #expect(ListTargeting.newListSourceIndex(in: [fake], defaultReminderSource: "XYZ-9", providers: providers) == nil)
        #expect(ListTargeting.newListSourceIndex(in: [fake], defaultReminderSource: nil, providers: [:]) == 0)
    }

    // MARK: - Read scoping

    @Test func unnamedReadScopeKeepsOnlyICloudCalendars() throws {
        let calendars = [
            calendar("UUID-LOCAL", "Local", localSource()),
            calendar("UUID-A", "Work", iCloudSource()),
        ]
        let scoped = try ListTargeting.readCalendars(in: calendars, listName: nil, providers: [:])
        #expect(scoped.map(\.identifier) == ["UUID-A"])
    }

    @Test func unnamedReadScopeWithoutICloudIsAnError() {
        let calendars = [calendar("UUID-LOCAL", "Local", localSource())]
        #expect(throws: ListTargetingError("No iCloud Reminders source found")) {
            try ListTargeting.readCalendars(in: calendars, listName: nil, providers: [:])
        }
    }

    @Test func namedReadScopeRejectsNonICloudList() {
        let calendars = [calendar("UUID-LOCAL", "Local", localSource())]
        #expect(throws: ListTargetingError(
            "List Local is not in iCloud Reminders; EventKit fallback is iCloud-only")) {
            try ListTargeting.readCalendars(in: calendars, listName: "Local", providers: [:])
        }
    }

    @Test func namedReadScopeRejectsDuplicates() {
        let calendars = [
            calendar("UUID-A", "Work", iCloudSource()),
            calendar("UUID-B", "Work", iCloudSource("src-2", title: "iCloud")),
        ]
        #expect(throws: ListTargetingError(
            "Multiple iCloud Reminders lists named Work; EventKit fallback cannot disambiguate them")) {
            try ListTargeting.readCalendars(in: calendars, listName: "Work", providers: [:])
        }
    }
}
