import AppKit
import Observation

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
  var avatarData: Data? { didSet { defaults.set(avatarData, forKey: Key.avatar) } }

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Premier lancement : on part du nom du compte macOS plutôt que d'un champ vide.
    let fallback = Self.splitFullName(NSFullUserName())
    firstName = defaults.string(forKey: Key.firstName) ?? fallback.first
    lastName = defaults.string(forKey: Key.lastName) ?? fallback.last
    avatarData = defaults.data(forKey: Key.avatar)
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

  var avatarImage: NSImage? { avatarData.flatMap(NSImage.init(data:)) }

  private static func splitFullName(_ name: String) -> (first: String, last: String) {
    let parts = name.split(separator: " ").map(String.init)
    guard let first = parts.first else { return ("", "") }
    return (first, parts.dropFirst().joined(separator: " "))
  }
}
