import Testing
import Foundation
@testable import RemindersControl

@Suite struct ColorTests {
    @Test func disabledReturnsPlain() {
        let a = Ansi(enabled: false)
        #expect(a.red("x") == "x"); #expect(a.bold("x") == "x"); #expect(a.rgb(1,2,3,"x") == "x")
    }
    @Test func enabledWrapsSGR() {
        let a = Ansi(enabled: true)
        #expect(a.red("x") == "\u{1B}[31mx\u{1B}[0m")
        #expect(a.dim(a.strikethrough("t")) == "\u{1B}[2m\u{1B}[9mt\u{1B}[0m\u{1B}[0m")
        #expect(a.rgb(0,136,255,"L") == "\u{1B}[38;2;0;136;255mL\u{1B}[0m")
    }
    @Test func resolveSuppressesOnNoColorFlagEnvOrNonTTY() {
        #expect(Ansi.resolve(noColorFlag: true, env: [:], isTTY: true).enabled == false)
        // Python uses os.environ.get("NO_COLOR") with truthiness: empty string is falsy → does NOT suppress
        #expect(Ansi.resolve(noColorFlag: false, env: ["NO_COLOR": ""], isTTY: true).enabled == true)
        // Non-empty NO_COLOR value suppresses color
        #expect(Ansi.resolve(noColorFlag: false, env: ["NO_COLOR": "1"], isTTY: true).enabled == false)
        #expect(Ansi.resolve(noColorFlag: false, env: [:], isTTY: false).enabled == false)
        #expect(Ansi.resolve(noColorFlag: false, env: [:], isTTY: true).enabled == true)
    }
    @Test func safeDisplayReplacesControls() {
        #expect(safeDisplay("a\u{0}b\tc\u{2028}d") == "a b c d")
        #expect(safeDisplay(nil) == "")
        #expect(safeDisplay("\u{1B}]52;c;x\u{07}Clipboard").contains("Clipboard"))
        // ESC (0x1B) and BEL (0x07) are < 0x20 -> spaces; visible text preserved
        #expect(safeDisplay("plain text") == "plain text")
    }
}

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
