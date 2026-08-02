import Foundation
import SwiftData

/// Le schéma COURANT : ce que le code décrit *maintenant*, estampillé d'un numéro de version.
///
/// `models` est une FLÈCHE vers les classes vivantes, pas une copie — et c'est voulu : le schéma
/// courant, par définition, est ce que les modèles disent aujourd'hui. D'où le nom : rien ici ne
/// prétend décrire une version passée. Les versions passées, elles, sont figées (cf. plus bas).
///
/// Corollaire à connaître : `versionIdentifier` ne se met PAS à jour tout seul. Modifier un
/// `@Model` sans toucher ce numéro redéfinit silencieusement ce que « 1.0.0 » veut dire, pendant
/// que la base sur disque, elle, n'a pas bougé. Deux issues, aucune bruyante :
///
/// - changement ADDITIF (champ optionnel ou à valeur par défaut) → SwiftData migre seul, rien à
///   faire, et c'est le cas courant ;
/// - changement CASSANT (renommer, supprimer, changer un type) → **la donnée part sans un mot**.
///   Mesuré sur cette app : renommer un champ stocké laisse `swift build` passer, laisse le store
///   s'ouvrir SANS erreur, et vide la colonne (SwiftData lit un renommage comme « supprime
///   l'ancien, ajoute le neuf »). Pas de quarantaine, pas d'alerte — juste des dates devenues nil.
///
/// Aucune API ne prévient de ça : la chaîne de versions de SwiftData sait TRANSPORTER une donnée
/// d'une forme à l'autre, elle ne sait pas REPÉRER qu'on a changé de forme sans le dire. C'est donc
/// à nous, et ça tient en une contrepartie écrite : la forme réellement présente sur les disques est
/// figée dans `Tests/TodayTests/SchemaV1Snapshot.swift`, et `SchemaCompatibilityTests` vérifie à
/// chaque `swift test` que `CurrentSchema` sait encore relire une base écrite à cette forme-là.
/// Tant que ce test est vert, l'estampille 1.0.0 est légitime. Rouge = elle ment, ne pas lancer
/// l'app avant d'avoir suivi la marche ci-dessous.
enum CurrentSchema: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }
}

/// **Forme 1.0.0, FIGÉE — ne se modifie plus jamais.** C'est ce que contiennent les bases écrites
/// avant le 2 août 2026, et la seule description qui en reste : les modèles vivants, eux, ont
/// changé.
///
/// Elle ne diffère de la forme courante que par `TaskItem.hasTime`, un booléen que rien n'a jamais
/// mis à vrai (l'app ne pose que des jours, jamais d'heures). Le retirer est un changement CASSANT
/// au sens de SwiftData — d'où cette version et l'étape ci-dessous, sans quoi la colonne serait
/// partie en silence, ce que `SchemaCompatibilityTests` aurait viré au rouge.
///
/// Les classes sont IMBRIQUÉES dans l'enum, donc indépendantes du code vivant : modifier `TaskItem`
/// ne les touche pas, et c'est ce qui leur permet de continuer à décrire l'ancienne forme.
/// Vérifié : imbriquer un `@Model` ne change pas l'entité de store qu'il décrit — une base écrite
/// par les modèles de premier niveau s'y relit sans perte, relations comprises.
enum SchemaV1: VersionedSchema {
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
    var smartOrder: Int = 0
    var when: Date?
    /// LE champ retiré en 2.0.0. Il reste ici parce qu'il est sur les disques.
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

/// Chaîne de migration de l'app : les formes PASSÉES, dans l'ordre, puis la forme courante.
///
/// Vide de versions passées pour l'instant — personne n'a encore de base à une autre forme que
/// celle d'aujourd'hui. Le plan existe déjà pour que la première migration soit un ajout et pas un
/// socle à inventer dans l'urgence.
///
/// ## Le jour où un changement cassant l'exige
///
/// 1. Déplacer `SchemaV1Snapshot` (cible de tests) ici, renommé `SchemaV1`. Ses types sont
///    IMBRIQUÉS dans l'enum, donc indépendants du code vivant : c'est ce qui lui permet de
///    continuer à décrire l'ANCIENNE forme une fois les modèles modifiés. Vérifié : imbriquer un
///    `@Model` ne change pas l'entité de store qu'il décrit — une base écrite par les modèles de
///    premier niveau s'y relit sans perte, relations comprises.
/// 2. Modifier librement les modèles vivants, puis monter `CurrentSchema.versionIdentifier` à
///    2.0.0. Il n'y a JAMAIS de `SchemaV2` figée : la forme courante n'est décrite qu'une fois,
///    par les modèles eux-mêmes. On ne fige une version qu'au moment où elle devient passée.
/// 3. `schemas = [SchemaV1.self, CurrentSchema.self]`.
/// 4. `stages = [.lightweight(...)]` si le changement est additif, `.custom(...)` s'il faut
///    transporter de la donnée d'un champ à l'autre — c'est le cas d'un renommage, et c'est LUI qui
///    sauve les valeurs que SwiftData jetterait sinon.
/// 5. Re-figer la nouvelle forme dans `SchemaV1Snapshot` (qui garde son rôle : « ce que contiennent
///    les disques »), et rendre `SchemaCompatibilityTests` vert.
///
/// Le test, lui, ne change jamais de nature : il vérifie toujours qu'une base au format déployé
/// s'ouvre par `TodayApp.openStore`. C'est ce qui rend l'ajout d'une version mécanique.
enum TodayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, CurrentSchema.self] }

  /// `.lightweight` et pas `.custom` : la 2.0.0 ne fait que RETIRER `hasTime`, elle ne transporte
  /// aucune valeur d'un champ vers un autre. Une étape sur mesure ne servirait qu'à recopier ce
  /// booléen quelque part — or il vaut faux partout, c'est toute la raison de sa suppression.
  static var stages: [MigrationStage] {
    [.lightweight(fromVersion: SchemaV1.self, toVersion: CurrentSchema.self)]
  }
}
