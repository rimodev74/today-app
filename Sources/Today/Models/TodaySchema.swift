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
  static let versionIdentifier = Schema.Version(5, 0, 0)

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

/// **Forme 2.0.0, FIGÉE — ne se modifie plus jamais.** C'est ce que contiennent les bases écrites
/// entre le 2 et le 3 août 2026 : la 1.0.0 moins `TaskItem.hasTime`.
///
/// Elle ne diffère de la forme courante que par `Project.colorRaw` (la teinte d'un projet), un
/// ajout PUR. Et pourtant elle existe : mesuré le 3 août 2026, un ajout optionnel n'est PAS absorbé
/// tout seul quand le numéro de version ne bouge pas. SwiftData compare les numéros, pas les
/// formes — 2.0.0 sur le disque contre 2.0.0 dans le code, il conclut « rien à faire », ne joue
/// aucune étape, et l'ouverture ÉCHOUE. `StoreQuarantine` a écarté la vraie base et l'app est
/// repartie vide. C'est le prix d'une étape oubliée : ce n'est pas la NATURE du changement qui
/// décide, c'est le fait de le DÉCLARER.
enum SchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)

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

/// **Forme 3.0.0, FIGÉE — ne se modifie plus jamais.** La 2.0.0 plus `Project.colorRaw`.
///
/// C'est la dernière forme SANS identité stable : aucune de ses entités ne porte d'`uuid` sauf
/// `Subtask`, et ses propriétés non optionnelles n'ont pas toutes de valeur par défaut. Autrement
/// dit, la dernière forme qu'iCloud aurait refusé de synchroniser (cf. l'étape 3→4).
enum SchemaV3: VersionedSchema {
  static let versionIdentifier = Schema.Version(3, 0, 0)

  static var models: [any PersistentModel.Type] {
    [Project.self, TodoList.self, TaskItem.self, Subtask.self]
  }

  @Model final class Project {
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

/// **Forme 4.0.0, FIGÉE — ne se modifie plus jamais.** La 3.0.0 plus les `uuid` d'identité stable
/// et les valeurs par défaut que CloudKit exige. C'est ce que contiennent les bases écrites entre le
/// 3 et le 5 août 2026.
///
/// Elle ne diffère de la forme courante que par `TaskItem.whenMinutes` (l'heure d'une tâche datée),
/// un ajout PUR — et pourtant elle existe, pour la raison mesurée le 3 août : un ajout sans montée
/// de version fait ÉCHOUER l'ouverture (cf. `SchemaV2`).
enum SchemaV4: VersionedSchema {
  static let versionIdentifier = Schema.Version(4, 0, 0)

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
/// Deux formes passées à ce jour (1.0.0, 2.0.0). La marche ci-dessous vaut pour TOUT changement de
/// forme, pas seulement pour un changement cassant : c'est la leçon du 3 août 2026, où un ajout
/// optionnel sans montée de version a fait échouer l'ouverture et mettre la vraie base en
/// quarantaine (cf. `SchemaV2`).
///
/// ## À chaque fois que la forme d'un `@Model` bouge
///
/// 1. Copier ICI la forme DÉPLOYÉE (`Tests/TodayTests/DeployedSchemaSnapshot.swift`, avant
///    retouche), sous le numéro qu'elle porte : `SchemaV<N>`. Ses types sont IMBRIQUÉS dans
///    l'enum, donc indépendants du code vivant : c'est ce qui lui permet de continuer à décrire
///    l'ANCIENNE forme une fois les modèles modifiés. Vérifié : imbriquer un `@Model` ne change
///    pas l'entité de store qu'il décrit — une base écrite par les modèles de premier niveau s'y
///    relit sans perte, relations comprises.
/// 2. Modifier librement les modèles vivants, puis monter `CurrentSchema.versionIdentifier`. Il
///    n'y a JAMAIS d'enum figée pour la forme COURANTE : elle n'est décrite qu'une fois, par les
///    modèles eux-mêmes. On ne fige une version qu'au moment où elle devient passée.
/// 3. Ajouter la forme passée à `schemas`, dans l'ordre.
/// 4. Ajouter son étape à `stages` — `.lightweight` si le changement est additif ou purement
///    soustractif, `.custom(...)` s'il faut transporter de la donnée d'un champ à l'autre (c'est
///    le cas d'un renommage, et c'est LUI qui sauve les valeurs que SwiftData jetterait sinon).
///    Une étape même triviale n'est PAS facultative : sans elle, l'ouverture échoue.
/// 5. Re-figer la nouvelle forme dans `DeployedSchemaSnapshot` (qui garde son rôle : « ce que
///    contiennent les disques »), son `versionIdentifier` compris, et rendre
///    `SchemaCompatibilityTests` vert.
///
/// Le test, lui, ne change jamais de nature : il vérifie toujours qu'une base au format déployé
/// s'ouvre par `TodayApp.openStore`. C'est ce qui rend l'ajout d'une version mécanique.
enum TodayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self, CurrentSchema.self]
  }

