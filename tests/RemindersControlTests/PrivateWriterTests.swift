import XCTest
@testable import RemindersControl

final class PrivateWriterTests: XCTestCase {

    // MARK: - PrivateResult

    func testPrivateResultDefaults() {
        let r = PrivateResult(status: "updated")
        XCTAssertEqual(r.status, "updated")
        XCTAssertEqual(r.fields, [:])
        XCTAssertNil(r.message)
    }

    func testPrivateResultWithFieldsAndMessage() {
        let r = PrivateResult(status: "error", fields: ["id": .string("X")], message: "not found")
        XCTAssertEqual(r.status, "error")
        XCTAssertEqual(r.fields["id"], .string("X"))
        XCTAssertEqual(r.message, "not found")
    }

    func testPrivateResultEquality() {
        let a = PrivateResult(status: "created", fields: ["name": .string("Groceries")])
        let b = PrivateResult(status: "created", fields: ["name": .string("Groceries")])
        let c = PrivateResult(status: "deleted")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - ListAppearance.isEmpty

    func testListAppearanceIsEmptyWhenAllNil() {
        XCTAssertTrue(ListAppearance().isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenNameSet() {
        XCTAssertFalse(ListAppearance(name: "Groceries").isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenColorSet() {
        XCTAssertFalse(ListAppearance(color: "red").isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenSymbolSet() {
        XCTAssertFalse(ListAppearance(symbol: "cart").isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenEmojiSet() {
        XCTAssertFalse(ListAppearance(emoji: "🛒").isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenGroceryFlagSet() {
        XCTAssertFalse(ListAppearance(shouldCategorizeGroceryItems: true).isEmpty)
    }

    func testListAppearanceIsNotEmptyWhenLocaleSet() {
        XCTAssertFalse(ListAppearance(groceryLocaleID: "en_US").isEmpty)
    }

    func testListAppearanceEquality() {
        let a = ListAppearance(name: "Work", color: "blue")
        let b = ListAppearance(name: "Work", color: "blue")
        let c = ListAppearance(name: "Work", color: "green")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - SubtaskSpec equality

    func testSubtaskSpecEquality() {
        let a = SubtaskSpec(title: "Buy milk", tags: ["grocery"], flagged: true)
        let b = SubtaskSpec(title: "Buy milk", tags: ["grocery"], flagged: true)
        let c = SubtaskSpec(title: "Buy eggs")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSubtaskSpecDefaults() {
        let s = SubtaskSpec(title: "Task")
        XCTAssertEqual(s.title, "Task")
        XCTAssertNil(s.notes)
        XCTAssertNil(s.due)
        XCTAssertTrue(s.urls.isEmpty)
        XCTAssertTrue(s.tags.isEmpty)
        XCTAssertTrue(s.images.isEmpty)
        XCTAssertNil(s.flagged)
        XCTAssertNil(s.urgent)
        XCTAssertNil(s.latitude)
        XCTAssertNil(s.proximity)
    }

    // MARK: - EarlyReminderWrite equality

    func testEarlyReminderWriteEquality() {
        XCTAssertEqual(EarlyReminderWrite.clear(existingIdentifiers: ["A"]),
                       EarlyReminderWrite.clear(existingIdentifiers: ["A"]))
        XCTAssertNotEqual(EarlyReminderWrite.clear(existingIdentifiers: ["A"]),
                          EarlyReminderWrite.clear(existingIdentifiers: ["B"]))
        XCTAssertEqual(EarlyReminderWrite.set(unit: 1, count: -2, existingIdentifiers: []),
                       EarlyReminderWrite.set(unit: 1, count: -2, existingIdentifiers: []))
        XCTAssertNotEqual(EarlyReminderWrite.set(unit: 1, count: -2, existingIdentifiers: []),
                          EarlyReminderWrite.set(unit: 2, count: -2, existingIdentifiers: []))
    }

    // MARK: - MockPrivateWriter call recording

    func testSetFlaggedRecordsCall() async throws {
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "updated", fields: ["id": .string("X")])
        let result = try await mock.setFlagged(id: "X", flagged: true)
        XCTAssertEqual(mock.calls, [.setFlagged(id: "X", flagged: true)])
        XCTAssertEqual(result, PrivateResult(status: "updated", fields: ["id": .string("X")]))
    }

    func testSetUrgentRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setUrgent(id: "R1", urgent: false)
        XCTAssertEqual(mock.calls, [.setUrgent(id: "R1", urgent: false)])
    }

    func testAddPrivateMetadataRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.addPrivateMetadata(id: "R2", urls: ["https://example.com"], tags: ["work"])
        XCTAssertEqual(mock.calls, [.addPrivateMetadata(id: "R2", urls: ["https://example.com"], tags: ["work"])])
    }

    func testAssignSectionRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.assignSection(id: "R3", sectionId: "S1")
        XCTAssertEqual(mock.calls, [.assignSection(id: "R3", sectionId: "S1")])
    }

    func testAddSectionAndAssignRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.addSectionAndAssign(id: "R4", name: "Morning")
        XCTAssertEqual(mock.calls, [.addSectionAndAssign(id: "R4", name: "Morning")])
    }

    func testAddSubtasksRecordsCall() async throws {
        let mock = MockPrivateWriter()
        let subtasks = [SubtaskSpec(title: "Step 1"), SubtaskSpec(title: "Step 2", flagged: true)]
        _ = try await mock.addSubtasks(id: "R5", subtasks: subtasks)
        XCTAssertEqual(mock.calls, [.addSubtasks(id: "R5", subtasks: subtasks)])
    }

    func testAddAttachmentsRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.addAttachments(id: "R6", images: ["/tmp/photo.jpg"])
        XCTAssertEqual(mock.calls, [.addAttachments(id: "R6", images: ["/tmp/photo.jpg"])])
    }

    func testSetEarlyReminderClearRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setEarlyReminder(id: "R7", spec: .clear(existingIdentifiers: ["A", "B"]))
        XCTAssertEqual(mock.calls, [.setEarlyReminder(id: "R7", spec: .clear(existingIdentifiers: ["A", "B"]))])
    }

    func testSetEarlyReminderSetRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setEarlyReminder(id: "R8", spec: .set(unit: 2, count: -1, existingIdentifiers: []))
        XCTAssertEqual(mock.calls, [.setEarlyReminder(id: "R8", spec: .set(unit: 2, count: -1, existingIdentifiers: []))])
    }

    func testAddLocationAlarmRecordsCall() async throws {
        let mock = MockPrivateWriter()
        let loc = PrivateLocation(title: "Home", latitude: 37.7, longitude: -122.4, radius: 100, proximity: 1)
        _ = try await mock.addLocationAlarm(id: "R9", location: loc)
        XCTAssertEqual(mock.calls, [.addLocationAlarm(id: "R9", location: loc)])
    }

    func testCategorizeGroceryItemsRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.categorizeGroceryItems(listId: "L1", reminderIds: ["R1", "R2"])
        XCTAssertEqual(mock.calls, [.categorizeGroceryItems(listId: "L1", reminderIds: ["R1", "R2"])])
    }

    func testSetListAppearanceRecordsCall() async throws {
        let mock = MockPrivateWriter()
        let appearance = ListAppearance(color: "blue", symbol: "cart")
        _ = try await mock.setListAppearance(listId: "L2", appearance: appearance)
        XCTAssertEqual(mock.calls, [.setListAppearance(listId: "L2", appearance: appearance)])
    }

    func testSetListPinnedRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setListPinned(listId: "L3", pinned: true)
        XCTAssertEqual(mock.calls, [.setListPinned(listId: "L3", pinned: true)])
    }

    func testSetSmartListPinnedRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setSmartListPinned(smartListId: "SL1", pinned: false)
        XCTAssertEqual(mock.calls, [.setSmartListPinned(smartListId: "SL1", pinned: false)])
    }

    func testCreateListRecordsCall() async throws {
        let mock = MockPrivateWriter()
        mock.result = PrivateResult(status: "created", fields: ["id": .string("NEW")])
        let appearance = ListAppearance(name: "Shopping", emoji: "🛒")
        let result = try await mock.createList(name: "Shopping", appearance: appearance)
        XCTAssertEqual(mock.calls, [.createList(name: "Shopping", appearance: appearance)])
        XCTAssertEqual(result.status, "created")
        XCTAssertEqual(result.fields["id"], .string("NEW"))
    }

    func testCreateSmartListRecordsCallWithFilterData() async throws {
        let mock = MockPrivateWriter()
        let filterData = Data([0x01, 0x02, 0x03])
        let appearance = ListAppearance(name: "Flagged", color: "orange")
        _ = try await mock.createSmartList(name: "Flagged", filterData: filterData, appearance: appearance)
        XCTAssertEqual(mock.calls, [.createSmartList(name: "Flagged", filterData: filterData, appearance: appearance)])
    }

    func testUpdateSmartListRecordsCall() async throws {
        let mock = MockPrivateWriter()
        let filterData = Data([0xAB, 0xCD])
        _ = try await mock.updateSmartList(smartListId: "SL2", filterData: filterData, appearance: ListAppearance())
        XCTAssertEqual(mock.calls, [.updateSmartList(smartListId: "SL2", filterData: filterData, appearance: ListAppearance())])
    }

    func testUpdateSmartListWithNilFilterDataRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.updateSmartList(smartListId: "SL3", filterData: nil, appearance: ListAppearance(color: "red"))
        XCTAssertEqual(mock.calls, [.updateSmartList(smartListId: "SL3", filterData: nil, appearance: ListAppearance(color: "red"))])
    }

    func testDeleteSmartListRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.deleteSmartList(smartListId: "SL4")
        XCTAssertEqual(mock.calls, [.deleteSmartList(smartListId: "SL4")])
    }

