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

/// Marge latérale des FONDS du panneau de détail — pilule de sélection, bandeau d'en-tête, cadre
/// de notes. Le CONTENU, lui, tombe `rowInset` plus loin (soit 75 pt du bord), et c'est cette
/// colonne-là qui se voit : case à cocher, ＋ de création, texte « Notes », anneau de progression
/// d'une liste. Séparer les deux est ce qui met l'anneau d'en-tête sur la même verticale que les
/// cases — il était seul posé au bord des fonds, 10 pt à gauche de tout le reste.
/// Interne (pas `private`) : `ArchivePageView` vit dans son propre fichier et doit se caler sur la
/// même marge que les pages de liste.
let gutter: CGFloat = 65

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
/// Apparition (création) ET disparition (suppression) d'une ligne, dans les deux sens. Le
/// réordonnancement, lui, passe par des offsets et pas des insertions/suppressions — la
/// transition des rangées n'y répond donc jamais.
/// Interne pour la même raison que `gutter` : `ArchivePageView` anime ses sorties de ligne avec.
let taskInsert = Animation.spring(response: 0.32, dampingFraction: 1)
/// Même ressort, CRITIQUEMENT amorti : le tableau de cartes d'un projet (`ProjectPageView`).
///
/// Le rebond de `taskInsert` est juste sur une RANGÉE — un objet fin, qui parcourt quelques points
/// et dont le dépassement se lit comme de l'élan. Sur une carte de 250 pt qui traverse une grille,
/// le même dépassement devient un ballottement : la carte arrive, repart, revient. La distance
/// parcourue change ce qu'on lit du même ressort, d'où deux amortissements et pas deux courbes
/// inventées séparément. Même raisonnement que `ProgressRing.ringFlow`.
let boardFlow = Animation.spring(response: 0.32, dampingFraction: 1)
/// TOUT dépliant de l'app : chevron qui tourne et contenu qui apparaît/disparaît — repli d'un
/// projet dans la sidebar, section d'« Aujourd'hui » ou de « Tâches », archives d'une liste,
/// sous-tâches d'une ligne. Quatre valeurs coexistaient (`.snappy(0.2)`, `.snappy(0.22)`,
/// `.easeInOut(0.2)`, et le défaut de `DisclosureGroup`) : le même geste ne se sentait pas pareil
/// d'un endroit à l'autre. Toujours en `withAnimation(disclosureFlow) { … }` autour de l'écriture
/// de l'état — jamais un `.animation(value:)` posé sur la vue : un `DisclosureGroup` change son
/// binding depuis son propre bouton AppKit, hors de notre code, et `.animation(value:)` n'attrape
/// pas cette transaction-là (testé : résultat instantané et saccadé). Pour un `DisclosureGroup`,
/// passer un `Binding` maison dont le `set` fait le `withAnimation` (cf.
/// `AllTasksPageView.expansion(of:)`).
let disclosureFlow = Animation.snappy(duration: 0.2)

/// Le repos d'un réordonnancement : écartement des voisines pendant le geste, et retour des
/// décalages à zéro au relâchement. Une seule valeur pour les deux, et pour toutes les pages —
/// deux courbes différentes se verraient au passage d'un onglet à l'autre.
let taskDrop = Animation.snappy(duration: 0.22)

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
      // Repère `taskPageSpace` et NON le repère local, qui est celui de la rangée — c'est-à-dire
      // celui que le glissement est en train de déplacer. Mesurer un déplacement dans un repère que
      // ce même déplacement bouge, c'est se mordre la queue : la rangée bouge, donc son repère
      // bouge, donc la translation lue change, donc la rangée rebouge. À l'écran, ça tremble et on
      // n'arrive plus à poser la ligne où on veut.
      //
      // `ListPageView` mesure depuis toujours dans son propre repère fixe (`dragSpace`), et c'est
      // exactement pour ça que son glisser est net.
      DragGesture(minimumDistance: 0, coordinateSpace: .named(taskPageSpace))
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
  /// Apparition d'une ligne de tâche : fondu seul, sans scale.
  func taskRowInsertion() -> some View {
    transition(.opacity)
  }

  /// La pilule lavande d'une ligne sélectionnée, pour les rangées qui ne sont pas des `TaskRow`
  /// (« À venir », « Archives », qui ont leur propre rendu).
  ///
  /// Le double retrait est volontaire : la pilule déborde de `rowInset` de chaque côté, comme dans
  /// une page de liste, mais la géométrie EXTÉRIEURE de la rangée ne bouge pas d'un point — sans
  /// quoi ajouter la sélection décalerait toute la page de 10 pt vers la droite.
  func taskRowSelection(_ isSelected: Bool) -> some View {
    padding(.horizontal, rowInset)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(thingsSelectionFill)
          .opacity(isSelected ? 1 : 0)
      )
      .padding(.horizontal, -rowInset)
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

