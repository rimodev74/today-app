import AppKit
import SwiftData
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
  /// Glissement en cours, quand la page en accepte un. Reçoit la translation depuis l'empoignade.
  var onDrag: ((CGSize) -> Void)?
  /// Relâchement après un glissement. N'est PAS appelé pour un simple clic.
  var onDrop: (() -> Void)?

  /// Le seuil qui sépare un clic d'un glissement. Il servait déjà à décider si le relâchement
  /// ouvre l'édition ; c'est le même, et c'est ce qui garantit qu'un geste ne peut pas être les
  /// deux à la fois.
  private static let threshold: CGFloat = 4

  /// Appui en cours (le premier `onChanged` est le mouseDown) et état de sélection d'AVANT cet
  /// appui : c'est lui qui décide si le relâchement ouvre l'édition (renommage façon Finder).
  @State private var pressing = false
  @State private var wasSelected = false

  private func moved(_ translation: CGSize) -> Bool {
    abs(translation.width) > Self.threshold || abs(translation.height) > Self.threshold
  }

  func body(content: Content) -> some View {
    content.gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          if !pressing {
            pressing = true
            wasSelected = isSelected
            // Empoigner sélectionne, comme sur une page de liste : on voit ce qu'on déplace.
            if !isEditing && !isSelected { onSelect() }
          }
          guard !isEditing, moved(value.translation) else { return }
          onDrag?(value.translation)
        }
        .onEnded { value in
          pressing = false
          guard !moved(value.translation) else {
            onDrop?()
            return
          }
          guard !isEditing, wasSelected else { return }
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
    onEdit: @escaping () -> Void,
    onDrag: ((CGSize) -> Void)? = nil,
    onDrop: (() -> Void)? = nil
  ) -> some View {
    modifier(
      RowPressGesture(
        isSelected: isSelected, isEditing: isEditing, onSelect: onSelect, onEdit: onEdit,
        onDrag: onDrag, onDrop: onDrop))
  }
}

extension View {
  /// Le rebond d'apparition d'une ligne de tâche : elle grandit depuis sa case à cocher, pas
  /// depuis son centre — d'où l'ancrage à gauche.
  ///
  /// Il n'existait que sur la page d'une liste ; « Aujourd'hui » et « Tâches » faisaient apparaître
  /// leurs lignes en fondu. Rien ne justifiait que la même tâche entre différemment selon l'onglet
  /// où on la regarde.
  func taskRowInsertion() -> some View {
    transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
  }
}

// MARK: - Où sont les lignes

/// Le repère dans lequel une page de tâches mesure ses lignes, et dans lequel elle convertit les
/// clics de la fenêtre pour les comparer à elles. Un seul nom : deux repères différents rendraient
/// la comparaison silencieusement fausse (des points justes, dans le mauvais système).
let taskPageSpace = "taskPage"