  /// Les deux premières étapes sont `.lightweight` : rien n'y voyage d'un champ vers un autre. La
  /// 2.0.0 RETIRE `hasTime` (faux partout, c'est la raison de sa suppression) ; la 3.0.0 AJOUTE
  /// `Project.colorRaw`, optionnel et donc nil sur toutes les bases existantes.
  ///
  /// Elles sont là malgré leur caractère trivial : sans étape, SwiftData ne compare que les numéros
  /// de version, conclut « rien à faire » et l'ouverture ÉCHOUE (cf. `SchemaV2`).
  ///
  /// **La 3→4 est `.custom`, et il le fallait.** Elle ajoute un `uuid` à `Project`, `TodoList` et
  /// `TaskItem` — l'identité stable dont la synchro entre appareils a besoin. En `.lightweight`,
  /// les lignes existantes auraient été remplies par la valeur par DÉFAUT de l'attribut, et une
  /// valeur par défaut est une expression évaluée UNE fois à la construction du schéma : les 87
  /// tâches d'une base auraient toutes reçu le MÊME `UUID`. Un identifiant d'identité partagé par
  /// tout le monde ne distingue rien — c'est précisément le doublon en masse qu'il est censé
  /// empêcher, livré dès le premier jour de synchro. `didMigrate` en attribue donc un neuf à chaque
  /// ligne, une fois, au moment du passage. Vérifié par `SchemaMigrationV4Tests`.
  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
      .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
      .custom(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self,
        willMigrate: nil,
        didMigrate: stampIdentities
      ),
      // 4→5 : ajout de `TaskItem.whenMinutes` (l'heure d'une tâche datée), optionnel donc nil sur
      // toutes les bases existantes — une tâche d'avant n'avait pas d'heure, et n'en a toujours pas.
      .lightweight(fromVersion: SchemaV4.self, toVersion: CurrentSchema.self),
    ]
  }

  /// Donne à chaque ligne d'avant la 4.0.0 son identité propre.
  ///
  /// Inconditionnel, et c'est volontaire : cette étape ne s'exécute qu'AU passage 3→4, où par
  /// construction aucune ligne n'a encore d'`uuid` qui lui appartienne. Chercher lesquelles
  /// « en ont besoin » demanderait de reconnaître la valeur par défaut — celle-là même qui change à
  /// chaque lancement du process, donc rien de fiable à comparer.
  ///
  /// `Subtask` est épargnée : elle porte un `uuid` depuis la 1.0.0, et le sien est bien distinct
  /// (ses lignes sont toutes nées d'un `init`, jamais remplies par une migration).
  /// `@Sendable` explicite : `MigrationStage.custom` attend une fonction `@Sendable`, et en mode
  /// Swift 5 le compilateur ne l'infère pas d'une déclaration — même quand elle ne capture rien.
  /// Les types de `SchemaV4` et PAS les modèles vivants : à ce moment-là le store porte la forme
  /// 4.0.0, pas la courante. Lire par les vivants reviendrait à réclamer une colonne (`whenMinutes`)
  /// que l'étape suivante seule ajoutera.
  @Sendable private static func stampIdentities(_ context: ModelContext) throws {
    for project in try context.fetch(FetchDescriptor<SchemaV4.Project>()) { project.uuid = UUID() }
    for list in try context.fetch(FetchDescriptor<SchemaV4.TodoList>()) { list.uuid = UUID() }
    for task in try context.fetch(FetchDescriptor<SchemaV4.TaskItem>()) { task.uuid = UUID() }
    try context.save()
  }
}
