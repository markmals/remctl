import Testing
@testable import RemindersControl

@Suite struct ConstantsTests {
    @Test func priorityMaps() {
        #expect(Constants.priorityName[0] == "none"); #expect(Constants.priorityName[1] == "high")
        #expect(Constants.priorityName[5] == "medium"); #expect(Constants.priorityName[9] == "low")
        #expect(Constants.priorityMarker[1] == "!!!"); #expect(Constants.priorityMarker[5] == "!!")
        #expect(Constants.priorityMarker[9] == "!"); #expect(Constants.priorityMarker[0] == "")
    }
    @Test func recurrenceMaps() {
        #expect(Constants.recurrenceFrequencies[0] == "daily"); #expect(Constants.recurrenceFrequencies[3] == "yearly")
        #expect(Constants.recurrenceDayNames[2] == "Mon"); #expect(Constants.recurrenceDayNames[4] == "Wed")
        #expect(Constants.dueDateDeltaUnits[0]?.1 == "minutes"); #expect(Constants.dueDateDeltaUnits[2]?.0 == "day")
    }
    @Test func listColorMapAndMarkers() {
        #expect(Constants.listColorMap["blue"]! == (0, 136, 255))
        #expect(Constants.listColorMap["teal"]! == (48, 176, 199))
        #expect(Constants.groceryListMarker == "🥕")
        #expect(Constants.customSmartListType == "com.apple.reminders.smartlist.custom")
        #expect(Constants.smartListTypeNames["com.apple.reminders.smartlist.flagged"] == "Flagged")
        #expect(Constants.deepLinkReminderPrefix == "x-apple-reminderkit://REMCDReminder/")
    }
}
