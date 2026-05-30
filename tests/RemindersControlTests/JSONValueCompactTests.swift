import Testing
import Foundation
@testable import RemindersControl

@Suite struct JSONValueCompactTests {

    // MARK: - Space-free compact output

    @Test func spaceFreeSimpleObject() {
        let v = JSONValue.object([("a", .int(1)), ("b", .string("x"))])
        #expect(v.serialized(indent: nil, ensureAscii: true, spaceSeparators: false) == #"{"a":1,"b":"x"}"#)
    }

    @Test func spaceFreeNestedObject() {
        let v = JSONValue.object([
            ("flagged", .bool(true)),
            ("priorities", .array([.string("high"), .string("medium")])),
        ])
        #expect(v.serialized(indent: nil, ensureAscii: true, spaceSeparators: false)
            == #"{"flagged":true,"priorities":["high","medium"]}"#)
    }

    @Test func spaceFreeNestedObjectInObject() {
        let v = JSONValue.object([
            ("hashtags", .object([("operation", .string("or")), ("include", .array([.string("work")]))])),
        ])
        #expect(v.serialized(indent: nil, ensureAscii: true, spaceSeparators: false)
            == #"{"hashtags":{"operation":"or","include":["work"]}}"#)
    }

    @Test func spaceFreeArray() {
        let v = JSONValue.array([.int(1), .int(2), .int(3)])
        #expect(v.serialized(indent: nil, ensureAscii: true, spaceSeparators: false) == "[1,2,3]")
    }

    // MARK: - Default (spaceSeparators: true) is unchanged

    @Test func defaultSpacedObject() {
        let v = JSONValue.object([("a", .int(1)), ("b", .string("x"))])
        #expect(v.serialized(indent: nil, ensureAscii: true) == #"{"a": 1, "b": "x"}"#)
    }

    @Test func explicitSpaceSeparatorsTrue() {
        let v = JSONValue.object([("a", .int(1)), ("b", .string("x"))])
        #expect(v.serialized(indent: nil, ensureAscii: true, spaceSeparators: true) == #"{"a": 1, "b": "x"}"#)
    }

    // MARK: - ensureAscii: false + spaceSeparators: false

    @Test func spaceFreeNonAsciiPreserved() {
        let v = JSONValue.object([("tag", .string("café"))])
        #expect(v.serialized(indent: nil, ensureAscii: false, spaceSeparators: false) == #"{"tag":"café"}"#)
    }

    @Test func spaceFreeNonAsciiEmojiPreserved() {
        let v = JSONValue.object([("emoji", .string("🥕"))])
        #expect(v.serialized(indent: nil, ensureAscii: false, spaceSeparators: false) == #"{"emoji":"🥕"}"#)
    }

    // MARK: - spaceSeparators ignored when indent != nil (pretty always has spaces)

    @Test func prettyPathIgnoresSpaceSeparatorsFalse() {
        let v = JSONValue.object([("a", .int(1))])
        let spaced   = v.serialized(indent: 2, ensureAscii: false, spaceSeparators: true)
        let noSpaced = v.serialized(indent: 2, ensureAscii: false, spaceSeparators: false)
        #expect(spaced == noSpaced)
        // Pretty path still uses ": " for key-value separator
        #expect(spaced.contains(": "))
    }

    // MARK: - Empty containers unaffected

    @Test func spaceFreeEmptyObject() {
        #expect(JSONValue.object([]).serialized(indent: nil, ensureAscii: false, spaceSeparators: false) == "{}")
    }

    @Test func spaceFreeEmptyArray() {
        #expect(JSONValue.array([]).serialized(indent: nil, ensureAscii: false, spaceSeparators: false) == "[]")
    }

    // MARK: - Round-trip through decodeSmartListFilterBlob

    @Test func roundTripFlaggedFilter() {
        let payload = JSONValue.object([("flagged", .bool(true))])
        let json = payload.serialized(indent: nil, ensureAscii: false, spaceSeparators: false)
        // Matches Python: json.dumps({"flagged": True}, separators=(",",":"), ensure_ascii=False)
        #expect(json == #"{"flagged":true}"#)
        let data = Data(json.utf8)
        let result = decodeSmartListFilterBlob(data)
        #expect(result.encoding == "json")
        #expect(result.error == nil)
        let summary = result.summary
        #expect(summary?.first(where: { $0.0 == "kind" })?.1 == .string("flagged"))
        #expect(summary?.first(where: { $0.0 == "supported" })?.1 == .bool(true))
        #expect(summary?.first(where: { $0.0 == "description" })?.1 == .string("Flagged reminders"))
    }

    @Test func roundTripPrioritiesFilter() {
        let payload = JSONValue.object([
            ("priorities", .array([.string("high"), .string("medium")])),
        ])
        let json = payload.serialized(indent: nil, ensureAscii: false, spaceSeparators: false)
        #expect(json == #"{"priorities":["high","medium"]}"#)
        let result = decodeSmartListFilterBlob(Data(json.utf8))
        #expect(result.encoding == "json")
        #expect(result.error == nil)
        let summary = result.summary
        #expect(summary?.first(where: { $0.0 == "kind" })?.1 == .string("priority"))
        #expect(summary?.first(where: { $0.0 == "supported" })?.1 == .bool(true))
        #expect(summary?.first(where: { $0.0 == "description" })?.1 == .string("Priority: high, medium"))
    }

    @Test func roundTripCompoundFilter() {
        // {"operation":"or","flagged":true,"priorities":["low"]}
        let payload = JSONValue.object([
            ("operation", .string("or")),
            ("flagged", .bool(true)),
            ("priorities", .array([.string("low")])),
        ])
        let json = payload.serialized(indent: nil, ensureAscii: false, spaceSeparators: false)
        #expect(json == #"{"operation":"or","flagged":true,"priorities":["low"]}"#)
        let result = decodeSmartListFilterBlob(Data(json.utf8))
        #expect(result.encoding == "json")
        #expect(result.error == nil)
        // compound supported filter
        let summary = result.summary
        #expect(summary?.first(where: { $0.0 == "kind" })?.1 == .string("compound"))
        #expect(summary?.first(where: { $0.0 == "supported" })?.1 == .bool(true))
    }

    @Test func roundTripNonAsciiTagsFilter() {
        // Tags filter with non-ASCII tag name; ensure_ascii=False must preserve it
        let payload = JSONValue.object([
            ("hashtags", .object([
                ("hashtags", .object([
                    ("operation", .string("and")),
                    ("include", .array([.string("café")])),
                    ("exclude", .array([])),
                ])),
            ])),
        ])
        let json = payload.serialized(indent: nil, ensureAscii: false, spaceSeparators: false)
        // No \u-escapes; non-ASCII preserved; no spaces around separators
        #expect(!json.contains(": "))
        #expect(!json.contains(", "))
        #expect(json.contains("café"))
        let result = decodeSmartListFilterBlob(Data(json.utf8))
        #expect(result.encoding == "json")
        #expect(result.error == nil)
        #expect(result.summary?.first(where: { $0.0 == "kind" })?.1 == .string("tags"))
    }
}
