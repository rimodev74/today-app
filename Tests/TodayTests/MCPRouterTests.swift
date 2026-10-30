import Foundation
import SwiftData
import XCTest

@testable import Today

@MainActor
final class MCPRouterTests: XCTestCase {
  private var context: ModelContext!
  private var forgotten: [[String]] = []
  private var removedCovers: [UUID] = []

  override func setUpWithError() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    context = ModelContext(try ModelContainer(for: schema, configurations: config))
    forgotten = []
    removedCovers = []
  }

  private var router: MCPRouter {
    MCPRouter(
      context: context,
      effects: MCPEffects(
        forgetAppleItems: { [unowned self] in forgotten.append($0) },
        removeCover: { [unowned self] in removedCovers.append($0) }))
  }

  private func rpc(_ method: String, _ params: JSONValue = .object([:])) -> JSONValue? {
    router.handle(
      .object([
        "jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params,
      ]))
  }

  /// Appelle un outil et rend (charge utile décodée, isError).
  @discardableResult
  private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> (JSONValue, Bool) {
    let response = rpc(
      "tools/call", .object(["name": .string(name), "arguments": .object(args)]))
    let result = response?["result"]
    let text = result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? "null"
    let payload =
      (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .string(text)
    return (payload, result?["isError"]?.boolValue ?? false)
  }

  private func count<T: PersistentModel>(_ type: T.Type) -> Int {
    (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
  }

  private func makeProject(_ title: String = "Monflix") -> String {
    call("create_project", ["title": .string(title)]).0["id"]!.stringValue!
  }

  private func makeList(_ project: String, _ title: String = "Phase 1") -> String {
    call("create_list", ["project_id": .string(project), "title": .string(title)]).0["id"]!
      .stringValue!
  }

  // MARK: - Protocole

  func testInitializeEchoesProtocolVersion() {
    let result = rpc("initialize", .object(["protocolVersion": .string("2025-06-18")]))?["result"]
    XCTAssertEqual(result?["protocolVersion"]?.stringValue, "2025-06-18")
    XCTAssertNotNil(result?["capabilities"]?["tools"])
    XCTAssertEqual(result?["serverInfo"]?["name"]?.stringValue, "Today")
  }

  func testNotificationReturnsNil() {
    let response = router.handle(
      .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
    XCTAssertNil(response)
  }

  func testUnknownMethodIsMinus32601() {
    XCTAssertEqual(rpc("nope")?["error"]?["code"], .number(-32601))
  }

  func testToolsListNamesAllEight() {
    let tools = rpc("tools/list")?["result"]?["tools"]?.arrayValue ?? []
    let names = Set(tools.compactMap { $0["name"]?.stringValue })
    XCTAssertEqual(
      names,
      [
        "list_projects", "get_project", "create_project", "create_list", "create_task",
        "add_subtask", "update_item", "delete_item",
      ])
    let delete = tools.first { $0["name"]?.stringValue == "delete_item" }
    XCTAssertEqual(delete?["annotations"]?["destructiveHint"], .bool(true))
  }

  // MARK: - Création idempotente

  func testCreateProjectIsIdempotentByTitle() {
    let (first, _) = call("create_project", ["title": .string("Monflix")])
    let (second, _) = call("create_project", ["title": .string("  monflix ")])
    XCTAssertEqual(first["id"], second["id"])
    XCTAssertEqual(first["created"], .bool(true))
    XCTAssertEqual(second["created"], .bool(false))
    XCTAssertEqual(count(Project.self), 1)
  }

  func testCreateListTaskSubtaskIdempotent() {
    let project = makeProject()
    for _ in 0..<2 {
      let list = makeList(project)
      let task = call(
        "create_task",
        [
          "list_id": .string(list), "title": .string("Lecteur vidéo"),
          "subtasks": .array([.string("a"), .string("b")]),
        ]
      ).0["id"]!.stringValue!
      call("add_subtask", ["task_id": .string(task), "title": .string("A")])
    }
    XCTAssertEqual(count(TodoList.self), 1)
    XCTAssertEqual(count(TaskItem.self), 1)
    XCTAssertEqual(count(Subtask.self), 2)
    let task = try! context.fetch(FetchDescriptor<TaskItem>()).first!
    XCTAssertEqual(task.orderedSubtasks.map(\.title), ["a", "b"])
  }

  // MARK: - Lecture

  func testGetProjectTree() {
    let project = makeProject()
    let list = makeList(project)
    call(
      "create_task",
      [
        "list_id": .string(list), "title": .string("Un"), "notes": .string("détail"),
        "subtasks": .array([.string("s1")]),
      ])
    call("create_task", ["list_id": .string(list), "title": .string("Deux")])
    let (tree, isError) = call("get_project", ["project_id": .string(project)])
    XCTAssertFalse(isError)
    let lists = tree["lists"]?.arrayValue ?? []
    XCTAssertEqual(lists.count, 1)
    let tasks = lists[0]["tasks"]?.arrayValue ?? []
    XCTAssertEqual(tasks.compactMap { $0["title"]?.stringValue }, ["Un", "Deux"])
    XCTAssertEqual(tasks[0]["completed"], .bool(false))
    XCTAssertEqual(tasks[0]["is_header"], .bool(false))
    XCTAssertEqual(tasks[0]["notes"]?.stringValue, "détail")
    XCTAssertEqual(tasks[0]["subtasks"]?.arrayValue?.first?["done"], .bool(false))
  }

  func testListProjectsIncludesInbox() {
    let inbox = TodoList(title: "Tâches")
    inbox.isInbox = true
    context.insert(inbox)
    _ = makeProject()
    let (payload, _) = call("list_projects")
    XCTAssertEqual(payload["inbox"]?["id"]?.stringValue, inbox.uuid.uuidString)
    XCTAssertEqual(payload["projects"]?.arrayValue?.count, 1)
  }

  // MARK: - Modification

  func testUpdateItemCompletesTask() {
    let list = makeList(makeProject())
    let id = call("create_task", ["list_id": .string(list), "title": .string("T")]).0["id"]!
    call("update_item", ["id": id, "completed": .bool(true)])
    let task = try! context.fetch(FetchDescriptor<TaskItem>()).first!
    XCTAssertTrue(task.isCompleted)
    XCTAssertNotNil(task.completedAt)
    call("update_item", ["id": id, "completed": .bool(false)])
    XCTAssertFalse(task.isCompleted)
    XCTAssertNil(task.completedAt)

    let sub = task.addSubtask()
    call("update_item", ["id": .string(sub.uuid.uuidString), "completed": .bool(true)])
    XCTAssertTrue(sub.isDone)
  }

  func testUpdateItemNotesRoundTrip() {
    let list = makeList(makeProject())
    let id = call("create_task", ["list_id": .string(list), "title": .string("T")]).0["id"]!
    call("update_item", ["id": id, "notes": .string("x"), "title": .string("T2")])
    let task = try! context.fetch(FetchDescriptor<TaskItem>()).first!
    XCTAssertEqual(NotesCodec.plainText(task.notes), "x")
    XCTAssertEqual(task.title, "T2")
  }

  // MARK: - Erreurs

  func testUnknownIdIsToolError() {
    let (_, isError) = call(
      "create_list", ["project_id": .string(UUID().uuidString), "title": .string("L")])
    XCTAssertTrue(isError)
    XCTAssertEqual(count(TodoList.self), 0)
  }

  func testWrongTypeIdIsToolError() {
    let list = makeList(makeProject())
    let task = call("create_task", ["list_id": .string(list), "title": .string("T")]).0["id"]!
    let (_, isError) = call("create_task", ["list_id": task, "title": .string("X")])
    XCTAssertTrue(isError)
    XCTAssertEqual(count(TaskItem.self), 1)
  }
}
