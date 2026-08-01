import SwiftUI

/// La barre d'outils flottante du bas et ses infobulles.
///
/// Utilisée par SIX pages. Elle était définie dans le fichier de la page d'une liste, ce qui laissait
/// croire qu'elle lui appartenait — alors qu'elle est le chrome commun de toute la zone de détail.
/// Barre d'outils flottante du bas, commune à TOUTES les pages (liste, projet, pomodoro, vues à
/// venir) : même capsule Liquid Glass partout. `onNewTask`/`onInsertHeader` sont optionnels — une
/// page projet ou une vue stub n'ont pas de bloc de tâches unique où insérer directement ; le
/// bouton correspondant disparaît alors plutôt que de faire semblant.
struct BottomToolbar: View {
  var onNewTask: (() -> Void)?
  var onInsertHeader: (() -> Void)?
  var onSearch: () -> Void

  var body: some View {
    buttonGroup {
      if let onNewTask {
        toolbarButton(
          "Nouvelle tâche", shortcut: "⌘N",
          description: "Le raccourci clavier crée la tâche et ouvre directement son édition.",
          action: onNewTask
        ) {
          Image(systemName: "plus").font(.app(16)).foregroundStyle(.secondary)
        }
        groupDivider
      }
      if let onInsertHeader {
        toolbarButton(
          "Insérer une en-tête", shortcut: "⌘⇧N",
          description: "Couleur attribuée au hasard, modifiable depuis son menu.",
          action: onInsertHeader
        ) { headerGlyph }
        groupDivider
      }
      toolbarButton("Recherche", action: onSearch) {
        Image(systemName: "magnifyingglass").font(.app(16)).foregroundStyle(.secondary)
      }
    }
    // Capsule flottante centrée : elle garde sa largeur intrinsèque, le frame full-width la centre.
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.bottom, 16)
    // `.overlayPreferenceValue` rend la bulle dans une couche à PART, au-dessus de tout ce bloc —
    // et surtout HORS du `.glassEffect`/`.background` de `buttonGroup` : celui-ci compose son
    // contenu dans une texture bornée à la Capsule, donc une bulle en overlay LOCAL d'un bouton
    // (essayé d'abord) se faisait rogner par ce bord dès qu'elle dépassait vers le haut.
    .overlayPreferenceValue(ToolbarTooltipKey.self) { request in
      if let request { ToolbarTooltipOverlay(request: request) }
    }
  }

  /// « Button group » flottant : une capsule unique posée au-dessus du contenu, toutes les actions
  /// regroupées dedans, séparées par des traits internes. Rendu Liquid Glass natif via `.glassEffect`
  /// (bouts arrondis + réfraction + ombre portée fournis par le système), `.interactive()` fait réagir
  /// le verre au survol/press. Repli material + ombre sous macOS 26 (Package.swift cible .v14, donc
  /// le `#available` est obligatoire — le compilateur refuse l'API sinon).
  @ViewBuilder
  private func buttonGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    let base = HStack(spacing: 3) { content() }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
    if #available(macOS 26, *) {
      base.glassEffect(.regular.interactive(), in: Capsule())
    } else {
      base
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }
  }

  private var groupDivider: some View {
    Divider().frame(height: 20)
  }

  private func toolbarButton<Icon: View>(
    _ help: String, shortcut: String? = nil, description: String? = nil,
    action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon
  ) -> some View {
    ToolbarButton(
      help: help, shortcut: shortcut, description: description, action: action, icon: icon)
  }

  /// Lettre « T » dans un carré à bordure fine : remplace l'icône générique pour signifier
  /// « insérer un intertitre texte ». `Color.primary` pour le trait ET la lettre — s'inverse tout
  /// seul entre light et dark mode, pas de couleur figée à adapter à la main.
  private var headerGlyph: some View {
    Text("T")
      .font(.app(12, weight: .bold, design: .rounded))
      .foregroundStyle(.primary)
      .frame(width: 19, height: 19)
      .overlay {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
          .strokeBorder(Color.primary, lineWidth: 1.2)
      }
  }
}

/// Un bouton de la toolbar : fond arrondi + léger agrandissement au survol, et curseur en main
/// (même geste que la sidebar). État `hovering` propre à CHAQUE bouton — c'est pour ça que c'est
/// une vue à part (une méthode ne peut pas porter de `@State`), sinon tous les boutons du groupe
/// auraient partagé un seul et même survol.
private struct ToolbarButton<Icon: View>: View {
  var help: String
  /// Non nil ⇒ bulle façon Reminders.app (titre + raccourci + description) au survol, à la place
  /// du tooltip système `.help` — ce style précis (gras, badge aligné, texte secondaire) n'est pas
  /// exposé par l'API AppKit publique, cf. `RichTooltip`.
  var shortcut: String? = nil
  var description: String? = nil
  var action: () -> Void
  @ViewBuilder var icon: () -> Icon

