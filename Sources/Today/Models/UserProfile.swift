import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Profil affiché en haut de la sidebar.
///
/// ponytail: stocké en UserDefaults tant qu'il n'y a pas de compte distant. Le jour où
/// un backend + auth arrivent, seul le corps de cette classe change — les vues lisent
/// `fullName` / `avatarImage` et ne savent pas d'où ça vient.
@Observable
final class UserProfile {
  private enum Key {
    static let firstName = "profileFirstName"
    static let lastName = "profileLastName"
    static let avatar = "profileAvatarData"
  }

  var firstName: String { didSet { defaults.set(firstName, forKey: Key.firstName) } }
  var lastName: String { didSet { defaults.set(lastName, forKey: Key.lastName) } }
  var avatarData: Data? {
    didSet {
      defaults.set(avatarData, forKey: Key.avatar)
      decodedAvatar = nil
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  /// L'image décodée de `avatarData`, gardée jusqu'à ce qu'il change. `avatarImage` est lue par
  /// chaque rendu de la carte de profil : sans cache, c'est un décodage complet à chaque fois.
  @ObservationIgnored private var decodedAvatar: NSImage?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Premier lancement : on part du nom du compte macOS plutôt que d'un champ vide.
    let fallback = Self.splitFullName(NSFullUserName())
    firstName = defaults.string(forKey: Key.firstName) ?? fallback.first
    lastName = defaults.string(forKey: Key.lastName) ?? fallback.last
    avatarData = defaults.data(forKey: Key.avatar)
    // Un avatar stocké avant la réduction à l'import (une photo entière dans les défauts) est ramené
    // à sa taille UNE fois, ici. `didSet` ne joue pas dans un `init` : l'écriture est explicite.
    if let stored = avatarData, let size = AvatarImage.pixelSize(of: stored),
      max(size.width, size.height) > AvatarImage.maxPixels,
      let reduced = AvatarImage.normalized(stored)
    {
      avatarData = reduced
      defaults.set(reduced, forKey: Key.avatar)
    }
  }

  var fullName: String {
    let name = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Sans nom" : name
  }

  /// Initiales de repli quand aucune photo n'est choisie.
  var initials: String {
    let letters = [firstName, lastName]
      .compactMap { $0.trimmingCharacters(in: .whitespaces).first }
      .map(String.init)
    return letters.isEmpty ? "?" : letters.joined().uppercased()
  }

  var avatarImage: NSImage? {
    guard let avatarData else { return nil }
    if let decodedAvatar { return decodedAvatar }
    let image = NSImage(data: avatarData)
    decodedAvatar = image
    return image
  }

  private static func splitFullName(_ name: String) -> (first: String, last: String) {
    let parts = name.split(separator: " ").map(String.init)
    guard let first = parts.first else { return ("", "") }
    return (first, parts.dropFirst().joined(separator: " "))
  }
}

/// La photo de profil telle qu'on la stocke : 256 px au plus, en PNG.
///
/// Elle s'affiche à 40-42 pt. Stocker la photo d'origine mettait plusieurs mégaoctets dans
/// `UserDefaults`, relus au lancement, avec un décodage complet à chaque rendu de la carte.
/// ImageIO et pas `NSImage` : il réduit en lisant, sans décoder l'image entière, et ne dépend
/// d'aucune vue.
enum AvatarImage {
  static let maxPixels = 256

  /// Les dimensions en pixels, lues dans l'en-tête — sans décoder l'image. `nil` si ce n'en est pas une.
  static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }

  /// `data` réduit à `maxPixels` sur son grand côté (jamais agrandi) et encodé en PNG ; `nil` si ce
  /// n'est pas une image. L'orientation EXIF est appliquée : une photo de téléphone ne doit pas se
  /// retrouver couchée une fois ses métadonnées perdues au ré-encodage.
  static func normalized(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let size = pixelSize(of: data)
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(max(size.width, size.height), maxPixels),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }
}
