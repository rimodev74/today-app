import SwiftData
import XCTest

@testable import Today

/// La 4.0.0 : identité stable entre appareils (`uuid` sur `Project`, `TodoList`, `TaskItem`) et
/// valeurs par défaut partout — les deux exigences dures de SwiftData + CloudKit.
///
/// Ce fichier garde l'étape `.custom` du plan de migration. C'est le SEUL endroit qui vérifie qu'une
/// base d'avant ressort avec des identités DISTINCTES : en `.lightweight`, elle s'ouvrirait très
/// bien, sans erreur, sans perte apparente — et chaque ligne porterait le même `uuid`. On ne s'en
/// apercevrait qu'au premier jour de synchro, en voyant tout se dupliquer.
final class SchemaMigrationV4Tests: XCTestCase {
  private func temporaryStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("v4-\(UUID().uuidString).store")
  }

  /// PLUSIEURS lignes par entité, et c'est tout l'intérêt : avec une seule, deux identités
  /// identiques et deux identités distinctes se ressemblent trait pour trait.
  @MainActor
  func testMigrationFromV3GivesEveryRowItsOwnIdentity() throws {
    let url = temporaryStoreURL()

    do {
      let v3 = try ModelContainer(
        for: Schema(versionedSchema: SchemaV3.self),
        configurations: ModelConfiguration(url: url))
      let context = ModelContext(v3)

      for p in 0..<3 {
        let project = SchemaV3.Project()
        project.title = "Projet \(p)"
        context.insert(project)
        for l in 0..<2 {
          let list = SchemaV3.TodoList()
          list.title = "Liste \(p)-\(l)"
          list.project = project
          context.insert(list)
          for t in 0..<4 {
            let task = SchemaV3.TaskItem()
            task.title = "Tâche \(p)-\(l)-\(t)"
            task.list = list
            context.insert(task)
          }
        }
      }
      try context.save()
    }

    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    let context = ModelContext(container)

    let projects = try context.fetch(FetchDescriptor<Project>())
    let lists = try context.fetch(FetchDescriptor<TodoList>())
    let tasks = try context.fetch(FetchDescriptor<TaskItem>())

    XCTAssertEqual(projects.count, 3)
    XCTAssertEqual(lists.count, 6)
    XCTAssertEqual(tasks.count, 24)

    // LE point du test. En `.lightweight`, chacun de ces trois ensembles vaudrait 1.
    XCTAssertEqual(
      Set(projects.map(\.uuid)).count, 3,
      "les 3 projets doivent avoir 3 identités distinctes, pas la valeur par défaut du schéma")
    XCTAssertEqual(
      Set(lists.map(\.uuid)).count, 6, "les 6 listes doivent avoir 6 identités distinctes")
    XCTAssertEqual(
      Set(tasks.map(\.uuid)).count, 24, "les 24 tâches doivent avoir 24 identités distinctes")

    // Et rien d'autre n'a bougé : une migration d'identité ne doit toucher qu'à l'identité.
    XCTAssertEqual(projects.map(\.title).sorted(), ["Projet 0", "Projet 1", "Projet 2"])
    XCTAssertEqual(tasks.filter { $0.list?.project != nil }.count, 24, "tâches détachées")
  }

  /// Une identité posée par l'app ne bouge plus. Sans ça, la synchro reverrait la même tâche comme
  /// une nouvelle à chaque écriture — le doublon, par l'autre bout.
  @MainActor
  func testIdentityIsAssignedOnceAndSurvivesEdits() throws {
    let url = temporaryStoreURL()
    let container = try TodayApp.openStore(ModelConfiguration(url: url))
    let context = ModelContext(container)

    let task = TaskItem(title: "Acheter du pain")
    context.insert(task)
    try context.save()
    let original = task.uuid

    task.title = "Acheter du pain complet"
    task.isCompleted = true
    try context.save()

    XCTAssertEqual(task.uuid, original, "modifier une tâche ne doit pas changer son identité")
  }

  /// Deux objets créés d'affilée ne partagent pas leur identité — la garantie la plus élémentaire,
  /// et celle qui tomberait si un jour quelqu'un remplaçait `UUID()` par une constante.
  func testFreshObjectsGetDistinctIdentities() {
    XCTAssertNotEqual(TaskItem(title: "a").uuid, TaskItem(title: "b").uuid)
    XCTAssertNotEqual(TodoList(title: "a").uuid, TodoList(title: "b").uuid)
    XCTAssertNotEqual(Project(title: "a").uuid, Project(title: "b").uuid)
  }
}

