import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import Today

/// Les couvertures sur un dossier TEMPORAIRE — jamais celui de l'app.
@MainActor
final class ProjectCoversTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProjectCoversTests-\(UUID().uuidString)")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: directory)
  }

  /// Une vraie image PNG de `width × height` pixels, écrite à côté.
  private func png(width: Int, height: Int) throws -> URL {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("source-\(UUID().uuidString).png")
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return url
  }

  func testSetReduitEcritEtSeRetrouveAuRelancement() async throws {
    let covers = ProjectCovers(directory: directory)
    let uuid = UUID()
    let ok = await covers.set(from: try png(width: 4_000, height: 1_000), for: uuid)

    XCTAssertTrue(ok)
    XCTAssertNotNil(covers.stamps[uuid])
    let stored = try XCTUnwrap(ProjectCovers.decode(covers.url(for: uuid), maxPixel: 10_000))
    XCTAssertEqual(stored.width, ProjectCovers.storedMaxPixel)
    XCTAssertEqual(stored.height, 500)
    // Un nouveau service (un relancement) relit le dossier.
    XCTAssertNotNil(ProjectCovers(directory: directory).stamps[uuid])
  }

  func testUnFichierQuiNEstPasUneImageEstRefuse() async throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let text = directory.appendingPathComponent("notes.txt")
    try Data("pas une image".utf8).write(to: text)
    let covers = ProjectCovers(directory: directory)
    let uuid = UUID()

    let ok = await covers.set(from: text, for: uuid)
    XCTAssertFalse(ok)
    XCTAssertNil(covers.stamps[uuid])
    XCTAssertFalse(FileManager.default.fileExists(atPath: covers.url(for: uuid).path))
  }

  func testRemplacerChangeLeStampEtRetirerEfface() async throws {
    let covers = ProjectCovers(directory: directory)
    let uuid = UUID()
    await covers.set(from: try png(width: 100, height: 100), for: uuid)
    let first = try XCTUnwrap(covers.stamps[uuid])
    await covers.set(from: try png(width: 200, height: 100), for: uuid)
    XCTAssertNotEqual(covers.stamps[uuid], first)

    let shown = await covers.image(for: uuid, stamp: covers.stamps[uuid]!, maxPixel: 50)
    XCTAssertEqual(shown?.width, 50)

    covers.remove(for: uuid)
    XCTAssertNil(covers.stamps[uuid])
    XCTAssertFalse(FileManager.default.fileExists(atPath: covers.url(for: uuid).path))
  }

  /// Retirer ou remplacer une couverture purge ses images décodées : sans ça, chaque version
  /// laissait sa mémoire au cache jusqu'à la pression du système.
  func testRetirerEtRemplacerPurgentLeCache() async throws {
    let covers = ProjectCovers(directory: directory)
    let uuid = UUID()
    await covers.set(from: try png(width: 100, height: 100), for: uuid)
    let first = try XCTUnwrap(covers.stamps[uuid])
    _ = await covers.image(for: uuid, stamp: first, maxPixel: 50)
    XCTAssertTrue(covers.hasCachedImage(for: uuid, stamp: first, maxPixel: 50))

    await covers.set(from: try png(width: 200, height: 100), for: uuid)
    XCTAssertFalse(covers.hasCachedImage(for: uuid, stamp: first, maxPixel: 50))

    let second = try XCTUnwrap(covers.stamps[uuid])
    _ = await covers.image(for: uuid, stamp: second, maxPixel: 50)
    _ = await covers.image(for: uuid, stamp: second, maxPixel: 80)
    XCTAssertTrue(covers.hasCachedImage(for: uuid, stamp: second, maxPixel: 80))
    covers.remove(for: uuid)
    XCTAssertFalse(covers.hasCachedImage(for: uuid, stamp: second, maxPixel: 50))
    XCTAssertFalse(covers.hasCachedImage(for: uuid, stamp: second, maxPixel: 80))
  }

  /// Le coût d'une entrée, ce sont ses octets décodés — c'est ce que `totalCostLimit` additionne.
  func testLeCoutDuCacheEstLeNombreDOctetsDeLImage() throws {
    let image = try XCTUnwrap(
      ProjectCovers.decode(try png(width: 300, height: 120), maxPixel: 10_000))
    XCTAssertEqual(ProjectCovers.cacheCost(of: image), image.bytesPerRow * 120)
    XCTAssertGreaterThanOrEqual(ProjectCovers.cacheCost(of: image), 300 * 120 * 4)
    XCTAssertEqual(ProjectCovers.cacheCostLimit, 64 * 1024 * 1024)
  }

  func testUnePetiteImageNEstPasAgrandie() async throws {
    let covers = ProjectCovers(directory: directory)
    let uuid = UUID()
    await covers.set(from: try png(width: 300, height: 120), for: uuid)
    let stored = try XCTUnwrap(ProjectCovers.decode(covers.url(for: uuid), maxPixel: 10_000))
    XCTAssertEqual(stored.width, 300)
  }
}
