import Testing
@testable import RemindersControl

@Suite struct JSONValueTests {
    @Test func prettyArrayOfOneObjectMatchesPythonIndent2() {
        let v: JSONValue = .array([.object([
            ("id", .int(42)), ("title", .string("Buy milk")), ("completed", .bool(false)),
        ])])
        let expected = """
        [
          {
            "id": 42,
            "title": "Buy milk",
            "completed": false
          }
        ]
        """
        #expect(v.serialized(indent: 2, ensureAscii: false) == expected)
    }

    @Test func emptyContainers() {
        #expect(JSONValue.array([]).serialized(indent: 2, ensureAscii: false) == "[]")
        #expect(JSONValue.object([]).serialized(indent: 2, ensureAscii: false) == "{}")
    }

    @Test func compactSeparatorsMatchPythonDefault() {
        let v: JSONValue = .object([("a", .int(1)), ("b", .array([.int(2), .int(3)]))])
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"a": 1, "b": [2, 3]}"#)
    }

    @Test func ensureAsciiEscapesNonAsciiWhenTrue() {
        // Python json.dumps({"name":"café 🥕"}) ensure_ascii=True -> escapes é to é and
        // 🥕 to the UTF-16 surrogate pair 🥕 (lowercase hex). Verified byte-for-byte:
        //   python3 -c 'import json; print(json.dumps({"name":"café 🥕"}))'
        //   -> {"name": "café 🥕"}
        // The raw-string literal below contains those backslash-u sequences as literal characters.
        let v: JSONValue = .object([("name", .string("café 🥕"))])
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"name": "caf\u00e9 \ud83e\udd55"}"#)
    }

    @Test func ensureAsciiFalseEmitsLiteralUnicode() {
        let v: JSONValue = .object([("name", .string("café 🥕"))])
        #expect(v.serialized(indent: nil, ensureAscii: false) == #"{"name": "café 🥕"}"#)
    }

    @Test func doesNotEscapeForwardSlash() {
        #expect(JSONValue.string("a/b").serialized(indent: nil, ensureAscii: true) == #""a/b""#)
    }

    @Test func escapesControlAndQuoteAndBackslash() {
        #expect(JSONValue.string("a\"b\\c\n\t").serialized(indent: nil, ensureAscii: true) == #""a\"b\\c\n\t""#)
    }

    @Test func wholeNumberDoubleRendersWithPointZero() {
        // pinnedDate raw Apple timestamps appear as 123.0
        #expect(JSONValue.double(123.0).serialized(indent: nil, ensureAscii: true) == "123.0")
    }
}
