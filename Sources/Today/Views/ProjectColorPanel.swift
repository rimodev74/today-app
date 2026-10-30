import AppKit
import SwiftData

/// Le sélecteur de couleur de macOS (`NSColorPanel`), branché sur UN projet.
///
/// Natif et pas un sélecteur maison : roue, pipette, champ hexadécimal, couleurs enregistrées de
/// l'utilisateur — tout ce qu'on réécrirait moins bien. Et ce n'est PAS un popover : c'est le
/// panneau partagé de l'app, une vraie fenêtre ouverte depuis l'ACTION d'un bouton, jamais depuis le
/// layout (cf. `PalettePicker` pour ce que ça coûtait). Le singleton ne se détruit jamais : son champ
/// hexadécimal peut prendre le focus sans laisser d'abonnement orphelin (cf. `PIEGES.md` § Fenêtres).
@MainActor
final class ProjectColorPanel: NSObject {
  static let shared = ProjectColorPanel()

  /// Le projet visé, par IDENTIFIANT : le panneau survit au projet (il reste ouvert pendant qu'on
  /// supprime le projet dans la sidebar), et retenir le modèle lui-même ferait écrire dans un
  /// objet effacé.
  private var projectID: PersistentIdentifier?
  private weak var context: ModelContext?

  func open(for project: Project, in context: ModelContext) {
    let panel = NSColorPanel.shared
    // La cible d'abord RETIRÉE : poser la couleur de départ déclenche l'action, qui écrirait sinon
    // cette couleur dans le projet précédent.
    panel.setTarget(nil)
    panel.setAction(nil)
    projectID = project.persistentModelID
    self.context = context
    panel.showsAlpha = false
    // Au relâchement seulement : en continu, chaque image de la roue écrirait la base, relancerait
    // l'autosave et redessinerait la sidebar — pour une couleur qu'on n'a pas encore choisie.
    panel.isContinuous = false
    if case .custom(let hex)? = project.color {
      panel.color = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    } else if let palette = project.color?.palette {
      panel.color = palette.nsColor
    }
    panel.setTarget(self)
    panel.setAction(#selector(colorChanged(_:)))
    panel.orderFront(nil)
  }

  @objc private func colorChanged(_ sender: NSColorPanel) {
    guard let projectID, let context,
      let project: Project = context.registeredModel(for: projectID), !project.isDeleted,
      let hex = ProjectColor.hex(of: sender.color)
    else { return }
    let color = ProjectColor.custom(hex)
    guard project.color != color else { return }
    project.color = color
    try? context.save()
  }
}
