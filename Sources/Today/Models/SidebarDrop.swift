import Foundation
import Observation
import SwiftData

/// Ranger une tâche en la lâchant sur une ligne de la barre latérale.
///
/// Deux morceaux, et la frontière entre eux est celle du reste du projet : la RÈGLE
/// (`SidebarFiling`, `TaskItem.move(to:)`) est une valeur sans état, donc vérifiable par des tests ;
/// l'ÉTAT du geste (`SidebarDrop`) est une classe observée, parce que les trois vues concernées —
/// la page qui tire, la sidebar qui accueille, la fenêtre qui dessine le calque — sont SŒURS.
///
/// C'est la seule entorse à « un état de geste est une valeur dans le `@State` de sa page »
/// (`TaskFocus`, `TaskPageReorder`), et elle se justifie par là : il n'existe aucune page où le
/// poser, et le faire descendre en `@Binding` traverserait `ContentView`, `TaskListView` et les cinq
/// pages pour un geste qui n'en concerne qu'une à la fois.

/// Une ligne d'accueil de la barre latérale : ce qu'on SURVOLE, et ce qu'un dépôt y RANGE.
///
/// Des identités et jamais les modèles eux-mêmes : cette valeur est comparée à chaque image de
/// glissement, et y mettre un `@Model` ferait relire ses propriétés à travers la machinerie
/// SwiftData à chaque comparaison — exactement le coût que `sortedByKey` documente.
struct SidebarDropRow: Hashable {
  /// La ligne elle-même. C'est elle qui s'allume au survol — sauf une ligne de PROJET, qui ne
  /// s'allume JAMAIS (cf. `list`) mais reste publiée : c'est ce qui la rend survolable.
  let row: PersistentIdentifier
  /// La liste où la tâche atterrit. `nil` pour une ligne de PROJET : une tâche appartient à une
  /// liste et jamais à un projet en direct (`TaskItem.project` se déduit de `list?.project`), donc
  /// lâcher sur un projet ne range RIEN — l'utilisateur doit viser une de ses listes. La ligne du
  /// projet reste malgré tout publiée : c'est ce qui la rend SURVOLABLE, pour la déplier
  /// (cf. `SidebarView`'s `.onChange(of: filing.hovered)`) et révéler ses listes, les seules vraies
  /// destinations.
  let list: PersistentIdentifier?
}

/// La règle du dépôt : ce qui peut accueillir, et où l'on vise.
enum SidebarFiling {
  /// Ce qu'une ligne de liste accueille : elle-même.
  static func dropRow(for list: TodoList) -> SidebarDropRow {
    SidebarDropRow(row: list.persistentModelID, list: list.persistentModelID)
  }

  /// Ce qu'une ligne de projet accueille : **rien**. Une tâche se range dans une LISTE, jamais dans
  /// un projet — même la première venue ne dit pas où l'utilisateur voulait vraiment la classer.
  /// Publiée quand même (même pour un projet sans liste) : c'est ce qui la rend survolable, et le
  /// survol la DÉPLIE pour révéler ses listes — la seule façon de viser un vrai dépôt.
  static func dropRow(for project: Project) -> SidebarDropRow {
    SidebarDropRow(row: project.persistentModelID, list: nil)
  }

  /// Le point d'accroche : le bord avant d'un cadre, à mi-hauteur — c'est là que le calque
  /// (`SidebarDropGhost`) est dessiné, donc ce qu'on voit est ce qui vise.
  ///
  /// L'appelant (`SidebarDrop.hovered`) lui passe un cadre déjà translaté du point d'empoignade
  /// (`grabOffsetX`), pas `draggedFrame` brut : posé tel quel, ce bord avant est celui de la
  /// RANGÉE, pas celui du curseur — juste tant qu'on empoigne près de son bord. Empoignée à son
  /// EXTRÉMITÉ opposée, l'écart devient la largeur de la ligne entière : le point visé sortait de
  /// l'écran, aucune ligne de la sidebar ne s'allumait et le calque n'apparaissait pas sous le
  /// curseur. Mesuré le 7 août 2026, en glissant délibérément par le bord droit d'une tâche.
  static func anchor(of frame: CGRect) -> CGPoint {
    CGPoint(x: frame.minX, y: frame.midY)
  }

  /// Les lignes de la barre latérale sont séparées de 6 pt d'air. Chacune en récupère la moitié de
  /// chaque côté, sans quoi le repère s'ÉTEINT entre deux lignes et un relâchement pile dans
  /// l'écart ne range rien — mesuré le 6 août 2026 : en descendant le long de la colonne, le survol
  /// clignotait `OUI`/`non` tous les 29 pt. Les zones de dépôt du Finder sont contiguës ; celles-ci
  /// le deviennent, exactement, sans jamais se chevaucher (`CGRect.contains` exclut son bord bas).
  ///
  /// Les grands vides, eux, restent des vides : entre la dernière liste d'un projet et le projet
  /// suivant il y a la rangée « + Nouvelle liste », qui n'est pas une destination.
  private static let rowGap: CGFloat = 6

