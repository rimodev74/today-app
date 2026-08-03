import SwiftUI

/// Le choix d'une couleur, écrit UNE fois pour ses deux porteurs : une en-tête de section
/// (`HeaderRow`) et un projet (`SidebarView`).
///
/// Un popover et PAS un sous-menu, alors que c'est bien un menu qui l'ouvre. Le sous-menu a été
/// écrit d'abord, et il ne marche pas : **un menu contextuel macOS ne dessine pas les icônes de ses
/// items** — les sept lignes sortaient en texte nu, donc sept lignes identiques à lire une par une,
/// exactement ce qu'une pastille doit éviter. Vérifié des deux côtés : dans un menu PRINCIPAL
/// (`CommandMenu`) l'image arrive pourtant intacte jusqu'au `NSMenuItem`, teinte comprise (mesuré :
/// R=1,00 G=0,22 B=0,24 pour `.systemRed`) ; c'est donc le rendu du menu contextuel qui les jette,
/// pas la fabrication de l'image.
///
/// Même conclusion que `SidebarMenu` dans `ContentView`, arrivée par le même chemin : dès qu'une
/// ligne veut autre chose que du texte, on sort du menu AppKit. Et une rangée de pastilles vaut
/// mieux que sept lignes de toute façon : la couleur se choisit à l'œil, en un clic, sans lire.
struct PalettePicker: View {
  @Binding var selection: PaletteColor?
  /// Refermer est au porteur : c'est lui qui tient le `isPresented` du popover.
  var dismiss: () -> Void

  private static let dot: CGFloat = 15

  var body: some View {
    HStack(spacing: 5) {
      // « Par défaut » d'abord, à gauche : c'est l'état de départ de tout projet, et le seul qu'on
      // ne peut pas désigner par une couleur. Le cercle barré dit « aucune », pas « noir ».
      button(color: nil) {
        Circle()
          .strokeBorder(.tertiary, lineWidth: 1.2)
          .overlay {
            Image(systemName: "line.diagonal")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.tertiary)
          }
      }
      Divider().frame(height: Self.dot)
      ForEach(PaletteColor.allCases) { option in
        button(color: option) { Circle().fill(option.color) }
      }
    }
    .padding(8)
  }

  /// Une pastille : le rond, l'anneau de sélection, l'infobulle et le clic. Écrit une fois — les
  /// huit boutons ne diffèrent QUE par leur remplissage.
  @ViewBuilder private func button<Fill: View>(
    color: PaletteColor?, @ViewBuilder fill: () -> Fill
  ) -> some View {
    Button {
      selection = color
      dismiss()
    } label: {
      fill()
        .frame(width: Self.dot, height: Self.dot)
        // L'anneau se pose EN DEHORS du rond (padding + overlay au-delà), sinon il rogne la
        // couleur qu'il est censé désigner et la pastille choisie paraît plus petite que les autres.
        .padding(2.5)
        .overlay {
          Circle()
            .strokeBorder(Color.accentColor, lineWidth: selection == color ? 1.5 : 0)
        }
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help(color?.label ?? "Par défaut")
  }
}