/// Les contraintes que CloudKit impose au modèle, vérifiées sur le schéma lui-même plutôt que
/// relues à l'œil.
///
/// Elles ne coûtent rien tant que la synchro n'est pas branchée — et c'est exactement le problème :
/// on peut les casser pendant des mois sans le voir, puis découvrir au moment de brancher iCloud
/// que le modèle est refusé en bloc. Ce test les tient à partir d'aujourd'hui.
final class CloudKitReadinessTests: XCTestCase {
  private var schema: Schema { Schema(versionedSchema: CurrentSchema.self) }

  /// CloudKit doit pouvoir matérialiser une ligne dont un champ n'est pas encore arrivé : toute
  /// propriété est donc optionnelle OU pourvue d'une valeur par défaut.
  func testEveryPropertyIsOptionalOrHasADefault() {
    var offenders: [String] = []
    for entity in schema.entities {
      for property in entity.properties {
        guard let attribute = property as? Schema.Attribute else { continue }
        if !attribute.isOptional && attribute.defaultValue == nil {
          offenders.append("\(entity.name).\(attribute.name)")
        }
      }
    }
    XCTAssertEqual(
      offenders, [],
      """
      CloudKit refuse un modèle dont une propriété n'est ni optionnelle ni pourvue d'une valeur par \
      défaut. À corriger : \(offenders.joined(separator: ", ")).
      """)
  }

  /// CloudKit ne sait pas tenir une contrainte d'unicité côté serveur : un modèle qui en porte une
  /// refuse de se synchroniser. L'unicité vient d'`UUID`, pas de la base.
  func testNoUniqueConstraints() {
    var offenders: [String] = []
    for entity in schema.entities {
      for property in entity.properties {
        guard let attribute = property as? Schema.Attribute else { continue }
        if attribute.isUnique { offenders.append("\(entity.name).\(attribute.name)") }
      }
    }
    XCTAssertEqual(offenders, [], "CloudKit interdit `@Attribute(.unique)` : \(offenders)")
  }

  /// Toute relation doit être optionnelle et avoir un inverse : CloudKit livre les objets liés dans
  /// un ordre qu'il ne garantit pas, une relation obligatoire ne peut donc jamais être satisfaite à
  /// l'arrivée du premier des deux.
  func testEveryRelationshipIsOptionalAndHasAnInverse() {
    var offenders: [String] = []
    for entity in schema.entities {
      for property in entity.properties {
        guard let relationship = property as? Schema.Relationship else { continue }
        let name = "\(entity.name).\(relationship.name)"
        if !relationship.isOptional && !relationship.isToOneRelationship {
          continue  // une relation « à plusieurs » vide est un ensemble vide, pas un manque
        }
        if !relationship.isOptional { offenders.append("\(name) (obligatoire)") }
        if relationship.inverseName == nil { offenders.append("\(name) (sans inverse)") }
      }
    }
    XCTAssertEqual(offenders, [], "relations incompatibles CloudKit : \(offenders)")
  }

  /// Les trois entités racines portent une identité stable. `Subtask` en avait déjà une.
  func testEveryEntityCarriesAStableIdentity() {
    for entity in schema.entities {
      XCTAssertTrue(
        entity.properties.contains { $0.name == "uuid" },
        "\(entity.name) n'a pas d'identité stable : la synchro ne pourra pas la reconnaître")
    }
  }
}
