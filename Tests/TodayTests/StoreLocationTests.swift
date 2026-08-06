import XCTest

@testable import Today

/// Le déménagement de la base vers son sous-dossier. Il n'a lieu qu'UNE fois, chez chaque
/// utilisateur, au premier lancement qui suit — autant dire qu'il ne se vérifie pas à l'usage :
/// quand on s'aperçoit qu'il a mal tourné, la base est déjà ailleurs.
///
/// Les trois refus comptent autant que le déplacement lui-même. Celui qui compte le plus est
/// « la destination existe déjà » : c'est lui qui empêche un second lancement d'écraser la base
/// vivante avec ce qui traîne encore à l'ancienne adresse — et à l'ancienne adresse, on sait
/// maintenant que n'importe quelle app peut avoir posé n'importe quoi.
final class StoreLocationTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("StoreLocationTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// Les trois fichiers SQLite, remplis d'un contenu reconnaissable pour vérifier que c'est bien
  /// CELUI-LÀ qui arrive à destination, et pas un fichier vide créé au passage.
  private func makeLegacyStore(contents: String = "base") throws {
    for suffix in StoreLocation.companionSuffixes {
      let url = URL(fileURLWithPath: StoreLocation.legacyURL(in: root).path + suffix)
      try (contents + suffix).write(to: url, atomically: true, encoding: .utf8)
    }
  }

  private func read(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  func testLaBaseVitDansUnSousDossierAuNomDeLApp() {
    let url = StoreLocation.storeURL(in: root)
    XCTAssertEqual(url.lastPathComponent, "default.store")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Today")
  }

  func testLeDemenagementEmporteLeJournalAvecLaBase() throws {
    try makeLegacyStore()
    try FileManager.default.createDirectory(
      at: StoreLocation.storeURL(in: root).deletingLastPathComponent(),
      withIntermediateDirectories: true)

    XCTAssertTrue(StoreLocation.migrateIfNeeded(applicationSupport: root))

    let destination = StoreLocation.storeURL(in: root)
    // Les TROIS, pas seulement le `.store` : le journal porte tout ce qui n'a pas encore été replié.
    XCTAssertEqual(read(destination), "base")
    XCTAssertEqual(read(URL(fileURLWithPath: destination.path + "-shm")), "base-shm")
    XCTAssertEqual(read(URL(fileURLWithPath: destination.path + "-wal")), "base-wal")
    // Déplacés, donc plus à l'ancienne adresse — sans quoi un prochain lancement pourrait les
    // reprendre et écraser ce qui aurait été écrit entre-temps.
    XCTAssertFalse(FileManager.default.fileExists(atPath: StoreLocation.legacyURL(in: root).path))
  }

  func testUneBaseDejaEnPlaceNEstJamaisEcrasee() throws {
    try makeLegacyStore(contents: "ancienne")
    let destination = StoreLocation.storeURL(in: root)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "vivante".write(to: destination, atomically: true, encoding: .utf8)

    XCTAssertFalse(StoreLocation.migrateIfNeeded(applicationSupport: root))

    XCTAssertEqual(read(destination), "vivante")
    // L'ancienne n'est pas supprimée non plus : on ne détruit rien qu'on n'a pas su déplacer.
    XCTAssertEqual(read(StoreLocation.legacyURL(in: root)), "ancienne")
  }

  func testPremierLancementSansAncienneBaseNeFaitRien() {
    XCTAssertFalse(StoreLocation.migrateIfNeeded(applicationSupport: root))
    XCTAssertFalse(FileManager.default.fileExists(atPath: StoreLocation.storeURL(in: root).path))
  }

  /// `resolve` doit rendre une adresse utilisable sans que l'appelant ait rien à préparer : c'est
  /// lui qui crée le dossier. Sans ça, le déplacement échouerait au premier lancement et l'app
  /// s'ouvrirait vide à côté d'une base intacte.
  ///
  /// La variante à dossier DONNÉ, jamais `resolve()` sans argument : celle-là irait chercher le
  /// vrai `~/Library/Application Support` et déménagerait la base de l'utilisateur.
  func testResolveCreeLeDossierEtDemenage() throws {
    try makeLegacyStore()
    let url = StoreLocation.resolve(applicationSupport: root)

    XCTAssertEqual(url, StoreLocation.storeURL(in: root))
    var isDirectory: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    // Et le déménagement a bien eu lieu au passage : c'est le seul appel du chemin réel.
    XCTAssertEqual(read(url), "base")
  }
}
