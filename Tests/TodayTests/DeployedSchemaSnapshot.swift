import Foundation
import SwiftData

/// **PHOTO FIGÉE de la forme DÉPLOYÉE du store — schéma 2.0.0, 2 août 2026.** Ne se modifie que
/// quand la forme déployée change, et alors dans le même geste que les modèles vivants — jamais
/// pour faire taire un test.
///
/// S'appelait `SchemaV1Snapshot` tant qu'il n'existait qu'une forme. Le nom aurait menti dès la
/// 2.0.0 : ce fichier ne décrit pas la version 1, il décrit *celle qui est déployée*, quel que soit
/// son numéro. Les formes PASSÉES, elles, vivent dans `Models/TodaySchema.swift` (`SchemaV1`),
/// parce que la migration en a besoin à l'exécution — pas seulement les tests.
///
/// Historique des retouches :
/// - `TaskItem.smartOrder`, 2 août 2026 — ajout PUR, absorbé par SwiftData sans étape de migration.
/// - `TaskItem.hasTime` RETIRÉ, 2 août 2026 — changement CASSANT, d'où `SchemaV1` et son étape.
/// - `Project.colorRaw`, 3 août 2026 — ajout PUR (optionnel), et pourtant 3.0.0 avec son étape.
///   Retoucher ce fichier SANS monter `CurrentSchema.versionIdentifier` ni déclarer l'étape rend ce
///   test VERT alors que l'app ne s'ouvre plus : le test fabrique sa base à la forme d'ici, donc
///   une base déjà migrée, quand les vrais disques, eux, portent l'ancienne. C'est arrivé — la
///   vraie base est partie en quarantaine. Ce fichier se retouche en DERNIER, jamais en premier.
/// - `uuid` sur `Project`, `TodoList` et `TaskItem` + valeurs par défaut partout, 3 août 2026 —
///   4.0.0, préparation de la synchro entre appareils. Ajout pur, mais étape `.custom` : les
///   identités existantes doivent être TIRÉES une par une (cf. `TodayMigrationPlan`).
/// - `TaskItem.whenMinutes`, 5 août 2026 — l'heure d'une tâche datée, ajout PUR (optionnel), étape
///   `.lightweight`. Une tâche d'avant n'avait pas d'heure et n'en a toujours pas : `nil` partout.
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
enum DeployedSchemaSnapshot: VersionedSchema {
  static let versionIdentifier = Schema.Version(5, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }

  @Model final class Project {
    var uuid: UUID = UUID()
    var title: String = ""
    var notes: Data = Data()
    var sortIndex: Int = 0
    var createdAt: Date = Date()
    var isCollapsed: Bool = false
    var colorRaw: String?
    @Relationship(deleteRule: .cascade, inverse: \TodoList.project) var lists: [TodoList] = []

    init() {}
  }

  @Model final class TodoList {
    var uuid: UUID = UUID()
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
    var uuid: UUID = UUID()
    var title: String = ""
    var notes: Data = Data()
    var isCompleted: Bool = false
    var isHeader: Bool = false
    var completedAt: Date?
    var sortIndex: Int = 0
    var smartOrder: Int = 0
    var when: Date?
    var whenMinutes: Int?
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
