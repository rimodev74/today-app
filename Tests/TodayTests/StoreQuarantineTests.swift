import XCTest

@testable import Today

final class StoreQuarantineTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func store(_ suffixes: [String]) throws -> URL {
    let url = directory.appendingPathComponent("default.store")
    for suffix in suffixes {
      try Data("x".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
    }
    return url
  }

  private var remaining: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
  }

  /// Le contrat entier : plus rien au chemin d'origine (l'app peut recréer une base neuve), et
  /// rien de perdu — les trois fichiers sont retrouvables à côté.
  func testQuarantine_movesStoreAndJournalInsteadOfDeleting() throws {
    let url = try store(["", "-wal", "-shm"])

    let moved = StoreQuarantine.quarantine(url)

    XCTAssertEqual(moved.count, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(remaining.count, 3)
    XCTAssertTrue(remaining.allSatisfy { $0.contains(".corrupt-") })
    for file in moved {
      XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
    }
  }

  /// `-wal`/`-shm` n'existent pas toujours (store fermé proprement) : leur absence n'est pas un
  /// échec, et le `.store` doit partir quand même.
  func testQuarantine_toleratesMissingJournalFiles() throws {
    let url = try store([""])

    let moved = StoreQuarantine.quarantine(url)

    XCTAssertEqual(moved.count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  /// Deux mises en quarantaine ne doivent pas s'écraser : c'est tout l'intérêt de l'horodatage.
  func testQuarantine_twiceKeepsBothCopies() throws {
    let first = try store([""])
    StoreQuarantine.quarantine(first, now: Date(timeIntervalSince1970: 0))
    let second = try store([""])
    StoreQuarantine.quarantine(second, now: Date(timeIntervalSince1970: 86_400))

    XCTAssertEqual(remaining.count, 2)
  }

  func testQuarantine_onMissingStoreDoesNothing() {
    XCTAssertTrue(
      StoreQuarantine.quarantine(directory.appendingPathComponent("absent.store")).isEmpty)
  }

  // MARK: Le rapport à l'utilisateur

  /// Des défauts À PART : la vraie base d'un développeur qui lance les tests n'a rien à voir ici.
  private func scratchDefaults() throws -> UserDefaults {
    let name = UUID().uuidString
    let suite = try XCTUnwrap(UserDefaults(suiteName: name))
    addTeardownBlock { suite.removeSuite(named: name) }
    return suite
  }

  /// Le contrat de l'alerte : ce qui a été écarté est retrouvable APRÈS coup, depuis un autre
  /// moment du lancement — la quarantaine a lieu avant qu'aucune fenêtre n'existe.
  func testReport_survivesQuarantineAndNamesEveryMovedFile() throws {
    let defaults = try scratchDefaults()
    let url = try store(["", "-wal", "-shm"])

    let moved = StoreQuarantine.quarantine(url, defaults: defaults)

    XCTAssertEqual(
      StoreQuarantine.consumeReport(defaults: defaults).sorted(), moved.map(\.path).sorted())
  }

  /// Lu une fois, oublié : sans ça l'alerte reviendrait à CHAQUE lancement, pour toujours.
  func testReport_isConsumedOnce() throws {
    let defaults = try scratchDefaults()
    StoreQuarantine.quarantine(try store([""]), defaults: defaults)

    XCTAssertFalse(StoreQuarantine.consumeReport(defaults: defaults).isEmpty)
    XCTAssertTrue(StoreQuarantine.consumeReport(defaults: defaults).isEmpty)
  }

  /// Une quarantaine qui n'écarte rien ne doit pas EFFACER un rapport pas encore lu : deux
  /// lancements ratés d'affilée, et le premier — celui qui portait la vraie base — serait perdu.
  func testReport_isNotErasedByAQuarantineThatMovedNothing() throws {
    let defaults = try scratchDefaults()
    StoreQuarantine.quarantine(try store([""]), defaults: defaults)

    StoreQuarantine.quarantine(directory.appendingPathComponent("absent.store"), defaults: defaults)

    XCTAssertEqual(StoreQuarantine.consumeReport(defaults: defaults).count, 1)
  }
}