/// Les cadres des lignes, publiés par chacune en se rendant et reçus par la page.
///
/// Aucune valeur en mémoire ne peut y suppléer : savoir si un clic est tombé À CÔTÉ d'une tâche,
/// ou où ouvrir le trou d'insertion d'un glissement, ce sont des questions de position — donc de
/// mesure. C'est le pendant exact de `TaskPageBlock`, qui répond, lui, à « quelles lignes, dans
/// quel ordre ».
struct TaskRowFrameKey: PreferenceKey {
  static let defaultValue: [PersistentIdentifier: CGRect] = [:]
  static func reduce(
    value: inout [PersistentIdentifier: CGRect],
    nextValue: () -> [PersistentIdentifier: CGRect]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

extension View {
  /// À poser sur CHAQUE ligne d'une page qui utilise `taskPageBase`. Sans elle, la page garde son
  /// clavier mais reste aveugle : le clic dans le vide ne peut pas savoir qu'il est dans le vide.
  func measureTaskRow(_ task: TaskItem) -> some View {
    background {
      GeometryReader { proxy in
        Color.clear.preference(
          key: TaskRowFrameKey.self,
          value: [task.persistentModelID: proxy.frame(in: .named(taskPageSpace))])
      }
    }
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
/// ## Le clic dans le vide
///
/// Un fond transparent posé derrière la page NE MARCHE PAS, et c'est écrit noir sur blanc dans
/// l'en-tête de `LeftClickOutsideObserver` : le ScrollView capte les clics de toute sa surface, et
/// un fond de contenu ne couvre de toute façon ni les marges (`gutter`) ni le vide sous la dernière
/// ligne. Essayé deux fois, rejeté deux fois.
///
/// La réponse qui marche est celle de la page d'une liste : un moniteur qui voit TOUS les clics de
/// la fenêtre, et les cadres des lignes pour trancher. Ici les cadres arrivent d'eux-mêmes
/// (`TaskRowFrameKey`), et une page qui ne les publie pas garde simplement son clavier — le socle
/// reste inerte plutôt que de relâcher la sélection au moindre clic, faute de savoir où sont les
/// lignes.
struct TaskPageBase: ViewModifier {
  @Binding var focus: TaskFocus
  /// Les pans que la page AFFICHE, dans l'ordre où elle les rend — pas un ordre de lignes recopié
  /// à la main (cf. `TaskPageBlock`, qui dit pourquoi la nuance a coûté cher). L'aplatissement est
  /// à nous : une page ne peut plus oublier de sauter une section repliée.
  let blocks: () -> [TaskPageBlock]
  let delete: (TaskItem) -> Void

  /// Renseigné par les lignes qui appellent `measureTaskRow`, dans le repère `taskPageSpace`.
  @State private var rowFrames: [PersistentIdentifier: CGRect] = [:]

  private var rows: [TaskItem] { blocks().displayedRows }

  /// Un clic quelque part dans la fenêtre : hors de toute ligne, il relâche la sélection.
  ///
  /// La garde `isIdle` n'est pas une optimisation. Ce moniteur voit TOUS les `mouseDown` de la
  /// fenêtre — sidebar, barre du bas, bouton des réglages compris. Sans elle, chaque appui rejouait
  /// une transaction animée, donc une résignation de premier répondeur ENTRE le mouseDown et le
  /// mouseUp du contrôle visé : le contrôle perdait le suivi de son propre clic et il fallait
  /// cliquer deux fois (cf. la même garde dans `ListPageView.dismissSelectionIfOutside`).
  private func releaseSelectionIfOutside(_ point: CGPoint) {
    guard !focus.isIdle, !rowFrames.isEmpty else { return }
    guard !rowFrames.values.contains(where: { $0.contains(point) }) else { return }
    withAnimation(taskFlow) { focus.dismiss() }
  }

  func body(content: Content) -> some View {
    content
      // Le repère de `measureTaskRow` et celui du moniteur, posés au MÊME endroit : c'est la seule
      // façon que les points comparés soient dans le même monde. Ici le socle coiffe le ScrollView,
      // donc le repère est celui de la FENÊTRE de défilement — et c'est bien celui qu'il faut : la
      // vue AppKit du moniteur est un fond de ce même ScrollView, ses clics arrivent déjà là-dedans.
      //
      // ponytail: les cadres suivent donc le défilement et sont republiés en défilant. Coût réel
      // mesurable seulement si une page devient longue ; le jour où ça se sent, mesurer dans le
      // repère du CONTENU (invariant au défilement, cf. `ListPageView.dragSpace`) et convertir le
      // point du clic.
      .coordinateSpace(name: taskPageSpace)
      .onPreferenceChange(TaskRowFrameKey.self) { frames in rowFrames = frames }
      .background(LeftClickOutsideObserver(onClick: releaseSelectionIfOutside))
      // Une ligne qui apparaît ou disparaît SANS que ce soit nous qui l'ayons décidé. C'est le cas
      // de ⌘Z : l'annulation part du menu *Édition*, traverse la chaîne des répondeurs et arrive
      // dans SwiftData sans passer par une seule de nos méthodes — donc sans le `withAnimation`
      // que chacune d'elles ouvre. La tâche ressuscitée apparaissait d'un coup, sèche.
      //
      // Le nombre de lignes PORTÉES suffit à repérer ces cas : il ne bouge que si une tâche entre
      // ou sort. Pas le nombre de lignes affichées — celui-là tombe aussi quand on replie une
      // section, ce qui aurait mis un ressort sur chaque dépliant. Un glisser ou une frappe n'y
      // touchent pas ; et quand un geste à NOUS le fait bouger (créer, supprimer, cocher sur une
      // page qui masque les cochées), son propre `withAnimation` ouvre déjà la même courbe.
      .animation(taskInsert, value: blocks().carriedRowCount)
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
