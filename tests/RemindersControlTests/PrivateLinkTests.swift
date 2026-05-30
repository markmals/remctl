import Testing
import ReminderKitPrivate

@Test("ReminderKitPrivate links and the private framework loads")
func privateFrameworkProbe() {
    // RKPProbe() returns "reminderkit-ok" when the private REMStore class
    // resolves at runtime, proving both link-time and runtime availability.
    #expect(String(cString: RKPProbe()) == "reminderkit-ok")
}

@Test("RKPDispatch rejects an unknown action without saving")
func privateDispatchUnknownAction() {
    // Exercises the entrypoint + allow-list reject + error envelope WITHOUT
    // reaching any saveSynchronouslyWithError: path (which needs a live store
    // + Reminders TCC grant that CI cannot provide).
    // RKPDispatch's NSDictionary params/return bridge to Swift [AnyHashable: Any].
    let response = RKPDispatch(["action": "totally-unknown"])
    #expect(response["status"] as? String == "error")
}

@Test("RKPDispatch rejects a request with no action")
func privateDispatchMissingAction() {
    // No "action" key -> still routed to the unknown-action / error path,
    // never a save and never a crash.
    let response = RKPDispatch([:])
    #expect(response["status"] as? String == "error")
}
