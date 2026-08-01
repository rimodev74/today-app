import AppKit
import SwiftUI

/// Le vocabulaire commun des pages de tâches : métriques, icône de bandeau, fondu d'ouverture,
/// courbes d'animation, teinte de sélection, geste de ligne.
///
/// Il vivait dans `TaskListView.swift`, c'est-à-dire dans le fichier d'UNE page, alors que cinq à
/// six autres s'en servent (« Aujourd'hui », « Tâches », « À venir », « Archives », Pomodoro). Une
/// page qui s'ajoute se construit AVEC ces briques ; les trouver ici plutôt que dans la page d'une
/// liste est ce qui rend cette règle évidente au lieu d'être une consigne à retenir.

/// Marge latérale du contenu du panneau de détail. Interne (pas `private`) : `ArchivePageView`
/// vit dans son propre fichier et doit se caler sur la même marge que les pages de liste.
let gutter: CGFloat = 75

/// Retrait interne d'une ligne de tâche : la respiration du fond de sélection, entre le bord de
/// section et la case à cocher. C'est lui qui définit la colonne des cases — donc celle sur
/// laquelle l'en-tête de page doit se caler (cf. `pageHeader`), sinon le titre de la page flotte
/// 10 pt à gauche de toutes les tâches qu'il coiffe.
let rowInset: CGFloat = 10

/// Icône d'un bandeau de page (« Tâches », « Aujourd'hui », « Archives »). Dessinée à la taille du
/// titre, mais LARGEUR de layout figée à celle d'une `TaskCheckbox` et alignée à gauche : le glyphe
/// débordera de quelques points dans l'espace qui suit (SwiftUI ne rogne pas), ce qui est exactement
/// l'effet voulu — la colonne reste juste des deux côtés, bord gauche sur celui des cases à cocher et
/// titre de page sur celui des titres de tâche, quel que soit le symbole (une étoile est plus large
/// qu'une coche). Sans ce cadrage, chaque page décale son titre d'une valeur différente.
struct PageHeaderIcon: View {
  let systemImage: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.app(.title2))
      .foregroundStyle(tint)
      .frame(width: 16, alignment: .leading)
  }
}

/// Le lavande de sélection de Things : #D1DFFC. Teinte de l'accent système, translucide, résolue par
/// apparence : périwinkle clair sur fond blanc, bleu voilé sur fond sombre — et suit la couleur
/// d'accent choisie par l'utilisateur. Plus opaque en sombre : sur le fond navy, une même alpha
/// rendrait la sélection quasi invisible. Partagé par la sélection d'une tâche, d'une en-tête, et
/// les calques en cascade du drag d'en-tête.
///
/// Non privée : son propre commentaire disait déjà « partagé », elle ne l'était que par accident de
/// fichier. C'est sa place ici, avec les autres jetons de style communs, qui rend ça vrai.
let thingsSelectionFill = Color(
  nsColor: NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.28 : 0.18)
  })

/// Transitions des états d'une tâche (normal ↔ select ↔ edit). Déclenchées en EXPLICITE
/// (`withAnimation` côté parent), jamais en `.animation(value:)` par ligne : ainsi une ligne
/// au repos ne porte aucun modificateur d'animation à traquer, et le scroll reste fluide.
/// `taskFlow` = la Material standard de l'index.html de référence.
// Internes et non `private` : « Aujourd'hui » pilote les mêmes transitions sur les mêmes
// `TaskRow` — deux courbes distinctes se verraient au passage d'une page à l'autre.
let taskFlow = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
let taskSelectFade = Animation.easeOut(duration: 0.05)
/// Apparition (création) ET disparition (suppression) d'une ligne : ressort peu amorti pour un
/// léger rebond, dans les deux sens. Le réordonnancement, lui, passe par des offsets et pas des
/// insertions/suppressions — la transition des rangées n'y répond donc jamais.
/// Interne pour la même raison que `gutter` : `ArchivePageView` anime ses sorties de ligne avec.
let taskInsert = Animation.spring(response: 0.32, dampingFraction: 0.62)

/// Sélection au mouseDOWN + édition au clic sur une ligne DÉJÀ sélectionnée, en UN SEUL geste —
/// pour les pages sans réordonnancement (« Tâches », « Aujourd'hui »).
///
/// SURTOUT PAS deux gestes séparés (`.onTapGesture(count: 2)` pour l'édition + `.onTapGesture`
/// pour la sélection) : dès qu'une vue porte un tap double, AppKit RETIENT le tap simple le temps
/// de la fenêtre de double-clic avant de le délivrer. La surbrillance n'arrivait donc qu'une
/// demi-seconde après le clic — c'était toute la lenteur d'« Aujourd'hui », que les pages de liste
/// n'ont jamais eue parce qu'elles fusionnent déjà tout dans leur geste de drag (même structure
/// ici, moins le réordonnancement — cf. `ListPageView.dragGesture`).
struct RowPressGesture: ViewModifier {
  let isSelected: Bool
  let isEditing: Bool
  var onSelect: () -> Void
  var onEdit: () -> Void

