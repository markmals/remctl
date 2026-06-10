import XCTest
@testable import RemindersControl

/// Tests for the PURE static helpers in `ReminderKitWriter`.
///
/// Do NOT instantiate `ReminderKitWriter` and call the 20 dispatching methods
/// — those invoke `RKPDispatch` which attempts live ReminderKit saves against
/// the real Reminders store. All tests here are purely computational: they
/// exercise `isTransient(message:)` and `anyToJSONValue(_:)`.
final class ReminderKitWriterTests: XCTestCase {

    // MARK: - isTransient

    func testIsTransientReturnsFalseForNil() {
        XCTAssertFalse(ReminderKitWriter.isTransient(message: nil))
    }

    func testIsTransientReturnsFalseForUnrelatedError() {
        XCTAssertFalse(ReminderKitWriter.isTransient(message: "Reminder not found"))
        XCTAssertFalse(ReminderKitWriter.isTransient(message: ""))
        XCTAssertFalse(ReminderKitWriter.isTransient(message: "save failed"))
    }

    func testIsTransientReturnsTrueForCurlyApostrophe() {
        // Full ReminderKit error string uses U+2019 (curly/right single quote).
        let curly = "Couldn\u{2019}t communicate with a helper application."
        XCTAssertTrue(ReminderKitWriter.isTransient(message: curly))
    }

    func testIsTransientReturnsTrueForStraightApostrophe() {
        // Belt-and-suspenders: also match the straight-apostrophe variant.
        let straight = "Couldn't communicate with a helper application."
        XCTAssertTrue(ReminderKitWriter.isTransient(message: straight))
    }

    func testIsTransientReturnsTrueForSubstring() {
        // The predicate matches a substring, not the full string.
        let embedded = "Error: communicate with a helper application was not possible"
        XCTAssertTrue(ReminderKitWriter.isTransient(message: embedded))
    }

    func testIsTransientReturnsFalseForPartialMatch() {
        // "helper application" alone without the required prefix does NOT match.
        XCTAssertFalse(ReminderKitWriter.isTransient(message: "helper application unavailable"))
    }

    // MARK: - anyToJSONValue — NSNull

    func testAnyToJSONValueNSNull() {
        let result = ReminderKitWriter.anyToJSONValue(NSNull())
        XCTAssertEqual(result, .null)
    }

    // MARK: - anyToJSONValue — NSString

    func testAnyToJSONValueNSString() {
        let result = ReminderKitWriter.anyToJSONValue(NSString("hello"))
        XCTAssertEqual(result, .string("hello"))
    }

    func testAnyToJSONValueEmptyNSString() {
        let result = ReminderKitWriter.anyToJSONValue(NSString(""))
        XCTAssertEqual(result, .string(""))
    }

    // MARK: - anyToJSONValue — NSNumber (bool)

