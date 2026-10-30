import SwiftUI

// Un panneau — « Quand », le rappel d'une tâche, la date d'une liste — révélé DANS la fenêtre,
// ancré à ce qui l'a ouvert. Ce que `.popover` et `.sheet` faisaient, sans fenêtre.
//
// ## Pourquoi pas une fenêtre
//
// Un popover est une FENÊTRE, et SwiftUI la présente depuis `NSHostingView.layout()` : dans cette
// app, qui fait circuler des préférences en continu, ça tue le process (SIGTRAP sans un mot,
// `PIEGES.md` § Fenêtres). Une feuille est une fenêtre aussi, et celle du rappel portait un champ
// Titre et deux champs d'heure : chaque fermeture jetait une fenêtre qui avait hébergé un champ
// focalisé — la moitié « ne pas jeter une fenêtre qui a hébergé un champ » des 27 plantages
// d'août 2026. Ici, le premier répondeur vit dans la fenêtre principale, toujours à l'écran : c'est
// précisément ce qui rend sûrs les champs du rappel.
//
// C'est le choix de `PalettePicker` et de `QuickFindPanel`, pour la même raison. La palette se
// déplie DANS sa pilule ; ces trois-là sont trop hauts pour ça (300 à 450 pt) — ils passent donc
// par-dessus les rangées voisines, d'où l'hôte au niveau de la PAGE.
//
// ## Qui tient quoi
//
// - **L'état « ouvert » reste à celui qui ouvre** (un `@State` de la rangée, de la page) : c'est sa
//   fermeture qui le remet à faux, et sa disparition qui l'emporte — une rangée démontée, une page
//   quittée, et le panneau n'existe plus.
// - **Il se DÉCLARE par une préférence d'ancre** (`pagePanel`), posée seulement tant qu'il est
//   ouvert : une rangée fermée ne publie rien, et aucune rangée ne lit quoi que ce soit de l'hôte —
//   ouvrir un panneau ne rejoue que la rangée qui l'ouvre.
// - **L'hôte le DESSINE** (`PagePanelHost`, posé par `taskPageBase`) : par-dessus la page, hors du
//   `ScrollView`, donc jamais rogné ; borné à la zone de la page, retourné au-dessus de son ancre
//   s'il déborde en bas (`PanelPlacement`).

/// Le fondu d'entrée et de sortie d'un panneau. Court, et pas un ressort : c'est un geste courant
/// (cf. `CLAUDE.md` § Animations). Celui de `QuickFindPanel`, l'autre panneau de la fenêtre.
let pagePanelFade = Animation.easeOut(duration: 0.12)

/// Ce que les moniteurs d'événements de la PAGE doivent savoir : un panneau est-il ouvert ?
///
/// Tant qu'il l'est, ils se taisent (`LeftClickOutsideObserver`, `RightClickObserver`,
/// `TaskKeyMonitor`). Un popover vivait dans SA fenêtre et les moniteurs l'ignoraient d'eux-mêmes
/// (`event.window == view.window`) ; un panneau dans la fenêtre principale, non — un clic sur un
/// jour tomberait hors de toute ligne et refermerait la carte qui l'a ouvert, ⌫ supprimerait la
/// tâche sélectionnée derrière lui.
///
/// Une classe tenue par référence et lue AU MOMENT de l'événement, pas un état observé : aucun
/// corps ne la lit, son écriture n'invalide donc rien, et les moniteurs n'ont pas à attendre une
/// mise à jour de leur vue pour savoir.
@MainActor
final class PagePanelPresence {
  var isPresented = false
  /// Referme le panneau montré — pour ce qui s'ouvre PAR-DESSUS la page (la recherche ⌘K) : sans
  /// ça, le premier Échap fermait le panneau caché derrière au lieu de la palette visible.
  var closeShown: (() -> Void)?

  /// Postée par la fenêtre quand elle révèle quelque chose au-dessus de la page.
  static let closeRequest = Notification.Name("PagePanelPresence.closeRequest")
}

private struct PagePanelPresenceKey: EnvironmentKey {
  static let defaultValue: PagePanelPresence? = nil
}

extension EnvironmentValues {
  /// Posée par `PagePanelHost` sur la page qu'il coiffe. `nil` hors d'une page de tâches : les
  /// moniteurs y gardent leur comportement d'origine.
  var pagePanelPresence: PagePanelPresence? {
    get { self[PagePanelPresenceKey.self] }
    set { self[PagePanelPresenceKey.self] = newValue }
  }
}

/// Un panneau qui se déclare ouvert : où il s'ancre, ce qu'il montre, comment le refermer.
struct PagePanel: Equatable {
  /// Nomme la CIBLE (« when.<uuid de la tâche> ») : deux panneaux de même id sont le même panneau.
  let id: String
  let anchor: Anchor<CGRect>
  let alignment: PanelPlacement.Alignment
  let content: () -> AnyView
  let close: () -> Void

  /// Sans les fermetures, qui ne se comparent pas. L'ancre en fait partie : la rangée qui bouge
  /// doit redéplacer le panneau.
  static func == (a: PagePanel, b: PagePanel) -> Bool {
    a.id == b.id && a.anchor == b.anchor
  }
}

struct PagePanelKey: PreferenceKey {
  /// Calculée et pas stockée : une valeur statique d'un type non `Sendable` (il porte des
  /// fermetures) serait un état global partagé aux yeux de la concurrence stricte.
  static var defaultValue: [PagePanel] { [] }

