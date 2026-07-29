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
    XCTAssertTrue(StoreQuarantine.quarantine(directory.appendingPathComponent("absent.store")).isEmpty)
  }
}
