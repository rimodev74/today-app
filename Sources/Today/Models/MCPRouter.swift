import Foundation
import SwiftData

/// Ce que le MCP déclenche HORS de SwiftData, après un enregistrement réussi. Passé de l'extérieur
/// parce que `Models/` ne connaît ni `RemindersService` ni `ProjectCovers` — même raison que le
/// `forget` sans valeur par défaut de `TodoList.delete`.
struct MCPEffects {
  let forgetAppleItems: ([String]) -> Void
  let removeCover: (UUID) -> Void
}

/// Le serveur MCP de Today, moins le réseau : JSON-RPC en entrée, JSON-RPC en sortie, écritures sur
/// le contexte de l'interface (sinon l'app ne verrait pas ce que Claude crée).
///
/// Identifiants exposés = les `uuid` des modèles : stables, contrairement à `persistentModelID`.
/// Créer est IDEMPOTENT par titre dans le parent : relancer une synchro ne duplique rien.
@MainActor
struct MCPRouter {
  let context: ModelContext
  let effects: MCPEffects

  init(context: ModelContext, effects: MCPEffects) {
    self.context = context
    self.effects = effects
  }

  /// `nil` pour une notification (pas d'`id`) : rien à répondre.
  func handle(_ request: JSONValue) -> JSONValue? {
    guard let id = request["id"] else { return nil }
    let method = request["method"]?.stringValue ?? ""
    let params = request["params"] ?? .object([:])
    switch method {
    case "initialize":
      return reply(id, initializeResult(params))
    case "ping":
      return reply(id, .object([:]))
    case "tools/list":
      return reply(id, .object(["tools": .array(Self.catalog)]))
    case "tools/call":
      guard let name = params["name"]?.stringValue else {
        return failure(id, code: -32602, "params.name manquant")
      }
      return reply(id, callTool(name, params["arguments"] ?? .object([:])))
    default:
      return failure(id, code: -32601, "Méthode inconnue : \(method)")
    }
  }

  // MARK: - JSON-RPC