  /// Appui en cours (le premier `onChanged` est le mouseDown) et état de sélection d'AVANT cet
  /// appui : c'est lui qui décide si le relâchement ouvre l'édition (renommage façon Finder).
  @State private var pressing = false
  @State private var wasSelected = false

  func body(content: Content) -> some View {
    content.gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !pressing else { return }
          pressing = true
          wasSelected = isSelected
          if !isEditing && !isSelected { onSelect() }
        }
        .onEnded { value in
          pressing = false
          let moved = abs(value.translation.width) > 4 || abs(value.translation.height) > 4
          guard !moved, !isEditing, wasSelected else { return }
          onEdit()
        },
      // En édition, les clics et les sélections de texte appartiennent au champ.
      including: isEditing ? .subviews : .all
    )
  }
}

extension View {
  func rowPressGesture(
    isSelected: Bool, isEditing: Bool, onSelect: @escaping () -> Void,
    onEdit: @escaping () -> Void
  ) -> some View {
    modifier(
      RowPressGesture(
        isSelected: isSelected, isEditing: isEditing, onSelect: onSelect, onEdit: onEdit))
  }
}

// MARK: - Le socle commun d'une page de tâches

/// Ce que TOUTE page de tâches doit savoir faire, posé une fois.
///
/// Historiquement, chaque page recevait ses gestes au coup par coup : la page d'une liste avait ⌫,
/// le glisser et le clic dans le vide ; « Aujourd'hui » et « Tâches » n'avaient rien. La même
/// touche donnait donc des résultats différents d'un onglet à l'autre, sans qu'aucune règle ne le
/// justifie.
///
/// La règle est désormais l'inverse : **une base unique, puis des contraintes ajoutées au cas par
/// cas**. Une page qui ne sait pas supprimer passe une action qui ne fait rien — elle ne fait pas
/// DISPARAÎTRE le geste.
///
/// ## Ce qu'il ne fait PAS encore : le clic dans le vide
///
/// Il ne porte que le CLAVIER. Le clic qui relâche la sélection demande de savoir si le point cliqué
/// est tombé sur une ligne — donc de connaître le cadre de chaque ligne. Seule la page d'une liste
/// les mesure aujourd'hui (`rowFrames`, pour son glisser), et elle garde donc son propre
/// `LeftClickOutsideObserver`.
///
/// Un fond transparent posé derrière la page NE MARCHE PAS, et c'est déjà écrit noir sur blanc dans
/// l'en-tête de `LeftClickOutsideObserver` : le ScrollView capte les clics de toute sa surface, et
/// un fond de contenu ne couvre de toute façon ni les marges (`gutter`) ni le vide sous la dernière
/// ligne. Essayé deux fois, rejeté deux fois.
///
/// La bonne réponse est celle de la page d'une liste — un moniteur NSEvent + les cadres des lignes.
/// Elle arrivera avec la mesure des cadres sur les pages intelligentes, dont le glisser a de toute
/// façon besoin : ce n'est pas un contournement à inventer, c'est la même brique.
struct TaskPageBase: ViewModifier {
  @Binding var focus: TaskFocus
  /// Les pans que la page AFFICHE, dans l'ordre où elle les rend — pas un ordre de lignes recopié
  /// à la main (cf. `TaskPageBlock`, qui dit pourquoi la nuance a coûté cher). L'aplatissement est
  /// à nous : une page ne peut plus oublier de sauter une section repliée.
  let blocks: () -> [TaskPageBlock]
  let delete: (TaskItem) -> Void

  private var rows: [TaskItem] { blocks().displayedRows }

  func body(content: Content) -> some View {
    content
      .background(
        TaskKeyMonitor(
          isActive: { focus.editing == nil },
          onDelete: {
            guard let target = rows.first(where: { focus.isSelected($0) }) else { return false }
            delete(target)
            return true
          },
          onMove: { offset in
            // `TaskFocus` est une VALEUR `Equatable` : comparer l'avant et l'après dit si la touche
            // a servi, sans faire rendre un résultat aux méthodes mutantes (elles n'en rendent
            // aucun, à dessein — cf. son en-tête). Au bord de la liste, ↓ ne bouge pas, l'événement
            // repart donc intact et le ScrollView peut en faire son affaire.
            let before = focus
            withAnimation(taskSelectFade) { focus.moveSelection(by: offset, in: rows) }
            return focus != before
          }
        )
      )
  }
}

extension View {
  func taskPageBase(
    focus: Binding<TaskFocus>,
    blocks: @escaping () -> [TaskPageBlock],
    delete: @escaping (TaskItem) -> Void
  ) -> some View {
    modifier(TaskPageBase(focus: focus, blocks: blocks, delete: delete))
  }
}
