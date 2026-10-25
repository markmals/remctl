import Foundation

/// An EventKit source reduced to the fields iCloud identification needs.
public struct ReminderSourceDescriptor: Equatable {
    public var identifier: String
    public var title: String
    public var isCalDAV: Bool
    public init(identifier: String, title: String, isCalDAV: Bool) {
        self.identifier = identifier; self.title = title; self.isCalDAV = isCalDAV
    }
}

/// An EventKit reminder calendar reduced to the fields list targeting needs, so the
/// matching rules stay testable without a live store or a granted TCC permission.
public struct ReminderCalendarDescriptor: Equatable {
    public var identifier: String
    public var title: String
    public var source: ReminderSourceDescriptor
    public init(identifier: String, title: String, source: ReminderSourceDescriptor) {
        self.identifier = identifier; self.title = title; self.source = source
    }
}

/// A list-targeting failure carrying the user-facing message. Callers re-wrap it in
/// their own error type (`WriteError` on writes, `EventKitReadError` on reads).
public struct ListTargetingError: Error, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Shared EventKit list targeting: stable-identifier matching, iCloud scoping and the
/// ambiguity rules. Port of the bridge's `normalizedReminderKitListIdentifier` /
/// `isICloudReminderSource` / `findList` / `eventKitCalendars`
/// (upstream c0db904, e2cbc6b, e6d2a7e).
public enum ListTargeting {
    /// The Accounts provider identifier that marks an Apple (iCloud) account.
    public static let appleAccountProvider = "com.apple.account.AppleAccount"

    /// Strips the ReminderKit URL prefix so a store CKID and an EventKit
    /// `calendarIdentifier` can be compared directly.
    public static func normalizedListIdentifier(_ raw: String) -> String {
        raw.replacingOccurrences(of: "x-apple-reminderkit://REMCDList/", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Account IDs survive renaming; display names do not identify a provider, so the
    /// title check is only the fallback for unavailable account records (upstream e2cbc6b).
    public static func isICloudSource(_ source: ReminderSourceDescriptor, providers: [String: String]) -> Bool {
        guard source.isCalDAV else { return false }
        if let provider = providers[source.identifier.lowercased()] {
            return provider == appleAccountProvider
        }
        return source.title.localizedCaseInsensitiveContains("icloud")
    }

    public static func isICloud(_ calendar: ReminderCalendarDescriptor, providers: [String: String]) -> Bool {
        isICloudSource(calendar.source, providers: providers)
    }

    public static func iCloudCalendars(_ calendars: [ReminderCalendarDescriptor],
                                       providers: [String: String]) -> [ReminderCalendarDescriptor] {
        calendars.filter { isICloud($0, providers: providers) }
    }

    /// The source new lists belong in. nil means the account has no iCloud Reminders source.
    public static func firstICloudSourceIndex(in sources: [ReminderSourceDescriptor],
                                              providers: [String: String]) -> Int? {
        sources.indices.first { isICloudSource(sources[$0], providers: providers) }
    }

    /// Port of the bridge `findList`: match the stable ReminderKit identifier first, then a
    /// unique iCloud title. Returns the index into `calendars`.
    public static func findListIndex(in calendars: [ReminderCalendarDescriptor],
                                     name: String?, listId: String?,
                                     providers: [String: String]) throws -> Int {
        if let listId, !listId.isEmpty {
            let wanted = normalizedListIdentifier(listId)
            let matches = calendars.indices.filter {
                normalizedListIdentifier(calendars[$0].identifier).caseInsensitiveCompare(wanted) == .orderedSame
            }
            if matches.count == 1 {
                guard isICloud(calendars[matches[0]], providers: providers) else {
                    throw ListTargetingError(
                        "List \(wanted) is not in iCloud Reminders; remctl only writes iCloud Reminders lists")
                }
                return matches[0]
            }
            if matches.count > 1 {
                throw ListTargetingError("Multiple EventKit reminder lists match id \(wanted)")
            }
            guard name?.isEmpty == false else {
                throw ListTargetingError("iCloud Reminders list not found for id: \(wanted)")
            }
            // EventKit and ReminderKit identifiers have diverged across macOS releases.
            // If the stable DB id cannot be matched, fall back to the unique iCloud title below.
        }

        guard let name, !name.isEmpty else {
            throw ListTargetingError("List name or listId is required")
        }
        let iCloudMatches = calendars.indices.filter {
            isICloud(calendars[$0], providers: providers) && calendars[$0].title == name
        }
        if iCloudMatches.count == 1 { return iCloudMatches[0] }
        if iCloudMatches.count > 1 {
            throw ListTargetingError("Multiple iCloud Reminders lists named \(name); pass --list-id")
        }
        if calendars.contains(where: { $0.title == name }) {
            throw ListTargetingError(
                "List \(name) is not in iCloud Reminders; remctl does not write non-iCloud Reminders accounts")
        }
        throw ListTargetingError("iCloud Reminders list not found: \(name)")
    }

    /// Port of the bridge `eventKitCalendars`: scope a read to one named iCloud list, or to
    /// every iCloud reminder list when no name is given (a nil scope used to query all sources).
    public static func readCalendars(in calendars: [ReminderCalendarDescriptor],
                                     listName: String?,
                                     providers: [String: String]) throws -> [ReminderCalendarDescriptor] {
        if let listName, !listName.isEmpty {
            let matches = iCloudCalendars(calendars, providers: providers).filter { $0.title == listName }
            if matches.isEmpty {
                if calendars.contains(where: { $0.title == listName }) {
                    throw ListTargetingError(
                        "List \(listName) is not in iCloud Reminders; EventKit fallback is iCloud-only")
                }
                throw ListTargetingError("iCloud Reminders list not found: \(listName)")
            }
            if matches.count > 1 {
                throw ListTargetingError(
                    "Multiple iCloud Reminders lists named \(listName); EventKit fallback cannot disambiguate them")
            }
            return matches
        }
        let iCloud = iCloudCalendars(calendars, providers: providers)
        if iCloud.isEmpty { throw ListTargetingError("No iCloud Reminders source found") }
        return iCloud
    }
}
