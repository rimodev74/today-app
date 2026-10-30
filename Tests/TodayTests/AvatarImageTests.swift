import AppKit
import XCTest

@testable import Today

/// La photo de profil stockée : 256 px au plus, en PNG, et décodée une fois.
@MainActor
final class AvatarImageTests: XCTestCase {
  /// Un PNG uni de la taille demandée, fabriqué sans fichier.
  private func png(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
  }

  func testLargePhotoIsReducedToMaxPixelsKeepingItsRatio() throws {
    let reduced = try XCTUnwrap(AvatarImage.normalized(png(width: 2000, height: 1000)))
    let size = try XCTUnwrap(AvatarImage.pixelSize(of: reduced))
    XCTAssertEqual(size.width, AvatarImage.maxPixels)
    XCTAssertEqual(size.height, AvatarImage.maxPixels / 2)
  }

  func testSmallPhotoIsNeverEnlarged() throws {
    let reduced = try XCTUnwrap(AvatarImage.normalized(png(width: 64, height: 48)))
    let size = try XCTUnwrap(AvatarImage.pixelSize(of: reduced))
    XCTAssertEqual(size.width, 64)
    XCTAssertEqual(size.height, 48)
  }

  func testOutputIsPNG() throws {
    let reduced = try XCTUnwrap(AvatarImage.normalized(png(width: 300, height: 300)))
    XCTAssertEqual(Array(reduced.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "signature PNG")
  }

  func testNotAnImageGivesNil() {
    XCTAssertNil(AvatarImage.normalized(Data("pas une image".utf8)))
    XCTAssertNil(AvatarImage.pixelSize(of: Data()))
  }

  /// Un avatar déjà stocké en grand est réduit une fois au chargement, et réécrit dans les défauts.
  func testOversizedStoredAvatarIsReducedAtLoad() throws {
    let suite = "AvatarImageTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let big = png(width: 1200, height: 1200)
    defaults.set(big, forKey: "profileAvatarData")

    let profile = UserProfile(defaults: defaults)
    let stored = try XCTUnwrap(profile.avatarData)
    XCTAssertLessThan(stored.count, big.count)
    XCTAssertEqual(AvatarImage.pixelSize(of: stored)?.width, AvatarImage.maxPixels)
    XCTAssertEqual(defaults.data(forKey: "profileAvatarData"), stored, "réécrit dans les défauts")
  }

  /// L'image décodée est gardée tant que les octets ne changent pas, et suit leur changement.
  func testDecodedImageIsCachedUntilAvatarDataChanges() throws {
    let suite = "AvatarImageTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = UserProfile(defaults: defaults)

    profile.avatarData = png(width: 32, height: 32)
    let first = try XCTUnwrap(profile.avatarImage)
    XCTAssertTrue(first === profile.avatarImage, "même instance : décodée une seule fois")

    profile.avatarData = png(width: 48, height: 48)
    XCTAssertFalse(first === profile.avatarImage, "nouvelle image après un changement")

    profile.avatarData = nil
    XCTAssertNil(profile.avatarImage)
  }
}