  /// TOUS, et pas le premier venu : deux panneaux peuvent se déclarer ouverts le temps d'une passe,
  /// et c'est à l'hôte de trancher lequel reste (`PanelStack`).
  static func reduce(value: inout [PagePanel], nextValue: () -> [PagePanel]) {
    value += nextValue()
  }
}

extension View {
  /// Révèle `content` DANS la page, ancré à cette vue, tant que `isPresented` est vrai. Remplace
  /// `.popover(isPresented:)` — cf. l'en-tête de ce fichier.
  ///
  /// Il faut un `PagePanelHost` au-dessus (`taskPageBase` en pose un) ; sans lui la déclaration
  /// remonte dans le vide et rien ne s'affiche.
  ///
  /// La fermeture passe par `pagePanelFade`. L'OUVERTURE aussi doit y passer — c'est à l'appelant
  /// d'envelopper son `isPresented = true` (cf. CLAUDE.md § Animations : la transition est
  /// déclenchée par qui la provoque).
  func pagePanel<Panel: View>(
    id: String, isPresented: Binding<Bool>, alignment: PanelPlacement.Alignment,
    @ViewBuilder content: @escaping () -> Panel
  ) -> some View {
    background {
      // Monté seulement quand il est ouvert : une rangée fermée ne publie rien, à aucune passe.
      if isPresented.wrappedValue {
        Color.clear.anchorPreference(key: PagePanelKey.self, value: .bounds) { anchor in
          [
            PagePanel(
              id: id, anchor: anchor, alignment: alignment,
              content: { AnyView(content()) },
              close: { withAnimation(pagePanelFade) { isPresented.wrappedValue = false } })
          ]
        }
      }
    }
  }
}

/// Dessine, au-dessus de la page, le panneau qui s'y déclare ouvert (cf. `View.pagePanel`).
///
/// Il se referme sur un clic hors de lui, Échap, la molette, ou quand celui qui l'a ouvert
/// disparaît. Le choix fait à l'intérieur le referme aussi — c'est son contenu qui en décide, comme
/// avant.
struct PagePanelHost: ViewModifier {
  /// Le panneau montré jusqu'ici — sert à trancher quand un second se déclare (`PanelStack`).
  @State private var shownID: String?
  /// Stable pour la vie de la page : posée une fois dans l'environnement, jamais remplacée.
  @State private var presence = PagePanelPresence()

  func body(content: Content) -> some View {
    content
      // Sur le CONTENU, pas sur le panneau : ce sont les moniteurs de la page qui doivent se taire,
      // pas ceux qui referment le panneau.
      .environment(\.pagePanelPresence, presence)
      .onPreferenceChange(PagePanelKey.self) { panels in
        let resolved = PanelStack.resolve(open: panels.map(\.id), shown: shownID)
        for panel in panels where resolved.closing.contains(panel.id) { panel.close() }
        presence.isPresented = resolved.shown != nil
        presence.closeShown = panels.first(where: { $0.id == resolved.shown })?.close
        if shownID != resolved.shown { shownID = resolved.shown }
      }
      .onReceive(NotificationCenter.default.publisher(for: PagePanelPresence.closeRequest)) { _ in
        presence.closeShown?()
      }
      .overlayPreferenceValue(PagePanelKey.self) { panels in
        // `panels.last` le temps de la première passe, avant que `shownID` ne l'ait rattrapé : le
        // panneau paraît dans la transaction qui l'ouvre, donc avec son fondu.
        if let panel = panels.first(where: { $0.id == shownID }) ?? panels.last {
          GeometryReader { proxy in
            PagePanelLayout(anchor: proxy[panel.anchor], alignment: panel.alignment) {
              PagePanelChrome(close: panel.close, content: panel.content)
                .id(panel.id)
            }
          }
          .transition(.opacity)
        }
      }
  }
}

/// Pose son unique sous-vue à sa taille idéale, à l'endroit que dit `PanelPlacement`.
///
/// Un `Layout` et pas une mesure : la taille du panneau se lit au placement, sans `GeometryReader`
/// qui réécrirait un `@State` à chaque passe (cf. `CLAUDE.md` § Ce qui se rend à chaque image).
private struct PagePanelLayout: Layout {
  let anchor: CGRect
  let alignment: PanelPlacement.Alignment

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let panel = subviews.first else { return }
    let size = panel.sizeThatFits(.unspecified)
    let frame = PanelPlacement.frame(
      of: size, anchoredTo: anchor, alignment: alignment, in: bounds.size)
    panel.place(
      at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
      anchor: .topLeading, proposal: ProposedViewSize(size))
  }
}

/// L'habit du panneau, et ce qui le referme.
///
/// Le même verre que `QuickFindPanel`, l'autre panneau de la fenêtre : un matériau système, donc
/// juste dans les deux thèmes sans rien doubler.
private struct PagePanelChrome: View {
  let close: () -> Void
  let content: () -> AnyView

  private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

  var body: some View {
    content()
      .background(.regularMaterial, in: Self.shape)
      .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
      // Un clic dans les marges du panneau ne doit pas traverser jusqu'à la rangée dessous : il la
      // sélectionnerait, ou empoignerait un glissement.
      .contentShape(Self.shape)
      .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
      // Les trois sorties, au cadre du panneau (les deux premières ne réagissent qu'au-DEHORS).
      // Montées avec lui, démontées avec lui : rien ne reste installé panneau fermé.
      .background {
        LeftClickOutsideObserver(onClick: { _ in close() }, outsideOnly: true)
      }
      .background { ScrollDismissObserver(onScroll: close) }
      .background { EscapeKeyMonitor(onEscape: close) }
  }
}
