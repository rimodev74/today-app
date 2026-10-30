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
///
/// ## Elle se révèle DANS la fenêtre, jamais dans un popover
///
/// Un popover était la présentation évidente, et c'est celle qui a été écrite d'abord. Elle tue
/// l'app. Un popover est une FENÊTRE, et SwiftUI ne la présente pas au clic : il la présente depuis
/// `NSHostingView.layout()`, quand les préférences de la fenêtre changent
/// (`PopoverBridge.preferencesDidChange` → `updatePresentations` → `NSPopover.showRelativeToRect:`).
/// Or cette app fait circuler des préférences EN CONTINU — chaque ligne republie son cadre
/// (`TaskRowFrameKey`) à chaque mise en page. Ordonner une fenêtre enfant en plein calcul de layout
/// fait passer AppKit par `addChildWindow:` → `_rebuildOrderingGroup:`, qui réordonne les autres
/// fenêtres du groupe ; l'une d'elles héberge une vue HORS-PROCESS, et
/// `-[NSRemoteView containingWindowWillOrderOnScreen:]` lève une exception. Levée sous
/// `_NSViewLayout`, AppKit la convertit en `+[NSApplication _crashOnException:]` : le process meurt
/// en SIGTRAP, sans message, et le gestionnaire d'exceptions de `CrashLog` ne la voit jamais.
/// Pile complète : `Today-2026-08-06-164404.ips`, geste « ••• → Couleur… » sur une en-tête.
///
/// Ce n'est PAS le menu qui se ferme derrière : mesuré avec un reproducteur AppKit nu, un
/// `NSPopover` présenté dans le même tour de boucle qu'un `NSMenu` qui se ferme passe 12 fois sur
/// 12. C'est bien la présentation DEPUIS le layout qui casse.
///
/// Les trois plantages du 5 août 2026 (cf. `WhenPicker`) sont la même famille, traités alors en
/// refermant le panneau avant d'écrire : un correctif sur le symptôme, qui laissait la fenêtre en
/// jeu. Sans fenêtre du tout, il n'y a plus ni groupe d'ordonnancement, ni vue hors-process, ni
/// ancre à poursuivre quand la ligne bouge. C'est déjà le choix de `QuickFindPanel`, pour la même
/// raison.
struct PalettePicker: View {
  @Binding var selection: PaletteColor?
  /// La pastille « Personnalisée… », pour un porteur qui accepte une couleur libre (un projet).
  /// `nil` = palette seule (une en-tête de section).
  var custom: CustomSlot? = nil
  /// Refermer est au porteur : c'est lui qui tient le booléen de révélation.
  var dismiss: () -> Void

  struct CustomSlot {
    /// La couleur libre en place, `nil` si le porteur est sur la palette ou sans couleur.
    let current: Color?
    /// Ouvre le sélecteur de couleur de macOS.
    let choose: () -> Void
  }

  // Assez petites pour tenir dans une sidebar à sa largeur MINIMALE (200 pt, cf.
  // `ContentView.minSidebarWidth`) : 8 pastilles + le séparateur + les marges y tombent à ~185 pt ;
  // avec la neuvième (« Personnalisée… »), pastilles et écarts se resserrent d'un point pour
  // rester sous cette largeur (~183 pt).
  // ponytail: si la palette gagne encore une couleur, elle déborde — passer en grille deux rangées.
  private var dot: CGFloat { custom == nil ? 13 : 12 }

  var body: some View {
    HStack(spacing: custom == nil ? 3 : 2) {
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
      Divider().frame(height: dot)
      ForEach(PaletteColor.allCases) { option in
        button(color: option) { Circle().fill(option.color) }
      }
      if let custom { customButton(custom) }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
  }

  /// La couleur libre : remplie de sa couleur quand elle est en place (et cerclée, comme une
  /// pastille choisie), arc-en-ciel sinon — le repère du sélecteur de couleur de macOS.
  private func customButton(_ custom: CustomSlot) -> some View {
    Button {
      dismiss()
      custom.choose()
    } label: {
      Group {
        if let current = custom.current {
          Circle().fill(current)
        } else {
          Circle().fill(
            AngularGradient(
              colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
        }
      }
      .frame(width: dot, height: dot)
      .padding(2.5)
      .overlay {
        Circle().strokeBorder(Color.accentColor, lineWidth: custom.current != nil ? 1.5 : 0)
      }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .help("Couleur personnalisée…")
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
        .frame(width: dot, height: dot)
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
