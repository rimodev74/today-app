import Foundation
import SwiftData

/// **PHOTO FIGÉE de la forme du store au 1er août 2026.** Ne se modifie JAMAIS.
///
/// `CurrentSchema`, côté app, décrit ce que le CODE dit aujourd'hui — par une flèche vers les
/// modèles vivants. Ce fichier-ci décrit l'autre moitié : ce que contiennent réellement les BASES
/// déjà sur les disques. Les deux doivent rester d'accord, et rien dans SwiftData ne le vérifie ;
/// c'est le rôle de `SchemaCompatibilityTests`, qui les confronte à chaque `swift test`.
///
/// C'est une comptabilité en partie double : la forme est écrite deux fois, par deux chemins
/// indépendants, et un écart entre les deux est précisément l'erreur qu'on veut voir. La redondance
/// n'est pas un doublon à factoriser — elle EST la propriété de sûreté.
///
/// Les copies sont IMBRIQUÉES dans l'enum, donc indépendantes du code vivant : modifier `TaskItem`
/// ne les touche pas. Vérifié : imbriquer un `@Model` ne change pas l'entité de store qu'il décrit —
/// ces classes relisent sans perte un fichier écrit par les modèles de premier niveau, relations
/// comprises.
///
/// Elles vivent dans la cible de TESTS et pas dans `Sources` tant qu'aucune migration n'en a besoin
/// à l'exécution : l'app n'en a aucun usage, et quatre `@Model` de plus dans le binaire ne
/// serviraient qu'à semer le doute sur lesquels sont les vrais. Le jour où une version devient
/// PASSÉE, elles déménagent telles quelles dans `Models/TodaySchema.swift` sous le nom `SchemaV1`
/// (mode d'emploi dans ce fichier-là) — et ce fichier-ci se re-fige sur la nouvelle forme déployée.
enum SchemaV1Snapshot: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }

  @Model final class Project {
    var title: String = ""
    var notes: Data = Data()
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    var isCollapsed: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \TodoList.project) var lists: [TodoList] = []

    init() {}
  }

  @Model final class TodoList {
    var title: String = ""
    var notes: Data = Data()
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    var scheduledWhen: Date?
    var priorityRaw: Int = 0
    var project: Project?
    var isInbox: Bool = false
    @Relationship(deleteRule: .cascade, inverse: \TaskItem.list) var tasks: [TaskItem] = []

    init() {}
  }

  @Model final class TaskItem {
    var title: String = ""
    var notes: Data = Data()
    var isCompleted: Bool = false
    var isHeader: Bool = false
    var completedAt: Date?
    var sortIndex: Int = 0
    var when: Date?
    var hasTime: Bool = false
    var deadline: Date?
    var priorityRaw: Int = 0
    var estimateMinutes: Int = 0
    var createdAt: Date = Date()
    var reminderIdentifier: String?
    var list: TodoList?
    var headerColorRaw: String?
    @Relationship(deleteRule: .cascade, inverse: \Subtask.task) var subtasks: [Subtask] = []

    init() {}
  }

  @Model final class Subtask {
    var uuid: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    var task: TaskItem?

    init() {}
  }
}