  @State private var hovering = false
  @State private var showTooltip = false

  var body: some View {
    let button = Button(action: action) {
      icon()
        .frame(width: 41, height: 33)
        .contentShape(Rectangle())
        // Capsule, pas un rectangle arrondi : le fond de survol doit reprendre le langage très
        // arrondi de la pilule qui l'englobe (`buttonGroup`), pas une forme plus carrée qui jure
        // avec elle.
        .background(hovering ? Color.primary.opacity(0.09) : .clear, in: Capsule())
        .scaleEffect(hovering ? 1.08 : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(help)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { inside in
      hovering = inside
      inside ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
      guard shortcut != nil else { return }
      if inside {
        // Même délai qu'un tooltip système avant apparition ; `hovering` revérifié à l'échéance
        // au cas où la souris serait déjà repartie entre-temps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          if hovering {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { showTooltip = true }
          }
        }
      } else {
        withAnimation(.easeOut(duration: 0.1)) { showTooltip = false }
      }
    }

    if let shortcut {
      button.anchorPreference(key: ToolbarTooltipKey.self, value: .bounds) { anchor in
        showTooltip
          ? ToolbarTooltipRequest(
            title: help, shortcut: shortcut, description: description ?? "", anchor: anchor)
          : nil
      }
    } else {
      button.help(help)
    }
  }
}

/// Contenu + ancre (position du bouton survolé) transmis par `ToolbarButton` à `BottomToolbar`,
/// qui rend la bulle hors du groupe de boutons — cf. commentaire sur `.overlayPreferenceValue`.
private struct ToolbarTooltipRequest {
  var title: String
  var shortcut: String
  var description: String
  var anchor: Anchor<CGRect>
}

private struct ToolbarTooltipKey: PreferenceKey {
  static let defaultValue: ToolbarTooltipRequest? = nil
  static func reduce(value: inout ToolbarTooltipRequest?, nextValue: () -> ToolbarTooltipRequest?) {
    if let next = nextValue() { value = next }
  }
}

/// Convertit l'ancre du bouton en position réelle (le `GeometryReader` fournit l'espace de coords
/// de `BottomToolbar`), puis pose la bulle juste au-dessus, centrée sur le bouton. `measuredHeight`
/// affiné au premier layout (`onAppear`/`onChange` sur sa propre taille) : sans ça, centrer la bulle
/// par rapport à SA PROPRE hauteur avant de la connaître la ferait d'abord apparaître mal calée.
private struct ToolbarTooltipOverlay: View {
  var request: ToolbarTooltipRequest
  @State private var measuredHeight: CGFloat = 70

  var body: some View {
    GeometryReader { proxy in
      let anchor = proxy[request.anchor]
      RichTooltip(
        title: request.title, shortcut: request.shortcut, description: request.description
      )
      .background {
        GeometryReader { size in
          Color.clear
            .onAppear { measuredHeight = size.size.height }
            .onChange(of: size.size.height) { _, new in measuredHeight = new }
        }
      }
      .position(x: anchor.midX, y: anchor.minY - 14 - measuredHeight / 2)
      .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
    }
  }
}

/// Bulle d'aide façon Reminders.app : titre en gras, raccourci aligné à droite sur la même ligne,
/// description secondaire en dessous. PAS le tooltip système (`.help`, texte plat sans mise en
/// forme ni badge) — cette mise en page précise n'est pas exposée par l'API AppKit publique, donc
/// reconstruite à la main. Décor seulement : aucune interaction, jamais de premier plan aux clics.
private struct RichTooltip: View {
  var title: String
  var shortcut: String
  var description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(title).font(.app(13, weight: .semibold))
        Spacer(minLength: 8)
        Text(shortcut)
          .font(.app(12))
          .foregroundStyle(.secondary)
      }
      if !description.isEmpty {
        Text(description)
          .font(.app(12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .frame(width: 220, alignment: .leading)
    // Matériau et PAS un gris figé (#F5F6F7 auparavant) : en sombre, ce fond clair restait clair
    // sous un texte `.primary` devenu blanc — bulle illisible. `.regularMaterial` est déjà la
    // surface flottante de l'app (cf. la carte de `QuickFindPanel`) et suit les deux apparences.
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    .allowsHitTesting(false)
  }
}
