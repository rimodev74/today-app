// La ligne d'un en-tête de section : titre, couleur, repli, et son propre glisser (il emmène les
// tâches de son bloc). Sortie de `TaskListView.swift` — cf. l'en-tête de `TaskRow.swift`.

import AppKit
import SwiftData
import SwiftUI

/// En-tête de section dans la liste. La pilule lavande (ou teintée si une `PaletteColor` est
/// choisie) est TOUJOURS visible, repos comme sélection/édition — ce n'est plus un indicateur de
/// sélection mais l'apparence permanente de l'en-tête. Le ••• apparaît au survol ou en
/// sélection/édition ; en édition le champ devient actif + focus (curseur de saisie).
/// - **drag** : la pilule est portée sous le curseur, avec DERRIÈRE elle des calques en cascade
///   (un par tâche rattachée, plafonné à 3, de plus en plus petits et pâles) et, en haut à gauche,
///   une bulle rouge portant le nombre RÉEL de tâches emportées.
struct HeaderRow: View {
  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  let isDragging: Bool
  /// Nombre réel de tâches rattachées, connu seulement pendant le drag (0 sinon).
  let attachedTaskCount: Int
  /// Autres listes où déplacer l'en-tête (et son bloc). Vide ⇒ entrée de menu désactivée.
  let moveTargets: [TodoList]
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onCopy: () -> Void
  var onDelete: () -> Void

  @FocusState private var titleFocused: Bool
  @State private var hovering = false
  /// Bascule brièvement l'icône de copie en checkmark après un clic, pour confirmer visuellement
  /// que le texte est bien dans le presse-papiers (sinon rien à l'écran ne le montre).
  @State private var copied = false
  /// Palette ouverte. Le choix d'une couleur ne tient pas dans un menu : cf. `PalettePicker`.
  @State private var pickingColor = false

  /// Cascade du drag : décalage vertical d'un calque et retrait horizontal (plus étroit, centré) par
  /// niveau. Couleurs OPAQUES, du même bleu, de plus en plus claires — assez SATURÉES pour se lire
  /// comme des cartes (des tons quasi blancs ne montraient que leur ombre → aspect brouillon).
  private static let layerStep: CGFloat = 7
  private static let layerInset: CGFloat = 6

  /// Marges de la RANGÉE autour de la pilule. Nommées parce que `dragPlaceholderRect` les retire :
  /// une en-tête, contrairement à une tâche, porte ses marges À L'EXTÉRIEUR de son fond — le trou
  /// d'insertion doit valoir la pilule qu'on transporte, pas la rangée qui la contient.
  static let topInset: CGFloat = 20
  static let bottomInset: CGFloat = 4

  /// Les trois teintes de la cascade, du calque le plus proche au plus lointain.
  ///
  /// Elles doivent rester OPAQUES (les calques se recouvrent : la moindre translucidité les ferait
  /// transparaître les uns à travers les autres), donc figées, donc à doubler pour le mode sombre —
  /// même contrainte et même solution que `SidebarView.rowFill`. Sans ce doublon, tout le drag
  /// d'en-tête s'affichait en bleu pâle de mode clair par-dessus une page sombre.
  ///
  /// Les valeurs claires sont celles de la maquette Things. Les sombres ne sont pas inventées : ce
  /// sont les équivalents OPAQUES de la pilule AU REPOS en sombre (`thingsSelectionFill`, soit
  /// l'accent à 28 % sur le fond de page), déclinés dans les mêmes proportions que les claires. La
  /// pilule tirée garde donc exactement la teinte perçue qu'elle a au repos, et le titre en accent
  /// y conserve la lisibilité qu'il avait déjà — aucun pari de contraste à prendre.
  private static let dragTop = dragLayer(light: 0xCA_E1FF, dark: 0x18_3A5D)
  private static let dragLayer1 = dragLayer(light: 0xDC_EAFF, dark: 0x1A_3149)
  private static let dragLayer2 = dragLayer(light: 0xEA_F1FF, dark: 0x1C_2937)