    func testAnyToJSONValueNSNumberTrue() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: true))
        XCTAssertEqual(result, .bool(true))
    }

    func testAnyToJSONValueNSNumberFalse() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: false))
        XCTAssertEqual(result, .bool(false))
    }

    func testAnyToJSONValueCFBooleanTrue() {
        // kCFBooleanTrue bridged to NSNumber must round-trip as .bool(true).
        let cfTrue = kCFBooleanTrue as AnyObject
        let result = ReminderKitWriter.anyToJSONValue(cfTrue)
        XCTAssertEqual(result, .bool(true))
    }

    func testAnyToJSONValueCFBooleanFalse() {
        let cfFalse = kCFBooleanFalse as AnyObject
        let result = ReminderKitWriter.anyToJSONValue(cfFalse)
        XCTAssertEqual(result, .bool(false))
    }

    // MARK: - anyToJSONValue — NSNumber (integer)

    func testAnyToJSONValueNSNumberInt() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: 42))
        XCTAssertEqual(result, .int(42))
    }

    func testAnyToJSONValueNSNumberNegativeInt() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: -7))
        XCTAssertEqual(result, .int(-7))
    }

    func testAnyToJSONValueNSNumberZeroInt() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: 0 as Int))
        // 0 as Int → .int, not .bool(false)
        XCTAssertEqual(result, .int(0))
    }

    // MARK: - anyToJSONValue — NSNumber (double)

    func testAnyToJSONValueNSNumberDouble() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: 3.14 as Double))
        XCTAssertEqual(result, .double(3.14))
    }

    func testAnyToJSONValueNSNumberFloat() {
        let result = ReminderKitWriter.anyToJSONValue(NSNumber(value: 1.5 as Float))
        // Float objCType == "f", mapped to .double
        if case .double = result { /* ok */ } else {
            XCTFail("Expected .double, got \(result)")
        }
    }

    // MARK: - anyToJSONValue — NSArray

    func testAnyToJSONValueEmptyNSArray() {
        let result = ReminderKitWriter.anyToJSONValue(NSArray())
        XCTAssertEqual(result, .array([]))
    }

    func testAnyToJSONValueNSArrayOfStrings() {
        let arr = NSArray(array: [NSString("a"), NSString("b")])
        let result = ReminderKitWriter.anyToJSONValue(arr)
        XCTAssertEqual(result, .array([.string("a"), .string("b")]))
    }

    func testAnyToJSONValueNSArrayMixed() {
        let arr = NSArray(array: [NSNumber(value: 1), NSNull(), NSString("x")])
        let result = ReminderKitWriter.anyToJSONValue(arr)
        XCTAssertEqual(result, .array([.int(1), .null, .string("x")]))
    }

    // MARK: - anyToJSONValue — NSDictionary

    func testAnyToJSONValueEmptyNSDictionary() {
        let result = ReminderKitWriter.anyToJSONValue(NSDictionary())
        XCTAssertEqual(result, .object([]))
    }

    func testAnyToJSONValueNSDictionaryWithStringValues() {
        let dict = NSDictionary(dictionary: ["status": NSString("updated"), "id": NSString("abc")])
        let result = ReminderKitWriter.anyToJSONValue(dict)
        // NSDictionary enumeration order is undefined — check membership, not order.
        guard case .object(let pairs) = result else {
            XCTFail("Expected .object"); return
        }
        let map = Dictionary(uniqueKeysWithValues: pairs)
        XCTAssertEqual(map["status"], .string("updated"))
        XCTAssertEqual(map["id"], .string("abc"))
    }

    func testAnyToJSONValueNSDictionaryNestedArray() {
        let inner = NSArray(array: [NSNumber(value: 1), NSNumber(value: 2)])
        let dict = NSDictionary(dictionary: ["items": inner])
        let result = ReminderKitWriter.anyToJSONValue(dict)
        guard case .object(let pairs) = result, let entry = pairs.first else {
            XCTFail("Expected .object with one pair"); return
        }
        XCTAssertEqual(entry.0, "items")
        XCTAssertEqual(entry.1, .array([.int(1), .int(2)]))
    }

    // MARK: - Bool vs Int disambiguation

    func testBoolDoesNotConflateWithZeroInt() {
        // NSNumber(value: false) vs NSNumber(value: 0 as Int) must produce different
        // JSONValue cases to preserve round-trip fidelity.
        let boolFalse = ReminderKitWriter.anyToJSONValue(NSNumber(value: false))
        let intZero   = ReminderKitWriter.anyToJSONValue(NSNumber(value: 0 as Int))
        XCTAssertNotEqual(boolFalse, intZero,
            "Bool(false) and Int(0) must map to different JSONValue cases")
        XCTAssertEqual(boolFalse, .bool(false))
        XCTAssertEqual(intZero, .int(0))
    }

    func testBoolDoesNotConflateWithOneInt() {
        let boolTrue = ReminderKitWriter.anyToJSONValue(NSNumber(value: true))
        let intOne   = ReminderKitWriter.anyToJSONValue(NSNumber(value: 1 as Int))
        XCTAssertNotEqual(boolTrue, intOne,
            "Bool(true) and Int(1) must map to different JSONValue cases")
        XCTAssertEqual(boolTrue, .bool(true))
        XCTAssertEqual(intOne, .int(1))
    }
}

// MARK: - remindd hint on transient errors (adapted from upstream aba7cf5)

final class ReminddHintTests: XCTestCase {
    let transient = "Couldn’t communicate with a helper application."

    func testAppendsHintWhenReminddStopped() {
        let enriched = ReminderKitWriter.enrichTransientMessage(transient, remindd: false)
        XCTAssertEqual(enriched, transient + " Reminders daemon (remindd) is not running; open Reminders.app, then retry.")
    }

    func testLeavesMessageWhenReminddRunningOrUnknown() {
        XCTAssertEqual(ReminderKitWriter.enrichTransientMessage(transient, remindd: true), transient)
        XCTAssertEqual(ReminderKitWriter.enrichTransientMessage(transient, remindd: nil), transient)
    }

    func testLeavesNonTransientMessages() {
        XCTAssertEqual(ReminderKitWriter.enrichTransientMessage("Reminder not found", remindd: false), "Reminder not found")
        XCTAssertNil(ReminderKitWriter.enrichTransientMessage(nil, remindd: false))
    }
}
