import Testing
import ReminderKitPrivate

@Test("ReminderKitPrivate links and the private framework loads")
func privateFrameworkProbe() {
    // RKPProbe() returns "reminderkit-ok" when the private REMStore class
    // resolves at runtime, proving both link-time and runtime availability.
    #expect(String(cString: RKPProbe()) == "reminderkit-ok")
}
