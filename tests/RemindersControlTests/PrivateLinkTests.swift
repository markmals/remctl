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

// RKPLooksLikeWebURL is the host policy the helper applies before saving a rich link.
// These cases are all numeric literals, so they never touch DNS.

@Test("Rich links reject IPv4-mapped IPv6 loopback literals")
func privateURLRejectsMappedLoopback() {
    // getaddrinfo returns ::ffff:127.0.0.1 as an AF_INET6 v4-mapped address, which the
    // plain IPv6 predicates (loopback/link-local/ULA) all miss.
    #expect(RKPLooksLikeWebURL("http://[::ffff:127.0.0.1]/") == false)
    #expect(RKPLooksLikeWebURL("http://[::ffff:192.168.1.1]/") == false)
}

@Test("Rich links reject literal fake-IP targets, including DNS-dot spellings")
func privateURLRejectsFakeIPLiterals() {
    // 198.18.0.0/15 is the fake-IP range DNS proxies hand out; a literal target is never real.
    #expect(RKPLooksLikeWebURL("https://198.18.0.1/") == false)
    #expect(RKPLooksLikeWebURL("https://198.19.255.254/") == false)
    #expect(RKPLooksLikeWebURL("https://198.18.0.1./") == false)
    #expect(RKPLooksLikeWebURL("http://[::ffff:198.18.0.1]/") == false)
}

@Test("Rich links still reject plain loopback and non-web schemes")
func privateURLRejectsLoopbackAndSchemes() {
    #expect(RKPLooksLikeWebURL("http://127.0.0.1/") == false)
    #expect(RKPLooksLikeWebURL("http://[::1]/") == false)
    #expect(RKPLooksLikeWebURL("http://localhost/") == false)
    #expect(RKPLooksLikeWebURL("ftp://198.51.100.9/") == false)
    #expect(RKPLooksLikeWebURL("not a url") == false)
}