  private func reply(_ id: JSONValue, _ result: JSONValue) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
  }

  private func failure(_ id: JSONValue, code: Double, _ message: String) -> JSONValue {
    .object([
      "jsonrpc": .string("2.0"), "id": id,
      "error": .object(["code": .number(code), "message": .string(message)]),
    ])
  }

  private func initializeResult(_ params: JSONValue) -> JSONValue {
    // On renvoie la version proposée : aucun outil ne dépend d'une fonction propre à une version.
    let version = params["protocolVersion"]?.stringValue ?? "2025-06-18"
    return .object([
      "protocolVersion": .string(version),
      "capabilities": .object(["tools": .object([:])]),
      "serverInfo": .object(["name": .string("Today"), "version": .string("1.0")]),
      "instructions": .string(Self.instructions),
    ])
  }

  // MARK: - Outils

  private struct ToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
  }

  private func callTool(_ name: String, _ args: JSONValue) -> JSONValue {
    do {
      let payload: JSONValue
      switch name {
      case "list_projects": payload = listProjects()
      case "get_project": payload = try getProject(args)
      case "create_project": payload = try createProject(args)
      case "create_list": payload = try createList(args)
      case "create_task": payload = try createTask(args)
      case "add_subtask": payload = try addSubtask(args)
      case "update_item": payload = try updateItem(args)
      case "delete_item": payload = try deleteItem(args)
      default: throw ToolError("Outil inconnu : \(name)")
      }
      return toolResult(payload, isError: false)
    } catch let error as ToolError {
      return toolResult(.string(error.message), isError: true)
    } catch {
      return toolResult(.string("\(error)"), isError: true)
    }
  }

  private func toolResult(_ payload: JSONValue, isError: Bool) -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let text = (try? encoder.encode(payload)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    return .object([
      "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
      "isError": .bool(isError),
    ])
  }

  private func listProjects() -> JSONValue {
    let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    let ordered = sortedByKey(
      projects, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
    var payload: [String: JSONValue] = [
      "projects": .array(
        ordered.map { project in
          let lists = project.orderedLists.map(listSummary)
          return .object([
            "id": .string(project.uuid.uuidString),
            "title": .string(project.title),
            "lists": .array(lists),
          ])
        })
    ]
    let inbox = try? context.fetch(FetchDescriptor<TodoList>(predicate: #Predicate { $0.isInbox }))
      .first
    if let inbox { payload["inbox"] = listSummary(inbox) }
    return .object(payload)
  }

  /// Une passe sur les tâches de la liste : chaque lecture d'attribut traverse SwiftData.
  private func listSummary(_ list: TodoList) -> JSONValue {
    var done = 0
    var total = 0
    for task in list.tasks where !task.isHeader {
      total += 1
      if task.isCompleted { done += 1 }
    }
    return .object([
      "id": .string(list.uuid.uuidString),
      "title": .string(list.title),
      "archived": .bool(list.isArchived),
      "done": .number(Double(done)),
      "total": .number(Double(total)),
    ])
  }

  private func getProject(_ args: JSONValue) throws -> JSONValue {
    let project = try fetchProject(try uuid(args, "project_id"))
    return .object([
      "id": .string(project.uuid.uuidString),
      "title": .string(project.title),
      "lists": .array(
        project.orderedLists.map { list in
          .object([
            "id": .string(list.uuid.uuidString),
            "title": .string(list.title),
            "archived": .bool(list.isArchived),
            "tasks": .array(list.orderedTasks.map(taskTree)),
          ])
        }),
    ])
  }

  private func taskTree(_ task: TaskItem) -> JSONValue {
    .object([
      "id": .string(task.uuid.uuidString),
      "title": .string(task.title),
      "completed": .bool(task.isCompleted),
      "is_header": .bool(task.isHeader),
      "notes": .string(NotesCodec.decode(task.notes).string),
      "subtasks": .array(
        task.orderedSubtasks.map { sub in
          .object([
            "id": .string(sub.uuid.uuidString),
            "title": .string(sub.title),
            "done": .bool(sub.isDone),
          ])
        }),
    ])
  }

  private func createProject(_ args: JSONValue) throws -> JSONValue {
    let title = try nonEmpty(args, "title")
    let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
    if let existing = projects.first(where: { Self.sameTitle($0.title, title) }) {
      return created(existing.uuid, false)
    }
    let project = Project(title: title, notes: notes(args) ?? Data())
    project.sortIndex = (projects.map(\.sortIndex).max() ?? -1) + 1
    context.insertAndSave(project)
    return try saved(created(project.uuid, true))
  }

  private func createList(_ args: JSONValue) throws -> JSONValue {
    let project = try fetchProject(try uuid(args, "project_id"))
    let title = try nonEmpty(args, "title")
    if let existing = project.lists.first(where: { Self.sameTitle($0.title, title) }) {
      return created(existing.uuid, false)
    }
    let list = project.appendList(titled: title, in: context)
    return try saved(created(list.uuid, true))
  }

  private func createTask(_ args: JSONValue) throws -> JSONValue {
    let list = try fetchList(try uuid(args, "list_id"))
    let title = try nonEmpty(args, "title")
    if let existing = list.tasks.first(where: { !$0.isHeader && Self.sameTitle($0.title, title) }) {
      return created(existing.uuid, false)
    }
    let task = TaskItem(title: title, notes: notes(args) ?? Data(), list: list)
    task.sortIndex = (list.tasks.map(\.sortIndex).max() ?? -1) + 1
    context.insertAndSave(task)
    for case .string(let subtitle) in args["subtasks"]?.arrayValue ?? [] {
      let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { task.addSubtask().title = trimmed }
    }
    if args["completed"]?.boolValue == true { task.toggleCompletion() }
    return try saved(created(task.uuid, true))
  }

  private func addSubtask(_ args: JSONValue) throws -> JSONValue {
    let task = try fetchTask(try uuid(args, "task_id"))
    let title = try nonEmpty(args, "title")
    if let existing = task.subtasks.first(where: { Self.sameTitle($0.title, title) }) {
      return created(existing.uuid, false)
    }
    let subtask = task.addSubtask()
    subtask.title = title
    return try saved(created(subtask.uuid, true))
  }

  private func updateItem(_ args: JSONValue) throws -> JSONValue {
    let id = try uuid(args, "id")
    let title = try args["title"].map { _ in try nonEmpty(args, "title") }
    let completed = args["completed"]?.boolValue
    let newNotes = notes(args)
    if let task = fetch(TaskItem.self, #Predicate { $0.uuid == id }) {
      if let title { task.title = title }
      if let newNotes { task.notes = newNotes }
      if let completed, completed != task.isCompleted { task.toggleCompletion() }
    } else if let sub = fetch(Subtask.self, #Predicate { $0.uuid == id }) {
      if newNotes != nil { throw ToolError("Une sous-tâche n'a pas de notes.") }
      if let title { sub.title = title }
      if let completed { sub.isDone = completed }
    } else if let list = fetch(TodoList.self, #Predicate { $0.uuid == id }) {
      if completed != nil { throw ToolError("Une liste ne se coche pas.") }
      if let title { list.title = title }
      if let newNotes { list.notes = newNotes }
    } else if let project = fetch(Project.self, #Predicate { $0.uuid == id }) {
      if completed != nil { throw ToolError("Un projet ne se coche pas.") }
      if let title { project.title = title }
      if let newNotes { project.notes = newNotes }
    } else {
      throw ToolError("Aucun élément avec l'id \(id.uuidString).")
    }
    return try saved(.object(["id": .string(id.uuidString), "updated": .bool(true)]))
  }

  /// `deleteCascadeAndSave` pour les QUATRE types, tâche comprise : ce que le MCP supprime n'a
  /// peut-être jamais été rendu (des sous-tâches jamais lues), et c'est l'instantané manquant qui
  /// fait tomber SwiftData avec l'`UndoManager` branché. Identifiants Apple lus AVANT la mutation.
  private func deleteItem(_ args: JSONValue) throws -> JSONValue {
    let id = try uuid(args, "id")
    let ok: Bool
    if let project = fetch(Project.self, #Predicate { $0.uuid == id }) {
      ok = project.delete(
        in: context, forget: effects.forgetAppleItems, removeCover: effects.removeCover)
    } else if let list = fetch(TodoList.self, #Predicate { $0.uuid == id }) {
      // La boîte de réception est un singleton que l'app recrée au lancement : la supprimer
      // effacerait toutes les tâches non classées pour rien.
      if list.isInbox { throw ToolError("La boîte de réception ne se supprime pas.") }
      ok = cascade(list, apple: RemindersService.appleIdentifiers(of: list.tasks))
    } else if let task = fetch(TaskItem.self, #Predicate { $0.uuid == id }) {
      ok = cascade(task, apple: RemindersService.appleIdentifiers(of: [task]))
    } else if let sub = fetch(Subtask.self, #Predicate { $0.uuid == id }) {
      ok = cascade(sub, apple: [])
    } else {
      throw ToolError("Aucun élément avec l'id \(id.uuidString).")
    }
    guard ok else {
      throw ToolError("Enregistrement en échec : la suppression sera réessayée par l'app.")
    }
    return .object(["id": .string(id.uuidString), "deleted": .bool(true)])
  }

  private func cascade(_ model: some PersistentModel, apple: [String]) -> Bool {
    let forget = effects.forgetAppleItems
    guard context.deleteCascadeAndSave(model) else {
      if !apple.isEmpty { context.runAfterNextSave { forget(apple) } }
      return false
    }
    if !apple.isEmpty { forget(apple) }
    return true
  }

  // MARK: - Aides

  private func created(_ id: UUID, _ isNew: Bool) -> JSONValue {
    .object(["id": .string(id.uuidString), "created": .bool(isNew)])
  }

  /// Un enregistrement raté laisse les changements EN ATTENTE (l'autosave les écrira) : on le dit,
  /// sans rien annuler — cf. `saveReportingSuccess`.
  private func saved(_ payload: JSONValue) throws -> JSONValue {
    guard context.saveReportingSuccess() else {
      throw ToolError("Enregistrement en échec : la modification sera réessayée par l'app.")
    }
    return payload
  }

  /// Comparaison des titres pour l'idempotence : espaces de bord et casse ignorés.
  static func sameTitle(_ a: String, _ b: String) -> Bool {
    let clean = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
    return clean(a).caseInsensitiveCompare(clean(b)) == .orderedSame
  }

  private func uuid(_ args: JSONValue, _ key: String) throws -> UUID {
    guard let raw = args[key]?.stringValue, let id = UUID(uuidString: raw) else {
      throw ToolError("\(key) manquant ou invalide.")
    }
    return id
  }

  private func nonEmpty(_ args: JSONValue, _ key: String) throws -> String {
    let value = (args[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { throw ToolError("\(key) ne peut pas être vide.") }
    return value
  }

  private func notes(_ args: JSONValue) -> Data? {
    args["notes"]?.stringValue.map { NotesCodec.encode(NSAttributedString(string: $0)) }
  }

  private func fetch<T: PersistentModel>(_ type: T.Type, _ predicate: Predicate<T>) -> T? {
    var descriptor = FetchDescriptor<T>(predicate: predicate)
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  private func fetchProject(_ id: UUID) throws -> Project {
    guard let found = fetch(Project.self, #Predicate { $0.uuid == id }) else {
      throw ToolError("Aucun projet avec l'id \(id.uuidString).")
    }
    return found
  }

  private func fetchList(_ id: UUID) throws -> TodoList {
    guard let found = fetch(TodoList.self, #Predicate { $0.uuid == id }) else {
      throw ToolError("Aucune liste avec l'id \(id.uuidString).")
    }
    return found
  }

  private func fetchTask(_ id: UUID) throws -> TaskItem {
    guard let found = fetch(TaskItem.self, #Predicate { $0.uuid == id }) else {
      throw ToolError("Aucune tâche avec l'id \(id.uuidString).")
    }
    return found
  }

  // MARK: - Catalogue

  static let instructions = """
    Today est l'app de tâches de l'utilisateur. Hiérarchie : projet → liste → tâche → sous-tâche. \
    Pour suivre l'avancement d'un projet de code : une phase de roadmap = une liste, une ligne = \
    une tâche, un sous-point = une sous-tâche. Appelle get_project avant de synchroniser et garde \
    les id renvoyés. Les create_* sont idempotents par titre : les rejouer ne duplique rien. \
    N'agis sur Today que si l'utilisateur te l'a demandé.
    """

  private static func property(_ type: String, _ description: String) -> JSONValue {
    .object(["type": .string(type), "description": .string(description)])
  }

  private static func tool(
    _ name: String, _ description: String, _ properties: [String: JSONValue],
    required: [String], destructive: Bool = false, readOnly: Bool = false
  ) -> JSONValue {
    .object([
      "name": .string(name),
      "description": .string(description),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object(properties),
        "required": .array(required.map(JSONValue.string)),
      ]),
      "annotations": .object([
        "destructiveHint": .bool(destructive),
        "readOnlyHint": .bool(readOnly),
      ]),
    ])
  }

  static let catalog: [JSONValue] = [
    tool(
      "list_projects",
      "Liste les projets (ordre de la barre latérale) avec leurs listes et leur avancement "
        + "(done/total), plus la boîte de réception.",
      [:], required: [], readOnly: true),
    tool(
      "get_project",
      "Arbre complet d'un projet : listes → tâches (cochées, notes) → sous-tâches.",
      ["project_id": property("string", "id du projet")], required: ["project_id"],
      readOnly: true),
    tool(
      "create_project",
      "Crée un projet. Si un projet porte déjà ce titre, le renvoie sans rien créer.",
      ["title": property("string", "titre"), "notes": property("string", "notes, texte brut")],
      required: ["title"]),
    tool(
      "create_list",
      "Crée une liste en fin de projet. Idempotent par titre dans le projet.",
      ["project_id": property("string", "id du projet"), "title": property("string", "titre")],
      required: ["project_id", "title"]),
    tool(
      "create_task",
      "Crée une tâche en fin de liste, avec ses sous-tâches. Idempotent par titre dans la liste.",
      [
        "list_id": property("string", "id de la liste"),
        "title": property("string", "titre"),
        "notes": property("string", "notes, texte brut"),
        "subtasks": .object([
          "type": .string("array"), "items": .object(["type": .string("string")]),
          "description": .string("titres des sous-tâches, dans l'ordre"),
        ]),
        "completed": property("boolean", "déjà terminée"),
      ], required: ["list_id", "title"]),
    tool(
      "add_subtask",
      "Ajoute une sous-tâche en fin de tâche. Idempotent par titre dans la tâche.",
      ["task_id": property("string", "id de la tâche"), "title": property("string", "titre")],
      required: ["task_id", "title"]),
    tool(
      "update_item",
      "Modifie un projet, une liste, une tâche ou une sous-tâche : titre, notes (pas pour une "
        + "sous-tâche), completed (tâche et sous-tâche seulement).",
      [
        "id": property("string", "id de l'élément"),
        "title": property("string", "nouveau titre"),
        "notes": property("string", "nouvelles notes, texte brut"),
        "completed": property("boolean", "cocher ou décocher"),
      ], required: ["id"]),
    tool(
      "delete_item",
      "Supprime un projet, une liste (avec leur contenu), une tâche ou une sous-tâche. "
        + "UNIQUEMENT quand l'utilisateur l'a demandé explicitement dans la conversation. Jamais "
        + "pour nettoyer, dédoublonner ou réorganiser de ta propre initiative.",
      ["id": property("string", "id de l'élément")], required: ["id"], destructive: true),
  ]
}