  private static func dragLayer(light: Int, dark: Int) -> Color {
    func srgb(_ hex: Int) -> NSColor {
      NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
    }
    return Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb(dark) : srgb(light)
      })
  }

  var body: some View {
    let active = isSelected || isEditing
    // Calques DERRIÈRE l'en-tête : 2 au plus, pour un total de 3 avec l'en-tête (elle + deux calques
    // de plus en plus transparents). Le compte réel vit dans la bulle rouge, pas dans la pile.
    let layers = min(max(attachedTaskCount, 0), 2)
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        // Calques en cascade DERRIÈRE la pilule (dessinés avant elle), décalés vers le bas et
        // rétrécis. Chacun est une pilule périwinkle OPAQUE globalement atténuée : nettement visible
        // (pas noyée comme un simple lavande translucide) mais de plus en plus transparente.
        if isDragging {
          // Du plus LOINTAIN au plus proche : le calque le plus décalé/clair est dessiné en premier
          // (donc DERRIÈRE), sinon il passait par-dessus le plus proche et la cascade s'inversait.
          ForEach(Array((0..<layers).reversed()), id: \.self) { i in
            let step = CGFloat(i + 1)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(i == 0 ? Self.dragLayer1 : Self.dragLayer2)
              // Plus étroit (centré) + décalé vers le bas → l'empilement de papiers. Ombre propre et
              // douce par calque : chaque carte se détache de celle du dessous, proprement.
              .padding(.horizontal, step * Self.layerInset)
              .offset(y: step * Self.layerStep)
              .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
              // Apparition/disparition NETTE (pas de fondu) : au drop, un fondu de sortie suivrait
              // l'en-tête en vol et se lirait comme une doublure fantôme.
              .transition(.identity)
          }
        }
        pill(active: active)
      }
    }
    .padding(.top, Self.topInset)
    .padding(.bottom, Self.bottomInset)
    // Bulle rouge du compte réel, en haut à gauche de la pilule (elle déborde le coin).
    .overlay(alignment: .topLeading) {
      if isDragging && attachedTaskCount > 0 {
        Text("\(attachedTaskCount)")
          .font(.app(11, weight: .bold))
          .foregroundStyle(.white)
          .frame(minWidth: 20, minHeight: 20)
          .background(Circle().fill(Color.red))
          .offset(x: -6, y: 12)
          .transition(.identity)  // disparaît net au drop, pas de fondu fantôme
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    // Le champ existe déjà au repos : le focus ne peut se poser à son .onAppear. On le pose/retire
    // au basculement d'état (comme TaskRow).
    .onChange(of: isEditing) { _, editing in titleFocused = editing }
  }

  /// Le corps de l'en-tête : titre + menu, sur une pilule lavande quand elle est active.
  private func pill(active: Bool) -> some View {
    HStack(spacing: 8) {
      // TOUJOURS le même TextField (repos comme édition) : identité de vue stable, pas de bascule
      // Text↔TextField qui « recharge » le titre. Au repos il ne capte pas les clics — ils vont au
      // geste de la page (sélection, drag) — et l'édition le rend actif + focus (curseur).
      TextField("Nouvel en-tête", text: $task.title)
        .textFieldStyle(.plain)
        .font(.app(.headline))
        .foregroundStyle((task.headerColor?.color ?? Color.accentColor).opacity(0.85))
        .focused($titleFocused)
        .allowsHitTesting(isEditing)
        .onSubmit(onEndEditing)
      Spacer(minLength: 0)
      // Copie texte du bloc entier (en-tête + tâches rattachées) dans le presse-papiers, sans
      // passer par le menu ; mêmes conditions d'apparition que le •••, juste à sa gauche. Checkmark
      // temporaire au clic : la copie est silencieuse côté système, sans ce retour rien ne confirme
      // à l'utilisateur qu'elle a eu lieu.
      Button {
        onCopy()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.app(11, weight: .semibold))
          .foregroundStyle(.secondary)
          // Largeur figée : "doc.on.doc" et "checkmark" n'ont pas la même largeur intrinsèque, sans
          // ce cadre la pilule respire d'un pixel ou deux au moment du bascule.
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
      .opacity((hovering || active || copied) && !isDragging ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: copied)
      .help("Copier l'en-tête et ses tâches")
      Menu {
        menuItems
      } label: {
        Image(systemName: "ellipsis")
          .font(.app(14, weight: .semibold))
          .foregroundStyle(Color.accentColor.opacity(0.85))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      // La palette s'ancre sur le ••• : c'est de lui qu'elle est ouverte, dans les deux chemins
      // (le menu du bouton et le clic droit partagent `menuItems`).
      .popover(isPresented: $pickingColor, arrowEdge: .bottom) {
        PalettePicker(selection: $task.headerColor, dismiss: { pickingColor = false })
      }
      // ••• visible en survol et à l'état actif, mais pas pendant le drag (la pilule est en vol).
      .opacity((hovering || active) && !isDragging ? 1 : 0)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
    .background {
      // La pilule est TOUJOURS visible (plus un indicateur de sélection) : c'est l'apparence
      // permanente de l'en-tête. Pendant le drag, l'en-tête est le calque du DESSUS de la
      // cascade : couleur OPAQUE dédiée (#CAE1FF), sinon les calques derrière transparaissent à
      // travers. Hors drag, le lavande translucide (comme une tâche sélectionnée) suffit, ou la
      // teinte choisie si définie. Ombre de soulevé seulement au drag.
      // ponytail: opacité fixe (0.22) plutôt que le double palier clair/sombre de
      // `thingsSelectionFill` — à aligner si l'écart se voit trop en mode sombre.
      let tinted = task.headerColor.map { AnyShapeStyle($0.color.opacity(0.22)) }
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isDragging
            ? AnyShapeStyle(Self.dragTop) : (tinted ?? AnyShapeStyle(thingsSelectionFill))
        )
        .shadow(color: .black.opacity(isDragging ? 0.14 : 0), radius: 6, y: 3)
    }
    // Même règle que le cadre de notes : la pilule est TOUJOURS visible, c'est donc son BORD qui
    // s'aligne sur la colonne (case à cocher, anneau, ＋), pas son titre. Le fond de sélection d'une
    // tâche, lui, reste 10 pt plus à gauche — il n'apparaît qu'au clic et doit dégager la case.
    .padding(.leading, rowInset)
    // Clic droit = le même jeu d'actions que le •••, qui n'apparaît qu'au survol : sans ça,
    // supprimer une en-tête demandait de viser un bouton invisible au repos.
    .contextMenu { menuItems }
  }

  /// Les actions d'une en-tête, écrites une fois pour ses deux points d'entrée (••• et clic droit).
  @ViewBuilder private var menuItems: some View {
    Button("Couleur…") { pickingColor = true }
    Menu {
      if moveTargets.isEmpty {
        Text("Aucune autre liste")
      } else {
        ForEach(moveTargets) { target in
          Button(target.title) { onMove(target) }
        }
      }
    } label: {
      Text("Déplacer vers…")
    }
    Divider()
    Button("Supprimer", role: .destructive, action: onDelete)
  }
}
