import Foundation

/// Les écrans de l'accueil du premier lancement, dans l'ordre où on les traverse.
enum OnboardingStep: Int, CaseIterable {
  case welcome
  case profile
  case appearance
  case quickEntry
  case reminders
  case ready

  var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
  var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Ce qui décide de l'accueil, hors de toute vue (cf. `OnboardingView`, qui ne fait qu'orchestrer).
enum Onboarding {
  static let completedStorageKey = "onboardingCompleted"

  enum Decision: Equatable {
    /// Une vraie première installation : l'accueil s'affiche.
    case present
    /// Le drapeau manque mais la base porte déjà du travail. C'est une MISE À JOUR vers la première
    /// version qui a un accueil, pas une installation : on écrit le drapeau sans rien montrer. Sans
    /// ce cas, chaque base existante aurait vu « Bonjour » au premier lancement après Sparkle.
    case markCompleted
    /// Déjà vu.
    case none
  }

  static func decide(completed: Bool, hasExistingData: Bool) -> Decision {
    guard !completed else { return .none }
    return hasExistingData ? .markCompleted : .present
  }

  /// Les touches à dessiner pour une combinaison, lues dans son libellé : « ⌃⌥Espace » donne
  /// `["⌃", "⌥", "Espace"]`. Le libellé est la seule écriture lisible déjà stockée (cf.
  /// `GlobalHotKey.label`) — la reconstruire depuis le code de touche ferait deux vérités.
  static func keycaps(for label: String) -> [String] {
    let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
    let caps = label.prefix(while: modifiers.contains).map(String.init)
    let key = String(label.drop(while: modifiers.contains))
    return key.isEmpty ? caps : caps + [key]
  }
}
