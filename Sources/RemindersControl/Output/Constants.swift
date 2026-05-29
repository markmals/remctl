public enum Constants {
    public static let priorityName: [Int: String] = [0: "none", 1: "high", 5: "medium", 9: "low"]
    public static let priorityMarker: [Int: String] = [0: "", 1: "!!!", 5: "!!", 9: "!"]

    public static let recurrenceFrequencies: [Int: String] = [0: "daily", 1: "weekly", 2: "monthly", 3: "yearly"]
    /// (singular, plural)
    public static let dueDateDeltaUnits: [Int: (String, String)] =
        [0: ("minute", "minutes"), 1: ("hour", "hours"), 2: ("day", "days"), 3: ("week", "weeks"), 4: ("month", "months")]
    public static let recurrenceDayNames: [Int: String] =
        [1: "Sun", 2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat"]

    public static let listColorMap: [String: (Int, Int, Int)] = [
        "red": (255, 41, 104),
        "orange": (255, 141, 40),
        "yellow": (255, 204, 0),
        "green": (99, 218, 56),
        "blue": (0, 136, 255),
        "purple": (204, 115, 225),
        "brown": (162, 132, 94),
        "gray": (91, 98, 106),
        "cyan": (90, 200, 250),
        "teal": (48, 176, 199),
    ]
    public static let defaultListColorRGB = (0, 122, 255)
    public static let defaultListColorJSON = (name: "blue", hex: "#007AFF")

    public static let groceryListMarker = "🥕"
    public static let customSmartListType = "com.apple.reminders.smartlist.custom"
    public static let smartListTypeNames: [String: String] = [
        "com.apple.reminders.smartlist.all": "All",
        "com.apple.reminders.smartlist.today": "Today",
        "com.apple.reminders.smartlist.scheduled": "Scheduled",
        "com.apple.reminders.smartlist.flagged": "Flagged",
        "com.apple.reminders.smartlist.completed": "Completed",
        "com.apple.reminders.smartlist.assigned": "Assigned",
        "com.apple.reminders.smartlist.urgent": "Urgent",
    ]
    public static let deepLinkReminderPrefix = "x-apple-reminderkit://REMCDReminder/"
    public static let deepLinkTemplatePrefix = "x-apple-reminderkit://REMCDTemplate/"
}
