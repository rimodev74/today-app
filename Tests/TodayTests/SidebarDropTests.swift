import SwiftData
import XCTest

@testable import Today

/// Ranger une tâche en la lâchant sur la barre latérale.
///
/// Ce qui est vérifié ici, c'est la RÈGLE — ce qu'une ligne accueille, où l'on vise, et ce qu'un
/// dépôt écrit. Le geste lui-même (le calque qui sort de la page, le repère de survol) ne se voit
/// qu'à l'écran, et se contrôle en lançant l'app.
final class SidebarDropTests: XCTestCase {
  /// Conteneur en mémoire : `Project.orderedLists` lit une VRAIE relation, qu'un objet détaché ne
  /// remplirait pas.
  private func makeContext() throws -> ModelContext {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: config))
  }

  // MARK: Ce qu'une ligne accueille

  func testAListRowTakesTheTaskItself() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "Courses")
    ctx.insert(list)

    let row = SidebarFiling.dropRow(for: list)

    XCTAssertEqual(row.row, list.persistentModelID)
    XCTAssertEqual(row.list, list.persistentModelID)
  }

  /// Une tâche appartient à une LISTE, jamais à un projet en direct : lâcher sur un projet ne range
  /// donc RIEN, même s'il a des listes — l'utilisateur doit viser l'une d'elles.
  func testAProjectRowNeverAcceptsADrop() throws {
    let ctx = try makeContext()
    let project = Project(title: "Maison")
    ctx.insert(project)
    let list = TodoList(title: "une liste")
    list.project = project
    ctx.insert(list)

    let row = SidebarFiling.dropRow(for: project)

    XCTAssertEqual(row.row, project.persistentModelID, "c'est la ligne du PROJET qui est publiée")
    XCTAssertNil(row.list, "aucun dépôt ne doit résoudre vers ce projet")
  }

  /// Un projet vide reste survolable — c'est ce qui permet de le déplier au survol — mais il n'y a
  /// toujours rien à y ranger : même traitement que pourvu de listes, seules SES listes rangent.
  func testAnEmptyProjectRowIsStillHoverableButNeverATarget() throws {
    let ctx = try makeContext()
    let project = Project(title: "Vide")
    ctx.insert(project)

    let row = SidebarFiling.dropRow(for: project)

    XCTAssertEqual(row.row, project.persistentModelID)
    XCTAssertNil(row.list)
  }

  // MARK: Où l'on vise

  /// Le bord AVANT à mi-hauteur, et pas le centre : c'est exactement là que la pastille de
  /// transport est dessinée, donc ce qu'on voit est ce qui touche.
  func testTheAnchorIsTheLeadingEdgeAtMidHeight() {
    let anchor = SidebarFiling.anchor(of: CGRect(x: 100, y: 40, width: 300, height: 30))

    XCTAssertEqual(anchor, CGPoint(x: 100, y: 55))
  }

  func testTheTargetIsTheRowUnderTheAnchor() throws {
    let ctx = try makeContext()
    let haut = TodoList(title: "haut")
    let bas = TodoList(title: "bas")
    ctx.insert(haut)
    ctx.insert(bas)
    let rows: [SidebarDropRow: CGRect] = [
      SidebarFiling.dropRow(for: haut): CGRect(x: 10, y: 0, width: 200, height: 30),
      SidebarFiling.dropRow(for: bas): CGRect(x: 10, y: 30, width: 200, height: 30),
    ]

    XCTAssertEqual(
      SidebarFiling.target(at: CGPoint(x: 50, y: 45), in: rows),
      SidebarFiling.dropRow(for: bas))
  }

  /// L'air entre deux lignes appartient à l'une des deux, jamais à personne : sans ça le repère
  /// s'éteint tous les 29 pt en descendant la colonne, et un relâchement pile dans l'écart ne range
  /// rien. Les deux zones restent disjointes — un point ne peut pas viser deux lignes.
  func testTheGapBetweenTwoRowsBelongsToOneOfThem() throws {
    let ctx = try makeContext()
    let haut = TodoList(title: "haut")
    let bas = TodoList(title: "bas")
    ctx.insert(haut)
    ctx.insert(bas)
    // Les mesures réelles de la sidebar : 29 pt de haut, 6 pt d'air entre les deux.
    let rows: [SidebarDropRow: CGRect] = [
      SidebarFiling.dropRow(for: haut): CGRect(x: 28, y: 406, width: 244, height: 29),
      SidebarFiling.dropRow(for: bas): CGRect(x: 28, y: 441, width: 244, height: 29),
    ]

    for y in 435...440 {
      XCTAssertNotNil(
        SidebarFiling.target(at: CGPoint(x: 100, y: CGFloat(y)), in: rows),
        "l'air à y=\(y) doit revenir à une ligne")
    }
    XCTAssertEqual(
      SidebarFiling.target(at: CGPoint(x: 100, y: 437), in: rows),
      SidebarFiling.dropRow(for: haut), "la moitié haute de l'air revient à la ligne du dessus")
    XCTAssertEqual(
      SidebarFiling.target(at: CGPoint(x: 100, y: 439), in: rows),
      SidebarFiling.dropRow(for: bas), "la moitié basse à celle du dessous")
  }

  /// Lâcher À CÔTÉ ne range rien — et surtout ne range pas au hasard.
  func testDroppingBesideAnyRowHitsNothing() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "seule")
    ctx.insert(list)
    let rows = [SidebarFiling.dropRow(for: list): CGRect(x: 10, y: 0, width: 200, height: 30)]

    XCTAssertNil(SidebarFiling.target(at: CGPoint(x: 50, y: 400), in: rows))
    XCTAssertNil(SidebarFiling.target(at: CGPoint(x: 500, y: 15), in: rows))
  }

  // MARK: Ce qu'un dépôt écrit

  /// Le rattachement ET le rang. Le rang est la moitié qu'on oublie : `sortIndex` est attribué PAR
  /// LISTE, une tâche qui garde le sien en changeant de liste se classe donc par un rang qui parle
  /// d'ailleurs — ici, elle se retrouverait DERRIÈRE les deux tâches déjà en place.
  func testFilingAttachesTheTaskAndPutsItFirst() throws {
    let ctx = try makeContext()
    let source = TodoList(title: "source")
    let target = TodoList(title: "cible")
    ctx.insert(source)
    ctx.insert(target)
    for (index, title) in ["a", "b"].enumerated() {
      let task = TaskItem(title: title, list: target)
      task.sortIndex = index
      ctx.insert(task)
    }
    let moved = TaskItem(title: "déménage", list: source)
    moved.sortIndex = 7
    ctx.insert(moved)

    moved.move(to: target)

    XCTAssertEqual(moved.list?.persistentModelID, target.persistentModelID)
    XCTAssertEqual(target.orderedTasks.map(\.title), ["déménage", "a", "b"])
  }

  /// Une liste vide accueille au rang 0, pas au rang gardé de l'ancienne.
  func testFilingIntoAnEmptyListStartsAtZero() throws {
    let ctx = try makeContext()
    let source = TodoList(title: "source")
    let target = TodoList(title: "vide")
    ctx.insert(source)
    ctx.insert(target)
    let moved = TaskItem(title: "déménage", list: source)
    moved.sortIndex = 4
    ctx.insert(moved)

    moved.move(to: target)

    XCTAssertEqual(moved.sortIndex, 0)
  }

  /// Au-dessus de TOUS les en-têtes, jamais dans le premier. Un en-tête est une tâche de la liste
  /// comme une autre : atterrir juste après lui, c'est se faire classer dans sa section sans
  /// l'avoir demandé, et c'est le choix qui revient à l'utilisateur.
  func testFilingLandsAboveEverySectionHeader() throws {
    let ctx = try makeContext()
    let source = TodoList(title: "source")
    let target = TodoList(title: "cible")
    ctx.insert(source)
    ctx.insert(target)
    for (index, title) in ["Matin", "a", "Soir", "b"].enumerated() {
      let task = TaskItem(title: title, list: target)
      task.isHeader = title == "Matin" || title == "Soir"
      task.sortIndex = index
      ctx.insert(task)
    }
    let moved = TaskItem(title: "déménage", list: source)
    ctx.insert(moved)

    moved.move(to: target)

    XCTAssertEqual(target.orderedTasks.map(\.title), ["déménage", "Matin", "a", "Soir", "b"])
  }

  /// Deux dépôts d'affilée gardent l'ordre d'arrivée, la seconde par-dessus la première. C'est le
  /// cas que le rang négatif rend possible : sans lui, la seconde n'aurait aucune place au-dessus
  /// de la première une fois le rang 0 pris.
  func testTwoFilingsInARowStack() throws {
    let ctx = try makeContext()
    let source = TodoList(title: "source")
    let target = TodoList(title: "cible")
    ctx.insert(source)
    ctx.insert(target)
    let existing = TaskItem(title: "a", list: target)
    ctx.insert(existing)
    let first = TaskItem(title: "première", list: source)
    let second = TaskItem(title: "seconde", list: source)
    ctx.insert(first)
    ctx.insert(second)

    first.move(to: target)
    second.move(to: target)

    XCTAssertEqual(target.orderedTasks.map(\.title), ["seconde", "première", "a"])
  }

  // MARK: L'état du geste

  /// La cible se lit AVANT de désarmer, et `drop()` fait les deux : sans ça, la page conclurait son
  /// geste sur un état qui n'existe plus.
  @MainActor
  func testDropReadsTheHoveredRowThenDisarms() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "cible")
    ctx.insert(list)
    let task = TaskItem(title: "en vol", list: list)
    ctx.insert(task)

    let filing = SidebarDrop()
    filing.measured([SidebarFiling.dropRow(for: list): CGRect(x: 0, y: 0, width: 200, height: 30)])
    filing.track(CGRect(x: 300, y: 0, width: 400, height: 30))
    XCTAssertNil(filing.hovered, "la ligne n'est pas encore entrée dans la sidebar")

    filing.track(CGRect(x: 40, y: 0, width: 400, height: 30))
    XCTAssertEqual(filing.hovered, SidebarFiling.dropRow(for: list))

    XCTAssertEqual(filing.drop(in: [list])?.persistentModelID, list.persistentModelID)
    XCTAssertNil(filing.hovered, "le geste est terminé")
  }

  /// Survoler la ligne d'un projet puis relâcher ne range rien : `list` y vaut `nil`, et `drop`
  /// désarme quand même le geste.
  @MainActor
  func testDroppingOnAProjectRowResolvesNothing() throws {
    let ctx = try makeContext()
    let project = Project(title: "Maison")
    ctx.insert(project)
    let list = TodoList(title: "une liste")
    list.project = project
    ctx.insert(list)

    let filing = SidebarDrop()
    filing.measured([
      SidebarFiling.dropRow(for: project): CGRect(x: 0, y: 0, width: 200, height: 30)
    ])
    filing.track(CGRect(x: 40, y: 0, width: 400, height: 30))

    XCTAssertNil(filing.drop(in: [list]))
    XCTAssertNil(filing.hovered, "le geste est terminé")
  }

  /// Le passage de témoin entre la rangée et le calque. UN seul booléen le porte : la fenêtre s'en
  /// sert pour montrer la pilule, la page pour effacer sa rangée. Deux conditions écrites séparément
  /// auraient fini par diverger d'une image — on aurait vu les deux, ou aucune.
  @MainActor
  func testTheGhostTakesOverExactlyWhenTheRowLeavesThePage() {
    let filing = SidebarDrop()
    filing.sidebarEdge = 282

    XCTAssertFalse(filing.isAirborne, "hors geste, rien ne vole")

    filing.track(CGRect(x: 300, y: 100, width: 400, height: 30))
    XCTAssertFalse(filing.isAirborne, "encore dans la page : c'est la vraie rangée qu'on voit")

    filing.track(CGRect(x: 281, y: 100, width: 400, height: 30))
    XCTAssertTrue(filing.isAirborne, "le bord franchi : le calque prend le relais")

    filing.track(nil)
    XCTAssertFalse(filing.isAirborne)
  }

  /// Empoignée à son EXTRÉMITÉ droite (loin de son bord avant), la ligne franchit la sidebar bien
  /// avant que le curseur ne l'atteigne — sauf si `isAirborne` vise le curseur (`grabOffsetX`),
  /// pas le bord de la rangée. Cf. les Pièges de CLAUDE.md, mesuré le 7 août 2026.
  @MainActor
  func testIsAirborneFollowsTheGrabPointNotTheRowEdge() {
    let filing = SidebarDrop()
    filing.sidebarEdge = 282
    // Ligne large (400 pt), empoignée à 380 pt de son bord avant (proche de son bord droit).
    filing.arm(grabOffsetX: 380)

    // Le bord avant a déjà franchi la sidebar, mais le point d'empoignade (280 + 380 = 660) ne l'a
    // pas encore atteinte.
    filing.track(CGRect(x: 100, y: 100, width: 400, height: 30))
    XCTAssertFalse(filing.isAirborne, "le curseur (à 480) n'a pas encore franchi le bord (282)")

    filing.track(CGRect(x: -100, y: 100, width: 400, height: 30))
    XCTAssertTrue(filing.isAirborne, "le curseur (à 280) a franchi le bord (282)")
  }

  /// Même correction, côté cible : sans elle, un dépôt empoigné loin du bord de sa ligne pouvait
  /// résoudre vers une liste que le curseur ne survole pourtant plus.
  @MainActor
  func testHoveredFollowsTheGrabPointNotTheRowEdge() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "cible")
    ctx.insert(list)

    let filing = SidebarDrop()
    filing.measured([SidebarFiling.dropRow(for: list): CGRect(x: 0, y: 0, width: 200, height: 30)])
    // Bord avant (40) dans la ligne — mais la ligne tirée fait 400 pt et on l'a empoignée à 380 pt
    // de ce bord : le curseur (40 + 380 = 420) n'y est plus.
    filing.track(CGRect(x: 40, y: 0, width: 400, height: 30))

    filing.arm(grabOffsetX: 380)
    XCTAssertNil(
      filing.hovered, "le curseur est hors de la ligne, même si le bord avant y est encore")

    filing.arm(grabOffsetX: 0)
    XCTAssertEqual(
      filing.hovered, SidebarFiling.dropRow(for: list),
      "sans décalage, le bord avant seul vise juste")
  }

  /// Sidebar repliée : son bord est à 0, donc plus rien ne peut voler — et c'est juste, il n'y a
  /// aucune destination à viser.
  @MainActor
  func testNothingFliesWhenTheSidebarIsCollapsed() {
    let filing = SidebarDrop()
    filing.sidebarEdge = 0
    filing.track(CGRect(x: 20, y: 100, width: 400, height: 30))

    XCTAssertFalse(filing.isAirborne)
  }

  /// Les cadres de la sidebar continuent d'être mesurés PENDANT un glissement — depuis que survoler
  /// un projet le déplie : les listes qu'il révèle n'existaient pas à l'empoignade, il faut donc
  /// pouvoir les accueillir en cours de route pour qu'elles deviennent des cibles valides.
  @MainActor
  func testSidebarFramesUpdateWhileATaskIsInFlight() throws {
    let ctx = try makeContext()
    let list = TodoList(title: "cible")
    ctx.insert(list)
    let revealed = [SidebarFiling.dropRow(for: list): CGRect(x: 0, y: 900, width: 200, height: 30)]

    let filing = SidebarDrop()
    filing.measured([SidebarFiling.dropRow(for: list): CGRect(x: 0, y: 0, width: 200, height: 30)])
    filing.track(CGRect(x: 40, y: 0, width: 400, height: 30))
    filing.measured(revealed)

    XCTAssertEqual(filing.rows, revealed)
  }
}
