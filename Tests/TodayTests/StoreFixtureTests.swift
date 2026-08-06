import SwiftData
import XCTest

@testable import Today

/// **Le cliquet des données : une VRAIE base par version de schéma livrée, rouverte à chaque
/// `swift test` par le chemin réel de l'app.**
///
/// Il existe parce que les deux autres protections ont laissé passer la même faute, à deux jours
/// d'écart, et que l'app a démarré vide les deux fois.
///
/// Ce qu'aucun autre test ne peut faire. `SchemaCompatibilityTests` fabrique ses bases à partir
/// d'une DESCRIPTION EN CODE de l'ancienne forme (`SchemaV1`, `SchemaV2`, `DeployedSchemaSnapshot`).
/// Une description est éditable — et le 3 août 2026 elle a été éditée dans le même commit que les
/// modèles : le test comparait alors la forme neuve à elle-même, il est resté vert, et la vraie base
/// est partie en quarantaine. Pire, la base réellement mise de côté le 2 août portait une forme
/// (`hasTime` SANS `smartOrder`) qu'aucune enum du code n'a jamais décrite : le test était vert sur
/// une fiction.
///
/// Un fichier binaire versionné, lui, ne dérive pas. Il n'est pas relu par la description, il EST le
/// disque. Le régénérer demande un geste délibéré, visible en revue — pas une ligne modifiée en
/// passant.
///
/// ## Ajouter une version
///
/// À chaque montée de `CurrentSchema.versionIdentifier`, déposer ici la base écrite par la version
/// SORTANTE, sous `Fixtures/v<M>_<m>_<p>.store`, et ajouter sa ligne à `shipped`. Un seul fichier :
/// le journal SQLite est replié dedans (`PRAGMA wal_checkpoint(TRUNCATE)`), sans quoi il faudrait en
/// committer trois et l'un des trois finirait par manquer.
///
/// Les fichiers déjà là ne se retouchent JAMAIS. Une fixture modifiée ne prouve plus rien.
final class StoreFixtureTests: XCTestCase {
  /// Toutes les formes qui ont existé sur un disque, de la plus ancienne à la courante.
  private static let shipped = ["v1_0_0", "v2_0_0", "v3_0_0", "v4_0_0", "v5_0_0"]

  /// Copie la fixture ailleurs AVANT de l'ouvrir : `openStore` MIGRE le fichier qu'on lui donne.
  /// Ouvrir la fixture en place la réécrirait à la forme courante — au deuxième `swift test` elle
  /// ne testerait plus rien, et personne ne s'en apercevrait.
  private func temporaryCopy(of fixture: String) throws -> URL {
    let source = try XCTUnwrap(
      Bundle.module.url(forResource: "Fixtures/\(fixture)", withExtension: "store"),
      "fixture « \(fixture).store » absente du bundle de tests")
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fixture-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let copy = directory.appendingPathComponent("default.store")
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
  }

  /// LE test. Chaque base livrée s'ouvre encore, et rend ce qu'elle contenait.
  ///
  /// Rouge = une base d'utilisateur ne s'ouvrira plus. **Ne pas lancer l'app** : suivre les cinq
  /// points en tête de `TodaySchema.swift` (figer la forme sortante, monter la version, déclarer
  /// l'étape) plutôt que de toucher à la fixture.
  @MainActor
  func testEveryShippedStoreStillOpensAndKeepsItsData() throws {
    for fixture in Self.shipped {
      let url = try temporaryCopy(of: fixture)
      let container = try TodayApp.openStore(ModelConfiguration(url: url))
      let context = ModelContext(container)

      let projects = try context.fetch(FetchDescriptor<Project>())
      let lists = try context.fetch(FetchDescriptor<TodoList>())
      let tasks = try context.fetch(FetchDescriptor<TaskItem>())
      let subtasks = try context.fetch(FetchDescriptor<Subtask>())

      XCTAssertEqual(projects.map(\.title), ["Maison"], "\(fixture) : projet perdu")
      XCTAssertEqual(lists.map(\.title), ["Courses"], "\(fixture) : liste perdue")
      XCTAssertEqual(tasks.map(\.title), ["Acheter du pain"], "\(fixture) : tâche perdue")
      XCTAssertEqual(subtasks.map(\.title), ["Baguette"], "\(fixture) : sous-tâche perdue")

      // Les scalaires, qu'un changement de TYPE ferait retomber au défaut sans un mot.
      let task = try XCTUnwrap(tasks.first)
      XCTAssertEqual(task.when, Date(timeIntervalSince1970: 1_800_000_000), "\(fixture) : when")
      XCTAssertEqual(
        task.deadline, Date(timeIntervalSince1970: 1_800_600_000), "\(fixture) : deadline")
      XCTAssertEqual(task.priority, .medium, "\(fixture) : priorité")
      XCTAssertEqual(task.estimateMinutes, 45, "\(fixture) : estimation")
      XCTAssertEqual(task.smartOrder, 7, "\(fixture) : ordre des vues intelligentes")
      XCTAssertEqual(task.headerColor, .purple, "\(fixture) : teinte d'en-tête")

      // Les relations : c'est par elles que la sidebar et les pages retrouvent quoi que ce soit.
      XCTAssertEqual(task.list?.title, "Courses", "\(fixture) : tâche détachée de sa liste")
      XCTAssertEqual(task.list?.project?.title, "Maison", "\(fixture) : liste détachée du projet")
      XCTAssertEqual(task.subtasks.map(\.title), ["Baguette"], "\(fixture) : sous-tâches détachées")
      XCTAssertEqual(projects.first?.lists.count, 1, "\(fixture) : projet vidé de ses listes")
    }
  }

  /// La liste des fixtures et la chaîne de migration doivent rester d'accord : autant de bases
  /// livrées que de formes déclarées. Sans ce compte, on peut monter une version, déclarer son
  /// étape, et oublier de déposer la base — le trou ne se verrait qu'à la prochaine montée, quand
  /// il serait trop tard pour la fabriquer.
  func testOneFixturePerDeclaredSchema() {
    XCTAssertEqual(
      Self.shipped.count, TodayMigrationPlan.schemas.count,
      """
      \(TodayMigrationPlan.schemas.count) formes déclarées dans `TodayMigrationPlan`, \
      \(Self.shipped.count) bases fixtures. Déposer la base écrite par la version sortante dans \
      Tests/TodayTests/Fixtures/, puis l'ajouter à `shipped`.
      """)
  }
}