/// Le cadre de la ligne EN VOL, remonté jusqu'à la fenêtre (cf. `View.publishTaskDrag`). Une seule
/// à la fois : un glissement empoigne une rangée, jamais deux — d'où « la première l'emporte »
/// plutôt qu'une fusion.
struct DraggedRowFrameKey: PreferenceKey {
  static let defaultValue: CGRect? = nil
  static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
    value = value ?? nextValue()
  }
}

/// La bande verticale d'une SECTION, publiée par celle-ci et reçue par la page.
///
/// Séparée des cadres de lignes, et ce n'est pas un second stockage de ceux-ci (cf. le piège
/// documenté) : elle ne nourrit AUCUN calcul de décalage, elle ne sert qu'au relâchement, pour
/// répondre à la seule question que les lignes ne peuvent pas trancher — « sur quelle section VIDE
/// vient-on de lâcher ? ». Elle est aussi stable pendant un geste : les décalages sont appliqués
/// aux rangées, à l'intérieur, et un `.offset` d'enfant ne déplace pas le cadre de son parent.

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

// MARK: - Le glissement, vu de la page

extension View {
  /// Ce qu'une rangée porte pendant un glissement : elle suit le curseur si c'est elle qu'on tire,
  /// elle s'écarte sinon.
  ///
  /// Écrit ici et pas dans chaque page. Les quatre modificateurs vont ensemble et leur ORDRE
  /// compte : le plan et l'ombre isolent la ligne tirée du reste, et l'animation ne doit surtout
  /// pas s'appliquer à elle — une ligne qui « rattrape » le curseur avec 0,22 s de retard donne
  /// l'impression que le geste patine.
  ///
  /// `airborne` : la ligne a franchi le bord de la page, c'est le calque qui la représente
  /// (`SidebarDrop.isAirborne`) et la rangée s'efface — sans quitter ni le layout ni le calcul, elle
  /// publie toujours son cadre et le trou reste à sa place. **Sans valeur par défaut**, comme
  /// `reorder` et `newTask` du socle : l'oublier montrerait la rangée ET la pilule, sans un mot.
  func taskRowDragLayer(
    _ reorder: TaskPageReorder, task: TaskItem, offset: CGSize, airborne: Bool
  ) -> some View {
    let lifted = reorder.isDragging(task)
    return
      self
      // AVANT le décalage, et c'est tout le sujet : voir `publishTaskDrag`.
      .publishTaskDrag(lifted: lifted)
      // `opacity` et pas un retrait de l'arbre : une rangée démontée ne publierait plus son cadre,
      // donc le calque perdrait sa position à l'instant même où il en prend la relève.
      .opacity(lifted && airborne ? 0 : 1)
      .offset(offset)
      .zIndex(lifted ? 1 : 0)
      .shadow(color: .black.opacity(lifted ? 0.22 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
      .animation(lifted ? nil : taskDrop, value: offset)
  }

  /// Dire à la FENÊTRE où en est la ligne qu'on tire : c'est ce qui permet de la ranger dans la
  /// barre latérale, et de l'y voir pendant qu'on l'y emmène.
  ///
  /// **À poser AVANT le `.offset`, jamais après**, et l'inverse ne se voit pas à la compilation.
  /// Posée après, la mesure devient le FRÈRE de la ligne décalée au lieu d'en être un descendant ;
  /// or `.offset` est un effet de RENDU, qui ne déplace pas la position de layout — le frère reste
  /// donc calé sur la place de repos et publie un cadre parfaitement immobile. Essayé : le calque
  /// n'apparaissait jamais et aucune ligne ne s'allumait, sans un mot nulle part. Sous l'offset,
  /// `frame(in:)` inclut le décalage : c'est le gel des cadres de `TaskPageReorder` vu de l'autre
  /// côté — là c'est le piège, ici c'est le mécanisme.
  ///
  /// En `.global` : c'est le seul repère qu'une page et la sidebar partagent, chacune mesurant dans
  /// le sien. Et par une préférence plutôt qu'une écriture directe, parce que la valeur doit
  /// remonter jusqu'à `ContentView`, seul ancêtre commun des deux colonnes.
  ///
  /// Interne, pas privée : `ListPageView` a son propre moteur de glissement mais range dans la
  /// sidebar comme les autres — c'est le MÊME calque, pas un second.
  func publishTaskDrag(lifted: Bool) -> some View {
    background {
      if lifted {
        GeometryReader { proxy in
          Color.clear.preference(key: DraggedRowFrameKey.self, value: proxy.frame(in: .global))
        }
      }
    }
  }

  /// Le trou d'insertion, DERRIÈRE la page : il n'est donc visible que dans le vide ouvert par
  /// l'écartement des voisines. Sans lui, aucun repère de dépôt — et l'écartement silencieux se
  /// lit comme une saccade.
  func taskReorderPlaceholder(_ reorder: TaskPageReorder) -> some View {
    background(alignment: .topLeading) {
      if let hole = reorder.placeholder() {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary.opacity(0.06))
          .frame(width: hole.width, height: hole.height)
          .offset(x: hole.minX, y: hole.minY)
          .allowsHitTesting(false)
      }
    }
  }
}

/// Le relâchement, écrit une fois pour toutes les pages. Deux règles y sont enfermées, et chacune
/// s'est déjà payée à l'écran :
///
/// - **lire le plan AVANT de désarmer** — il se déduit de l'état du geste, qui n'existe plus après ;
/// - **une SEULE transaction** pour l'ordre écrit et les décalages remis à zéro. Séparés, ils se
///   contredisent : la rangée saute à sa nouvelle place instantanément pendant que son décalage
///   revient à zéro en s'animant depuis l'ancienne, donc elle s'élance à l'opposé avant de revenir.
///
/// `write` reçoit l'ordre obtenu ; ce qu'on en persiste appartient à la page (renuméroter un rang,
/// et sur « Tâches » rattacher la tâche à la liste où elle a atterri).
///
/// **Un dépôt sur la barre latérale l'emporte sur le réordonnancement**, et les deux s'excluent :
/// une tâche lâchée sur une liste part dans cette liste, point — écrire aussi son rang dans la page
/// qu'elle quitte ne veut rien dire. Le geste est le même des deux côtés (cf. `SidebarDrop`), c'est
/// donc ici, à l'endroit unique où il se termine, que la question se tranche — et pas dans chacune
/// des trois pages qui glissent.
@MainActor
func dropTaskDrag(
  _ reorder: inout TaskPageReorder, onto filing: SidebarDrop, lists: [TodoList],
  in context: ModelContext, write: ([TaskItem]) -> Void
) {
  let ordered = reorder.dropped()
  let dragged = reorder.draggedTask
  // Lue AVANT de désarmer, comme l'ordre, et pour la même raison.
  let filed = filing.drop(in: lists)
  withAnimation(taskDrop) {
    if let filed, let dragged {
      dragged.move(to: filed)
      try? context.save()
    } else if let ordered {
      write(ordered)
    }
    reorder.end()
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

  /// Le glissement de la page, quand elle en accepte un. Il porte AUSSI les cadres des lignes :
  /// une seule mesure pour les deux usages (savoir si un clic est tombé à côté, savoir où une ligne
  /// tirée peut se poser).
  ///
  /// Deux stockages séparés ont coûté cher : celui-ci gèle ses cadres pendant un geste, l'autre non.
  /// Or `frame(in:)` inclut le `.offset` des lignes tirées — le second se réécrivait donc à chaque
  /// image, ce qui relançait un rendu, qui redéplaçait les lignes, qui réécrivait les cadres. La
  /// boucle exacte que `ListPageView` documente depuis toujours, et le glisser saccadé qu'on a mis
  /// deux fois sur le dos du reste.
  /// `nil` = cette page ne se réordonne pas. **Sans valeur par défaut, et c'est délibéré** :
  /// l'oubli de ce branchement compilait sans un mot et le glissement ne recevait aucun cadre. Une
  /// page doit se prononcer — c'est la même règle que la closure `rows` d'avant, dont l'oubli
  /// silencieux est à l'origine de tout ce chantier.
  var reorder: Binding<TaskPageReorder>?

  /// ⌘N sur cette page, ou `nil` si elle ne sait pas créer de tâche (« À venir », « Archives »).
  ///
  /// **Sans valeur par défaut, pour la même raison que `reorder`** : l'omission compilerait sans un
  /// mot et rendrait la touche muette sur une page qui, elle, sait créer. Les pages se prononcent.
  ///
  /// `nil` ne veut pas dire « laisse passer la touche » : ⌘N ne doit RIEN faire là où il n'y a rien
  /// à créer. Ce qu'il faisait avant — ouvrir un onglet — venait du *Nouvelle fenêtre* d'office de
  /// `WindowGroup`, retiré dans `TodayApp.commands`. Une page sans création n'a donc rien à porter.
  let newTask: (() -> Void)?

  /// Le repli de secours pour une page SANS glissement (« À venir », « Archives », une liste) : elle
  /// n'a pas de `TaskPageReorder` à elle, mais elle a droit au clic dans le vide.
  @State private var ownFrames: [PersistentIdentifier: CGRect] = [:]

  private var rowFrames: [PersistentIdentifier: CGRect] {
    reorder?.wrappedValue.frames ?? ownFrames
  }

  private var rows: [TaskItem] { blocks().displayedRows }

  /// Clic droit sur une tâche → la sélectionne.
  private func selectAtRightClick(_ point: CGPoint) {
    guard
      let task = rows.first(where: {
        rowFrames[$0.persistentModelID]?.contains(point) == true
      })
    else { return }
    withAnimation(taskSelectFade) { focus.select(task) }
  }

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
      .onPreferenceChange(TaskRowFrameKey.self) { frames in
        guard let reorder else {
          // Test d'égalité, pour la raison que la ligne du dessous énonce déjà : réécrire une
          // valeur identique invalide la vue quand même. Le repli sans glissement n'avait pas ce
          // garde-fou — donc les pages qui l'utilisent (une liste, « À venir », « Archives ») se
          // réinvalidaient à chaque mise en page, en continu, sans que rien ne bouge à l'écran.
          guard ownFrames != frames else { return }
          ownFrames = frames
          return
        }
        // GEL. Pas seulement « on ignore la valeur » : on n'ÉCRIT pas. Écrire une valeur identique
        // dans un `@State` invalide quand même la vue, et c'est l'invalidation qui boucle.
        guard !reorder.wrappedValue.isDragging else { return }
        reorder.wrappedValue.measured(frames)
      }
      .background(LeftClickOutsideObserver(onClick: releaseSelectionIfOutside))
      .background(RightClickObserver(onRightClick: selectAtRightClick))
      // Une tâche restée VIDE quand son édition se referme s'en va (cf. `TaskItem.isBlank`).
      //
      // Posé sur la SORTIE d'édition, et pas dans les `endEditing` des pages : elles ne sont qu'un
      // des chemins. Échap et le clic dans le vide appellent `focus.dismiss()` directement, et
      // cliquer une autre ligne bascule l'édition sans passer par elles non plus. Trois façons de
      // laisser un déchet, dont deux qu'un correctif posé sur `endEditing` aurait manquées.
      //
      // On regarde ce qui n'est PLUS édité (`previous`) : la tâche existe encore à cet instant,
      // c'est justement ce qui permet de la lire avant de trancher.
      .onChange(of: focus.editing) { previous, _ in
        guard let previous,
          let abandoned = rows.first(where: { $0.persistentModelID == previous }),
          abandoned.isBlank
        else { return }
        delete(abandoned)
      }
      // ⌘N. Moniteur NSEvent et pas un bouton caché + `.keyboardShortcut` : c'est le mécanisme que
      // `ListPageView` utilisait déjà, précisément parce que deux raccourcis sur la même lettre
      // (⌘N et ⌘⇧N) se marchent dessus sous SwiftUI — ce moniteur compare les modificateurs à
      // l'égalité. Il vit ici pour que les cinq pages en héritent, au lieu d'une seule.
      .background {
        if let newTask {
          KeyCommandMonitor(keyCode: 45, modifiers: [.command], action: newTask)
        }
      }
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
            // Le déplacement se calcule sur une COPIE, et on n'écrit que si elle a bougé. Écrire
            // puis relire le `@Binding` pour savoir si ça a marché — ce que faisait la version
            // précédente — dépendait du moment où SwiftUI applique l'écriture ; depuis un moniteur
            // NSEvent, elle n'est pas forcément visible à la relecture qui suit. Résultat : la
            // touche était rendue à la fenêtre au lieu d'agir, et il fallait insister.
            var moved = focus
            moved.moveSelection(by: offset, in: rows)
            if moved != focus { withAnimation(taskSelectFade) { focus = moved } }

            // Consommée dès qu'il y a des lignes à parcourir, MÊME si la sélection n'a pas bougé :
            // au bord de la liste, ↑/↓ ne font rien et ne doivent rien faire d'autre — ni défiler,
            // ni déplacer le focus AppKit. C'est le comportement du Finder et de Mail. Sans lignes,
            // la touche repart intacte : la page n'a rien à en faire.
            return !rows.isEmpty
          }
        )
      )
  }
}

extension View {
  func taskPageBase(
    focus: Binding<TaskFocus>,
    blocks: @escaping () -> [TaskPageBlock],
    delete: @escaping (TaskItem) -> Void,
    reorder: Binding<TaskPageReorder>?,
    newTask: (() -> Void)?
  ) -> some View {
    modifier(
      TaskPageBase(
        focus: focus, blocks: blocks, delete: delete, reorder: reorder, newTask: newTask))
  }
}