  /// La ligne d'accueil sous ce point, s'il y en a une. `nil` À CÔTÉ d'une ligne : c'est ce qui fait
  /// qu'un dépôt raté ne range rien, au lieu de ranger n'importe où.
  ///
  /// ponytail: test sur le cadre, donc borné à gauche par le bord de la ligne (10 pt pour un
  /// projet, 28 pour une liste indentée). Tirer à plus de 340 pt du bord de la page fait ressortir
  /// le point d'accroche par la gauche et éteint le repère. Plafond assumé : la colonne fait
  /// 262 pt de large, il faut vraiment le vouloir. Le jour où ça gêne, la zone doit couvrir la
  /// COLONNE entière — ce qui demande d'en connaître la largeur ici, donc de la faire descendre.
  static func target(at point: CGPoint, in rows: [SidebarDropRow: CGRect]) -> SidebarDropRow? {
    rows.first { $0.value.insetBy(dx: 0, dy: -rowGap / 2).contains(point) }?.key
  }
}

extension TaskItem {
  /// Rattacher une tâche à une autre liste, et l'y poser EN TÊTE.
  ///
  /// Ce rattachement était écrit trois fois à l'identique — `ListPageView`, `TodayPageView`,
  /// `AllTasksPageView` — pour le seul menu *Déplacer vers…*. Le rang est la moitié qu'on oublie :
  /// `sortIndex` est attribué PAR LISTE (cf. `TaskItem.smartOrder`), une tâche qui change de liste
  /// en gardant le sien se retrouve donc classée par un rang qui parle d'une autre liste.
  ///
  /// **En tête et pas en fin.** Une tâche posée en fin atterrit hors de l'écran dès que la liste
  /// dépasse une hauteur de fenêtre : le geste n'a alors aucun accusé de réception, et le seul
  /// moyen de vérifier qu'il a marché est de faire défiler. En tête, elle est là où on regarde.
  ///
  /// Et au-dessus de TOUS les en-têtes de section, pas dans l'un d'eux. Un en-tête est une tâche
  /// comme une autre dans cette liste (`TaskItem.isHeader`), donc « au-dessus du premier » suffit à
  /// n'être dans aucune section : la tâche arrive dans le pan libre qui ouvre la liste, et c'est à
  /// l'utilisateur de la ranger — pas à un défaut de la classer à sa place.
  ///
  /// N'enregistre PAS : l'appelant sait s'il écrit une chose ou plusieurs, et c'est à lui que la
  /// transaction appartient.
  ///
  /// Le premier rang se lit AVANT le rattachement, et c'est ce que les trois copies faisaient à
  /// l'envers : `list = target` remplit la relation inverse tout de suite, donc `target.tasks`
  /// contiendrait DÉJÀ la tâche qu'on déplace, avec le rang qu'elle avait dans son ancienne liste —
  /// et c'est à ce rang-là, venu d'ailleurs, qu'on se comparerait pour trouver la place.
  func move(to target: TodoList) {
    // Les rangs négatifs ne gênent personne : l'ordre est un tri, pas une position dans un tableau
    // (`TodoList.orderedTasks`), et la première renumérotation venue — un glissement,
    // `moveToEndOfSection` — les remet à plat.
    let first = target.tasks.map(\.sortIndex).min() ?? 1
    list = target
    sortIndex = first - 1
  }
}

/// L'état du geste, partagé par la page, la sidebar et la fenêtre (cf. l'en-tête de ce fichier).
@MainActor @Observable
final class SidebarDrop {
  /// Cadres des lignes d'accueil, dans le repère global. Publiés par la sidebar.
  private(set) var rows: [SidebarDropRow: CGRect] = [:]

  /// Le cadre de la ligne EN VOL, dans le repère global, ou `nil` hors geste.
  ///
  /// Un cadre et rien d'autre. Il a porté l'identité et le titre de la tâche, le temps que le
  /// calque affiche son nom — depuis qu'il ne l'affiche plus (cf. `SidebarDropGhost`, et pourquoi),
  /// les deux ne servaient plus à personne. Ce qu'on RANGE au relâchement ne vient pas d'ici : la
  /// page tient déjà sa tâche, c'est elle qui la tire.
  ///
  /// Publié par la rangée qui se déplace : elle est la seule à connaître son cadre APRÈS décalage,
  /// et elle le sait sans que personne n'ait à convertir de repère.
  private(set) var draggedFrame: CGRect?

  /// Le bord droit de la barre latérale, dans le repère global — c'est-à-dire le bord GAUCHE de la
  /// page, celui où le `ScrollView` rogne ce qui dépasse. Posé par la fenêtre, qui est la seule à
  /// connaître la largeur courante (elle se replie, elle se tire).
  var sidebarEdge: CGFloat = 0

  /// Distance entre le bord avant de la ligne et le point où on l'a empoignée, constante sur tout
  /// le geste. Sans elle, `isAirborne` comparait le bord de la rangée au bord de la sidebar — juste
  /// tant qu'on empoigne une ligne PAR son bord, faux dès qu'on la prend ailleurs (son extrémité
  /// opposée, son centre) : le bord AVANT franchit alors la sidebar bien avant que le curseur ne
  /// l'atteigne, et le calque bascule trop tôt. Posée par `arm`, aux deux moteurs de glissement de
  /// l'app (page intelligente comme page d'une liste).
  private(set) var grabOffsetX: CGFloat = 0