    func testCreateTemplateRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.createTemplate(name: "Weekly Review", sourceListId: "L4", includeCompleted: false)
        XCTAssertEqual(mock.calls, [.createTemplate(name: "Weekly Review", sourceListId: "L4", includeCompleted: false)])
    }

    func testApplyTemplateRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.applyTemplate(templateId: "T1")
        XCTAssertEqual(mock.calls, [.applyTemplate(templateId: "T1")])
    }

    func testDeleteTemplateRecordsCall() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.deleteTemplate(templateId: "T2")
        XCTAssertEqual(mock.calls, [.deleteTemplate(templateId: "T2")])
    }

    // MARK: - Multiple calls accumulate in order

    func testMultipleCallsAccumulate() async throws {
        let mock = MockPrivateWriter()
        _ = try await mock.setFlagged(id: "A", flagged: true)
        _ = try await mock.setUrgent(id: "B", urgent: false)
        _ = try await mock.deleteSmartList(smartListId: "SL5")
        XCTAssertEqual(mock.calls, [
            .setFlagged(id: "A", flagged: true),
            .setUrgent(id: "B", urgent: false),
            .deleteSmartList(smartListId: "SL5"),
        ])
    }

    // MARK: - throwError propagates

    func testThrowErrorPropagatesFromSetFlagged() async throws {
        struct TestError: Error, Equatable {}
        let mock = MockPrivateWriter()
        mock.throwError = TestError()
        do {
            _ = try await mock.setFlagged(id: "X", flagged: true)
            XCTFail("Expected error to be thrown")
        } catch is TestError {
            // expected
        }
        // call is recorded before the error is thrown (mirrors MockWriter convention)
        XCTAssertEqual(mock.calls, [.setFlagged(id: "X", flagged: true)])
    }

    func testThrowErrorPropagatesFromCreateSmartList() async throws {
        struct TestError: Error {}
        let mock = MockPrivateWriter()
        mock.throwError = TestError()
        do {
            _ = try await mock.createSmartList(name: "X", filterData: Data(), appearance: ListAppearance())
            XCTFail("Expected error to be thrown")
        } catch is TestError {
            // expected
        }
        // call is recorded before the error is thrown (mirrors MockWriter convention)
        XCTAssertEqual(mock.calls, [.createSmartList(name: "X", filterData: Data(), appearance: ListAppearance())])
    }
}
