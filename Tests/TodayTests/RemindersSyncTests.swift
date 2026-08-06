import SwiftData
import XCTest

@testable import Today

/// Ce qui est vérifié ici, c'est la CONDITION D'ARRÊT de la synchro : les deux sens partent du même
/// point, et chacune de nos écritures dans EventKit relance ce point. Si `needsPush` répondait
/// « oui » à une tâche déjà à jour, l'app réécrirait le rappel en boucle sans jamais se taire — un
/// défaut invisible en test manuel court, et coûteux en batterie comme en données.
final class RemindersSyncTests: XCTestCase {
  private let calendar = Calendar(identifier: .gregorian)

  private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d))!
  }

  private func dated(_ title: String = "Acheter du pain", on when: Date?) -> TaskItem {
    TaskItem(title: title, when: when)
  }

  // MARK: L'arrêt

  func testTacheSansRappelDoitEtrePoussee() {
    let task = dated(on: day(2026, 8, 10))
    XCTAssertTrue(
      RemindersSync.needsPush(task, reminderDue: nil, wasSeenAlive: false, calendar: calendar))
  }

  func testRappelDejaSurLeBonJourNestPasReecrit() {
    let task = dated(on: day(2026, 8, 10))
    XCTAssertFalse(
      RemindersSync.needsPush(
        task, reminderDue: day(2026, 8, 10), wasSeenAlive: false, calendar: calendar))
  }

  /// Le cas qui protège l'heure d'un rappel importé : même jour, heure différente — on ne touche
  /// à rien. C'est la comparaison par JOUR, et elle seule, qui rend l'import non destructeur.
  func testMemeJourAUneHeureDifferenteNestPasReecrit() {
    let task = dated(on: day(2026, 8, 10))
    let dixHuitHeures = calendar.date(
      bySettingHour: 18, minute: 30, second: 0, of: day(2026, 8, 10))!
    XCTAssertFalse(
      RemindersSync.needsPush(
        task, reminderDue: dixHuitHeures, wasSeenAlive: false, calendar: calendar))
  }

  func testDateChangeeDeclencheUneReecriture() {
    let task = dated(on: day(2026, 8, 11))
    XCTAssertTrue(
      RemindersSync.needsPush(
        task, reminderDue: day(2026, 8, 10), wasSeenAlive: false, calendar: calendar))
  }

  // MARK: Ce qui n'a rien à faire dans Rappels

  func testTacheSansDateNestPasPoussee() {
    XCTAssertFalse(
      RemindersSync.needsPush(
        dated(on: nil), reminderDue: nil, wasSeenAlive: false, calendar: calendar))
  }

  func testTacheCocheeNestPasPoussee() {
    let task = dated(on: day(2026, 8, 10))
    task.isCompleted = true
    XCTAssertFalse(
      RemindersSync.needsPush(task, reminderDue: nil, wasSeenAlive: false, calendar: calendar))
  }

  func testEnTeteNestPasPoussee() {
    let header = TaskItem(title: "Matin", when: day(2026, 8, 10), isHeader: true)
    XCTAssertFalse(
      RemindersSync.needsPush(header, reminderDue: nil, wasSeenAlive: false, calendar: calendar))
  }

  /// ⌘N crée une tâche VIDE que la page « Aujourd'hui » date d'office. Sans ce filtre, chaque ⌘N
  /// suivi d'Échap laissait un rappel sans titre dans l'app Rappels.
  func testTacheSansTitreNestPasPoussee() {
    XCTAssertFalse(
      RemindersSync.needsPush(
        dated("   ", on: day(2026, 8, 10)), reminderDue: nil, wasSeenAlive: false,
        calendar: calendar))
  }

  // MARK: L'heure de la tâche (schéma 5.0.0)

  /// Le cas qui a motivé le champ : la date ne bouge pas, seule l'HEURE change. Comparer les jours
  /// aurait répondu « rien à faire », et le sélecteur d'heure n'aurait rien produit côté Rappels.
  func testHeureChangeeSeuleDeclencheUneReecriture() {
    let task = dated(on: day(2026, 8, 10))
    task.whenMinutes = 14 * 60 + 30
    let neufHeures = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day(2026, 8, 10))!
    XCTAssertTrue(
      RemindersSync.needsPush(
        task, reminderDue: neufHeures, wasSeenAlive: false, calendar: calendar))
  }

  func testTacheAvecHeureDejaAJourNestPasReecrite() {
    let task = dated(on: day(2026, 8, 10))
    task.whenMinutes = 14 * 60 + 30
    let due = RemindersSync.due(for: task.when!, minutes: task.whenMinutes, calendar: calendar)
    XCTAssertFalse(
      RemindersSync.needsPush(task, reminderDue: due, wasSeenAlive: false, calendar: calendar))
  }

  /// L'heure de la TÂCHE prime sur celle des Réglages — sinon le sélecteur ne servirait à rien
  /// dès que le réglage vaut autre chose que 9 h.
  func testLHeureDeLaTachePrimeSurCelleDesReglages() {
    let due = RemindersSync.due(
      for: day(2026, 8, 10), minutes: 7 * 60 + 15, hour: 18, calendar: calendar)
    XCTAssertEqual(calendar.component(.hour, from: due), 7)
    XCTAssertEqual(calendar.component(.minute, from: due), 15)
  }

  // MARK: L'échéance posée

  func testEcheanceEstPoseeAHeureRaisonnable() {
    let due = RemindersSync.due(for: day(2026, 8, 10), calendar: calendar)
    XCTAssertEqual(calendar.component(.hour, from: due), RemindersSync.dueHour)
    XCTAssertEqual(calendar.component(.minute, from: due), 0)
    XCTAssertTrue(calendar.isDate(due, inSameDayAs: day(2026, 8, 10)))
  }

  func testLHeureRegleeEstCellePoseeSurLEcheance() {
    let due = RemindersSync.due(for: day(2026, 8, 10), hour: 18, calendar: calendar)
    XCTAssertEqual(calendar.component(.hour, from: due), 18)
    XCTAssertTrue(calendar.isDate(due, inSameDayAs: day(2026, 8, 10)))
  }

  /// Une heure hors 0…23 (défaut corrompu, réglage recopié à la main) ne doit pas faire retomber
  /// l'échéance à minuit — c'est-à-dire à l'alarme de la veille au soir que le réglage évite.
  func testUneHeureAberranteEstBornee() {
    XCTAssertEqual(
      calendar.component(
        .hour, from: RemindersSync.due(for: day(2026, 8, 10), hour: 99, calendar: calendar)),
      23)
    XCTAssertEqual(
      calendar.component(
        .hour, from: RemindersSync.due(for: day(2026, 8, 10), hour: -3, calendar: calendar)),
      0)
  }

  // MARK: Le rappel supprimé côté Apple

  private func linked(on when: Date?) -> TaskItem {
    let task = dated(on: when)
    task.reminderIdentifier = "x-apple-reminderkit://REMCDReminder/1234"
    return task
  }

  /// Le défaut corrigé : rappel supprimé et tâche jamais poussée sont le même fait pour
  /// `needsPush`, qui recréait donc le rappel dans la seconde — supprimer côté Rappels n'avait
  /// aucun effet visible.
  ///
  /// `vanished: true` est une affirmation FORTE (vu vivant dans cette session, puis absent deux
  /// passes de suite) — c'est `RemindersService.reminderVanished(_:)` qui la produit, pas une
  /// simple absence. Cf. le test de la base restaurée plus bas.
  func testRappelSupprimeEmporteLaTache() {
    XCTAssertTrue(RemindersSync.shouldDelete(linked(on: day(2026, 8, 10)), vanished: true))
  }

  func testRappelToujoursLaNeSupprimeRien() {
    XCTAssertFalse(RemindersSync.shouldDelete(linked(on: day(2026, 8, 10)), vanished: false))
  }

  /// Le défaut qui a coûté trois tâches le 5 août 2026, réduit à sa forme minimale : une base
  /// restaurée porte des identifiants de rappels nettoyés depuis longtemps. « Introuvable » y est
  /// l'état NORMAL, jamais un geste de l'utilisateur. Tant que le doute n'est pas levé
  /// (`vanished == false`), rien ne part.
  func testUneBaseRestauréeNePerdAucuneTache() {
    XCTAssertFalse(RemindersSync.shouldDelete(linked(on: day(2026, 8, 10)), vanished: false))
  }

  /// Une tâche jamais poussée n'a rien à voir avec un rappel disparu — et c'est la majorité de la
  /// base : sans ce garde-fou, la passe viderait l'app.
  func testTacheSansRappelNestJamaisSupprimee() {
    XCTAssertFalse(RemindersSync.shouldDelete(dated(on: day(2026, 8, 10)), vanished: true))
  }

  /// Hors du périmètre de la boucle, un lien mort reste sans conséquence : une tâche cochée garde
  /// sa place dans les archives même si Rappels a fait le ménage de son côté.
  func testTacheCocheeSurvitALaDisparitionDeSonRappel() {
    let task = linked(on: day(2026, 8, 10))
    task.isCompleted = true
    XCTAssertFalse(RemindersSync.shouldDelete(task, vanished: true))
  }

  func testTacheDontOnARetireLaDateSurvit() {
    XCTAssertFalse(RemindersSync.shouldDelete(linked(on: nil), vanished: true))
  }

  /// Une tâche au titre vide ne part pas non plus : ⌘N puis Échap en laisse passer, et elles
  /// n'ont jamais eu de rappel à perdre.
  func testTacheSansTitreNestJamaisSupprimee() {
    let task = dated("", on: day(2026, 8, 10))
    task.reminderIdentifier = "x-apple-reminderkit://REMCDReminder/1234"
    XCTAssertFalse(RemindersSync.shouldDelete(task, vanished: true))
  }

  /// Une échéance ainsi posée ne doit pas rappeler la tâche à elle-même : le rappel créé porte le
  /// jour de la tâche, `needsPush` doit donc répondre non tout de suite après.
  func testLEcheancePoseeSatisfaitImmediatementNeedsPush() {
    let task = dated(on: day(2026, 8, 10))
    let due = RemindersSync.due(for: task.when!, calendar: calendar)
    XCTAssertFalse(
      RemindersSync.needsPush(task, reminderDue: due, wasSeenAlive: false, calendar: calendar))
  }

  // MARK: Le déclencheur du sens app → Rappels

  /// `ContentView` réveille la synchro sur `ModelContext.didSave` — c'est le SEUL déclencheur du
  /// sens app → Rappels, dater une tâche n'écrivant que dans SwiftData. Toute la correction du
  /// délai (une quinzaine de secondes, mesurées à l'usage le 6 août 2026) repose sur le fait que
  /// SwiftData poste bien cette notification ; ici on le vérifie plutôt que de le supposer.
  @MainActor
  func testSwiftDataPosteBienDidSave() throws {
    let schema = Schema([Project.self, TodoList.self, TaskItem.self, Subtask.self])
    let container = try ModelContainer(
      for: schema,
      configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let context = ModelContext(container)

    let posted = expectation(description: "ModelContext.didSave")
    let token = NotificationCenter.default.addObserver(
      forName: ModelContext.didSave, object: nil, queue: nil
    ) { _ in posted.fulfill() }
    defer { NotificationCenter.default.removeObserver(token) }

    context.insert(TaskItem(title: "Acheter du pain", when: day(2026, 8, 10)))
    try context.save()

    wait(for: [posted], timeout: 2)
  }

  // MARK: Le rappel supprimé depuis l'app Rappels

  /// LE défaut du 6 août 2026, signalé à l'usage : supprimer un rappel dans l'app Rappels ne
  /// supprimait pas la tâche, et le rappel réapparaissait dans la seconde.
  ///
  /// La cause tient en une ligne : le push traitait « rappel introuvable » comme « jamais poussé »,
  /// donc le recréait DANS LA MÊME PASSE que celle qui venait d'enregistrer sa disparition. La
  /// passe suivante voyait un rappel bien vivant — le nôtre — et les deux preuves qu'exige
  /// `RemindersService.reminderVanished` ne pouvaient jamais être réunies.
  func testUnRappelVuVivantPuisDisparuNestPasRecree() {
    let task = dated(on: day(2026, 8, 10))
    task.reminderIdentifier = "x-apple-reminderkit://REMCDReminder/1234"
    XCTAssertFalse(
      RemindersSync.needsPush(task, reminderDue: nil, wasSeenAlive: true, calendar: calendar))
  }

  /// Le pendant, et c'est lui qui interdit de simplement « ne jamais recréer » : une base restaurée
  /// porte des identifiants périmés, jamais vus vivants. Ceux-là DOIVENT repartir, sinon remonter
  /// une sauvegarde laisserait toutes ses tâches sans rappel, définitivement.
  func testUnIdentifiantPerimeEstBienRepousse() {
    let task = dated(on: day(2026, 8, 10))
    task.reminderIdentifier = "x-apple-reminderkit://REMCDReminder/perime"
    XCTAssertTrue(
      RemindersSync.needsPush(task, reminderDue: nil, wasSeenAlive: false, calendar: calendar))
  }

  /// Une tâche qui n'a jamais eu de rappel part toujours, quoi qu'ait vu la session.
  func testTacheJamaisLieePartQuandMeme() {
    let task = dated(on: day(2026, 8, 10))
    XCTAssertTrue(
      RemindersSync.needsPush(task, reminderDue: nil, wasSeenAlive: true, calendar: calendar))
  }

  /// Le verrou DIT quand il refuse. C'est ce retour qui permet à `ContentView.syncWithReminders` de
  /// repasser plus tard : sans lui, un changement extérieur tombé pendant une passe était perdu
  /// jusqu'au prochain retour au premier plan, sans trace.
  @MainActor
  func testLeVerrouRefuseUnePasseConcurrenteEtLeDit() async {
    let service = RemindersService()
    var nested: Bool?
    let ran = await service.withSyncLock {
      nested = await service.withSyncLock {}
    }
    XCTAssertTrue(ran, "la première passe s'exécute")
    XCTAssertEqual(nested, false, "la seconde est refusée, et le dit")
    let after = await service.withSyncLock {}
    XCTAssertTrue(after, "le verrou est rendu à la sortie")
  }
}
