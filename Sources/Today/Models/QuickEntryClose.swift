import Foundation

/// Ce que la capsule fait d'une demande de fermeture. Sorti de la vue pour être testé : la règle
/// tient en trois booléens, et c'est en la mélangeant à du SwiftUI qu'elle s'est trompée.
///
/// **Seul Échap fait un « pas en arrière »** : il referme d'abord le bloc ouvert, puis défait
/// l'étape, puis seulement ferme. Le clic ailleurs, la perte de la clé et le raccourci global rejoué
/// passaient par le même chemin — le premier refermait le bloc des destinations et laissait un
/// panneau fantôme à l'écran (sans clé, donc sans Échap), le second rejouait `backToSearch()` et
/// VIDAIT le brouillon au lieu de le ranger. Toute autre demande ferme VRAIMENT, brouillon gardé.
enum QuickEntryClose {
  enum Outcome: Equatable {
    /// Échap sur un bloc ouvert par-dessus la capsule : on le referme, la capsule reste.
    case collapseBlock
    /// Échap sur la seconde étape : on revient à la recherche, la capsule reste.
    case stepBack
    /// Fermeture accidentelle : le brouillon est rangé, la capsule se ferme.
    case closeKeepingDraft
    /// Échap sur la recherche : annulation volontaire, le brouillon est jeté.
    case closeDiscardingDraft
  }

  static func outcome(discardDraft: Bool, blockOpen: Bool, onSecondStep: Bool) -> Outcome {
    guard discardDraft else { return .closeKeepingDraft }
    if blockOpen { return .collapseBlock }
    if onSecondStep { return .stepBack }
    return .closeDiscardingDraft
  }
}
