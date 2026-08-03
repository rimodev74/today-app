import SwiftData
import XCTest

@testable import Today

/// L'alarme qui manquait : une base écrite à la forme d'AUJOURD'HUI doit toujours s'ouvrir par le
/// chemin RÉEL de l'app (`TodayApp.openStore`, donc le vrai schéma et le vrai plan de migration).
///
/// Le jour où un `@Model` change de façon cassante (renommer un champ, en supprimer un, en changer
/// le type) sans qu'une `SchemaV2` et son étape n'accompagnent le changement, CE test vire au rouge.
/// Sans lui, rien ne prévient : `swift build` passe, les autres tests passent, et c'est au lancement
/// suivant que la vraie base part en quarantaine et que l'app s'ouvre vide.
///
/// **Attention à sa portée, mesurée le 3 août 2026 :** ce premier test écrit sa base à la forme de
/// `DeployedSchemaSnapshot`. Retoucher ce fichier-là EN MÊME TEMPS que les modèles le laisse donc
/// vert quoi qu'il arrive — il compare alors la forme neuve à elle-même, pendant que les vrais
/// disques portent l'ancienne. Ce sont les tests de MIGRATION plus bas qui tiennent l'autre bout :
/// eux partent d'une forme figée dans le code de l'app, qu'on ne peut pas déplacer sous ses pieds.
/// Toute forme déployée doit avoir le sien, y compris quand le changement n'est qu'un ajout.
final class SchemaCompatibilityTests: XCTestCase {
  private func temporaryStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("schema-compat-\(UUID().uuidString).store")
  }

  /// Écrit un store à la forme figée (cf. `DeployedSchemaSnapshot`), le rouvre par le chemin de l'app,
  /// et vérifie que TOUT se relit : les quatre entités et les relations qui les lient.
  @MainActor
  func testStoreWrittenAtV1ShapeStillOpensThroughTheApp() throws {
    let url = temporaryStoreURL()

    do {
      let frozen = try ModelContainer(
        for: Schema(versionedSchema: DeployedSchemaSnapshot.self),
        configurations: ModelConfiguration(url: url))
      let context = ModelContext(frozen)

      let project = DeployedSchemaSnapshot.Project()
      project.title = "Maison"
      context.insert(project)

      let list = DeployedSchemaSnapshot.TodoList()
      list.title = "Courses"
      list.project = project
      context.insert(list)

      let task = DeployedSchemaSnapshot.TaskItem()
      task.title = "Acheter du pain"
      task.list = list
      task.when = Date(timeIntervalSince1970: 1_800_000_000)
      task.priorityRaw = 2
      context.insert(task)

      let subtask = DeployedSchemaSnapshot.Subtask()
      subtask.title = "Baguette"
      subtask.task = task
      context.insert(subtask)

      try context.save()
    }

    // LE point du test : le même chemin que `ThingsCloneApp.container`. Un `throw` ici, c'est la
    // quarantaine et l'app vide au prochain lancement.
    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    let context = ModelContext(container)

    let projects = try context.fetch(FetchDescriptor<Project>())
    let lists = try context.fetch(FetchDescriptor<TodoList>())
    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    let subtasks = try context.fetch(FetchDescriptor<Subtask>())

    XCTAssertEqual(projects.map(\.title), ["Maison"])
    XCTAssertEqual(lists.map(\.title), ["Courses"])
    XCTAssertEqual(tasks.map(\.title), ["Acheter du pain"])
    XCTAssertEqual(subtasks.map(\.title), ["Baguette"])

    // Les relations, pas seulement les lignes : c'est par elles que la sidebar et les pages
    // retrouvent quoi que ce soit.
    XCTAssertEqual(lists.first?.project?.title, "Maison")
    XCTAssertEqual(tasks.first?.list?.title, "Courses")
    XCTAssertEqual(subtasks.first?.task?.title, "Acheter du pain")
    XCTAssertEqual(projects.first?.lists.count, 1)
    XCTAssertEqual(lists.first?.tasks.count, 1)
    XCTAssertEqual(tasks.first?.subtasks.count, 1)

    // Et les valeurs scalaires, qu'un changement de TYPE ferait silencieusement retomber au défaut.
    XCTAssertEqual(tasks.first?.when, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(tasks.first?.priority, .medium)  // priorityRaw 2, cf. `Priority`
  }

  /// Une base VIDE à la forme figée doit s'ouvrir aussi : c'est le cas du premier lancement après
  /// une mise à jour, où rien n'a encore été écrit mais où le fichier porte déjà sa version.
  @MainActor
  func testEmptyStoreAtDeployedShapeOpensThroughTheApp() throws {
    let url = temporaryStoreURL()
    _ = try ModelContainer(
      for: Schema(versionedSchema: DeployedSchemaSnapshot.self),
      configurations: ModelConfiguration(url: url))

    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<TaskItem>()).count, 0)
  }

  // MARK: La migration elle-même

  /// Le test que la 2.0.0 a rendu nécessaire : une base écrite à l'ANCIENNE forme (1.0.0, avec
  /// `hasTime`) doit traverser `TodayMigrationPlan` sans rien perdre.
  ///
  /// C'est la seule chose qui distingue une migration déclarée d'une colonne qui disparaît en
  /// silence — les deux compilent, les deux ouvrent le store sans erreur. Retirer l'étape
  /// `.lightweight` du plan vire CE test au rouge, et rien d'autre.
  @MainActor
  func testStoreWrittenAtV1ShapeMigratesWithoutLosingAnything() throws {
    let url = temporaryStoreURL()

    do {
      let v1 = try ModelContainer(
        for: Schema(versionedSchema: SchemaV1.self),
        configurations: ModelConfiguration(url: url))
      let context = ModelContext(v1)

      let project = SchemaV1.Project()
      project.title = "Maison"
      context.insert(project)

      let list = SchemaV1.TodoList()
      list.title = "Courses"
      list.project = project
      context.insert(list)

      let task = SchemaV1.TaskItem()
      task.title = "Acheter du pain"
      task.list = list
      task.when = Date(timeIntervalSince1970: 1_800_000_000)
      task.priorityRaw = 2
      task.estimateMinutes = 45
      // Le champ que la 2.0.0 retire : posé à vrai pour que sa disparition soit le seul écart
      // possible entre les deux formes — tout le reste doit arriver intact de l'autre côté.
      task.hasTime = true
      context.insert(task)

      let subtask = SchemaV1.Subtask()
      subtask.title = "Baguette"
      subtask.task = task
      context.insert(subtask)

      try context.save()
    }

    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    let context = ModelContext(container)

    let tasks = try context.fetch(FetchDescriptor<TaskItem>())
    XCTAssertEqual(tasks.map(\.title), ["Acheter du pain"])

    // Ce qui devait SURVIVRE au retrait de `hasTime` — scalaires et relations.
    XCTAssertEqual(tasks.first?.when, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(tasks.first?.priority, .medium)
    XCTAssertEqual(tasks.first?.estimateMinutes, 45)
    XCTAssertEqual(tasks.first?.list?.title, "Courses")
    XCTAssertEqual(tasks.first?.list?.project?.title, "Maison")
    XCTAssertEqual(tasks.first?.subtasks.map(\.title), ["Baguette"])
  }

  /// Le test que la 3.0.0 a rendu nécessaire — et celui qui aurait évité l'incident du 3 août 2026 :
  /// une base à la forme 2.0.0 (sans `Project.colorRaw`) doit s'ouvrir par le chemin de l'app.
  ///
  /// La 3.0.0 n'AJOUTE qu'un champ optionnel, et on aurait juré que SwiftData l'absorbe seul. Non :
  /// tant que `CurrentSchema.versionIdentifier` restait à 2.0.0, il comparait 2.0.0 à 2.0.0,
  /// concluait « rien à faire », ne jouait aucune étape — et l'ouverture ÉCHOUAIT. La vraie base est
  /// partie en quarantaine et l'app s'est ouverte vide. Retirer l'étape 2→3 du plan, ou reposer
  /// `CurrentSchema` à 2.0.0, vire CE test au rouge.
  @MainActor
  func testStoreWrittenAtV2ShapeMigratesWithoutLosingAnything() throws {
    let url = temporaryStoreURL()

    do {
      let v2 = try ModelContainer(
        for: Schema(versionedSchema: SchemaV2.self),
        configurations: ModelConfiguration(url: url))
      let context = ModelContext(v2)

      let project = SchemaV2.Project()
      project.title = "Maison"
      context.insert(project)

      let list = SchemaV2.TodoList()
      list.title = "Courses"
      list.project = project
      context.insert(list)

      let task = SchemaV2.TaskItem()
      task.title = "Acheter du pain"
      task.list = list
      task.when = Date(timeIntervalSince1970: 1_800_000_000)
      task.priorityRaw = 2
      task.headerColorRaw = "purple"
      context.insert(task)

      try context.save()
    }

    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    let context = ModelContext(container)

    let projects = try context.fetch(FetchDescriptor<Project>())
    let tasks = try context.fetch(FetchDescriptor<TaskItem>())

    XCTAssertEqual(projects.map(\.title), ["Maison"])
    // Le champ qui APPARAÎT : nil sur une base d'avant, donc teinte d'accent — et surtout pas un
    // projet perdu au passage.
    XCTAssertNil(projects.first?.color)
    XCTAssertEqual(projects.first?.lists.map(\.title), ["Courses"])
    XCTAssertEqual(tasks.first?.when, Date(timeIntervalSince1970: 1_800_000_000))
    XCTAssertEqual(tasks.first?.priority, .medium)
    XCTAssertEqual(tasks.first?.headerColor, .purple)
    XCTAssertEqual(tasks.first?.list?.project?.title, "Maison")
  }
}
