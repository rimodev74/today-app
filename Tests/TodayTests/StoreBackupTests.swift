import SwiftData
import XCTest

@testable import Today

/// La sauvegarde avant migration. Tout se joue dans un dossier temporaire et un `UserDefaults`
/// jetable — la vraie base et les vrais défauts ne sont jamais touchés.
final class StoreBackupTests: XCTestCase {
  private var directory: URL!
  private var store: URL!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("backup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = directory.appendingPathComponent("default.store")
    // Suite nommée et vidée : `UserDefaults.standard` porte les réglages de l'utilisateur.
    let suite = "StoreBackupTests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Écrit un store bidon et son journal, pour vérifier que les TROIS fichiers voyagent ensemble.
  private func writeStoreFiles(_ content: String = "données") throws {
    for suffix in ["", "-wal", "-shm"] {
      try content.write(
        to: URL(fileURLWithPath: store.path + suffix), atomically: true, encoding: .utf8)
    }
  }

  private func backupDirectories() -> [String] {
    let root = directory.appendingPathComponent(StoreBackup.directoryName)
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    return entries.map(\.lastPathComponent).sorted()
  }

  private var schema: Schema { Schema(versionedSchema: CurrentSchema.self) }

  // MARK: L'empreinte

  /// **Le test qui compte, et celui qui manquait.** L'empreinte ne doit dépendre QUE des noms et des
  /// types — pas des valeurs par défaut.
  ///
  /// `DeployedSchemaSnapshot` décrit la même forme que les modèles vivants (`SchemaCompatibilityTests` le
  /// prouve en relisant l'un par l'autre) mais DÉCLARE ses valeurs par défaut là où les modèles
  /// vivants les posent dans leur `init`. Deux empreintes égales prouvent donc que les défauts n'y
  /// entrent pas.
  ///
  /// C'est vital, et pas cosmétique : une valeur par défaut est une expression évaluée à la
  /// construction du schéma, donc `Date()` et `UUID()` en donnent une différente à CHAQUE lancement.
  /// Une première version les incluait — l'app recopiait sa base à chaque démarrage. Une comparaison
  /// entre deux constructions dans le même process ne l'avait pas vu (SwiftData mémoïse le schéma) ;
  /// celle-ci, si.
  func testFingerprintIgnoresDefaultValues() {
    XCTAssertEqual(
      StoreBackup.fingerprint(of: schema),
      StoreBackup.fingerprint(of: Schema(versionedSchema: DeployedSchemaSnapshot.self)))
  }

  // MARK: Le déclenchement

  /// Première ouverture connue de cette forme : on copie, même si rien n'a « changé » — on ne sait
  /// simplement pas ce qui a précédé, et une copie de trop ne coûte rien.
  func testFirstRunTakesASnapshot() throws {
    try writeStoreFiles()
    let created = StoreBackup.snapshotIfShapeChanged(of: store, schema: schema, defaults: defaults)

    XCTAssertNotNil(created)
    XCTAssertEqual(backupDirectories().count, 1)
  }

  /// Forme inchangée : rien, pas même un dossier vide. C'est le cas de tous les lancements ordinaires.
  func testUnchangedShapeDoesNothing() throws {
    try writeStoreFiles()
    StoreBackup.snapshotIfShapeChanged(of: store, schema: schema, defaults: defaults)
    let after = StoreBackup.snapshotIfShapeChanged(of: store, schema: schema, defaults: defaults)

    XCTAssertNil(after)
    XCTAssertEqual(backupDirectories().count, 1, "toujours la seule copie du premier passage")
  }

  /// Le journal SQLite part avec le store. Une copie amputée restituerait un état antérieur aux
  /// dernières écritures — une sauvegarde qui ment est pire que pas de sauvegarde.
  func testSnapshotCarriesTheWriteAheadLog() throws {
    try writeStoreFiles("contenu vérifiable")
    let created = try XCTUnwrap(
      StoreBackup.snapshotIfShapeChanged(of: store, schema: schema, defaults: defaults))

    for name in ["default.store", "default.store-wal", "default.store-shm"] {
      let copied = created.appendingPathComponent(name)
      XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path), "\(name) manque")
      XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "contenu vérifiable")
    }
  }

  /// Pas encore de base (tout premier lancement de l'app) : rien à copier, et surtout pas d'échec.
  /// L'empreinte est tout de même retenue, sinon le chemin serait repris à chaque démarrage.
  func testNoStoreYetIsHarmless() {
    let created = StoreBackup.snapshotIfShapeChanged(of: store, schema: schema, defaults: defaults)

    XCTAssertNil(created)
    XCTAssertNotNil(defaults.string(forKey: StoreBackup.fingerprintKey))
    XCTAssertTrue(backupDirectories().isEmpty)
  }

  // MARK: L'élagage

  /// Au-delà de `keep`, les plus anciennes disparaissent — sinon chaque changement de modèle
  /// laisserait un dépôt de plusieurs mégaoctets derrière lui, indéfiniment.
  func testOnlyTheMostRecentSnapshotsAreKept() throws {
    try writeStoreFiles()
    // Une date différente par passage (le nom du dossier est un horodatage), et une empreinte
    // considérée changée à chaque fois puisqu'on repart de défauts vides.
    for day in 1...(StoreBackup.keep + 2) {
      defaults.removeObject(forKey: StoreBackup.fingerprintKey)
      StoreBackup.snapshotIfShapeChanged(
        of: store, schema: schema, defaults: defaults,
        now: Date(timeIntervalSince1970: TimeInterval(day) * 86_400))
    }

    let kept = backupDirectories()
    XCTAssertEqual(kept.count, StoreBackup.keep)
    // Les horodatages ISO 8601 se trient alphabétiquement dans l'ordre chronologique : ce sont bien
    // les derniers qui restent.
    XCTAssertTrue(kept.last!.hasPrefix("1970-01-06"), "la plus récente doit survivre : \(kept)")
    XCTAssertFalse(
      kept.contains { $0.hasPrefix("1970-01-02") }, "la plus ancienne doit avoir été élaguée")
  }
}