  /// La ligne a franchi le bord de la page : c'est le CALQUE qui la représente désormais.
  ///
  /// Un seul état pour les deux moitiés du geste, et c'est tout l'intérêt : la fenêtre l'utilise
  /// pour montrer la pilule, la page pour effacer sa rangée. Le même booléen, donc jamais l'une
  /// sans l'autre — deux conditions écrites séparément auraient fini par diverger d'une image, et
  /// on aurait vu soit les deux, soit aucune.
  ///
  /// SwiftUI ne sait pas ré-héberger une vue ailleurs dans l'arbre le temps d'un geste : une
  /// rangée qui doit s'afficher par-dessus la sidebar est forcément une SECONDE vue. La question
  /// n'est donc pas de « détacher » la ligne, elle est de savoir laquelle des deux on montre — et
  /// ce booléen est la réponse.
  ///
  /// Comparé au CURSEUR (`draggedFrame.minX + grabOffsetX`), pas au seul bord de la rangée : voir
  /// `grabOffsetX`. Même correction que `hovered`, pour la même raison.
  var isAirborne: Bool {
    guard let draggedFrame else { return false }
    return draggedFrame.minX + grabOffsetX < sidebarEdge
  }

  /// La ligne survolée. Calculée à la lecture — un troisième état à tenir synchronisé avec les deux
  /// autres est exactement la façon dont deux vues se mettent à diverger sans qu'on le voie.
  ///
  /// Vise le cadre TRANSLATÉ de `grabOffsetX`, pas `draggedFrame` brut : cf. `SidebarFiling.anchor`.
  var hovered: SidebarDropRow? {
    guard let draggedFrame else { return nil }
    let cursorFrame = draggedFrame.offsetBy(dx: grabOffsetX, dy: 0)
    return SidebarFiling.target(at: SidebarFiling.anchor(of: cursorFrame), in: rows)
  }

  /// Nouvelle mesure de la sidebar — publiée même PENDANT un geste, depuis que survoler un projet
  /// le déplie (cf. `SidebarView`) : les listes qu'il révèle n'existaient pas à l'empoignade, donc
  /// `rows` doit pouvoir les accueillir en cours de route, sans quoi elles ne s'allumeraient jamais
  /// tant que la tâche reste en vol. Rien à voir avec le gel de `TaskPageReorder.measured` : LÀ, ce
  /// sont les cadres du glissement lui-même qui se décalent (l'offset des lignes tirées), et les
  /// réinjecter boucle. ICI, aucune ligne de la sidebar ne porte d'offset tant qu'on y lâche une
  /// tâche (seul `dragID` — le réordonnancement de la sidebar elle-même, exclusif d'un dépôt — en
  /// pose un, et il reste `nil` tout du long). Le test d'égalité suffit donc à éviter le travail
  /// inutile.
  func measured(_ new: [SidebarDropRow: CGRect]) {
    guard rows != new else { return }
    rows = new
  }

  func track(_ frame: CGRect?) {
    guard draggedFrame != frame else { return }
    draggedFrame = frame
  }

  /// Pose `grabOffsetX` pour le geste en cours. Appelable à chaque image du drag (le résultat est
  /// le même tout du long) : le garde d'égalité évite d'invalider les deux colonnes pour une valeur
  /// inchangée, même motif que `track` et `measured`.
  func arm(grabOffsetX: CGFloat) {
    guard self.grabOffsetX != grabOffsetX else { return }
    self.grabOffsetX = grabOffsetX
  }

  /// La même chose depuis ce que les pages ont sous la main : le point d'empoignade et le cadre de
  /// REPOS de la ligne tirée (gelé dès l'empoignade par les deux moteurs, donc constant sur tout le
  /// geste). Les trois pages soustrayaient ces deux valeurs elles-mêmes ; sans cadre, il n'y a rien
  /// à armer et l'ancien décalage reste — appelé à chaque image, il sera posé à la suivante.
  func arm(grabbedAt start: CGPoint, restingFrame: CGRect?) {
    guard let restingFrame else { return }
    arm(grabOffsetX: start.x - restingFrame.minX)
  }

  /// **Le relâchement du geste** : la liste où ranger, s'il y en a une, et fin du vol.
  ///
  /// Rend la LISTE et pas la ligne visée, parce que c'est la seule chose qu'un appelant en fasse —
  /// les deux moteurs de glissement de l'app résolvaient sinon le même identifiant chacun de son
  /// côté. Et elle désarme au passage : la cible se déduit d'un geste qui n'existe plus après, il
  /// n'y a donc pas d'ordre correct autre que celui-là.
  func drop(in lists: [TodoList]) -> TodoList? {
    defer {
      draggedFrame = nil
      grabOffsetX = 0
    }
    // `list` vaut `nil` pour une ligne de PROJET : la survoler la déplie, elle ne range rien.
    guard let hovered, let listID = hovered.list else { return nil }
    return lists.first { $0.persistentModelID == listID }
  }
}
