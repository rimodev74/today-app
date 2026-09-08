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

  // MARK: Rappel ou événement — l'exclusivité, et ce qui la déclenche

  /// La règle du chantier : une durée, et la tâche cesse d'être une sonnerie pour devenir un
  /// créneau. Sans cette exclusivité, la même tâche existerait des DEUX côtés d'Apple.
  func testUneDureeEnvoieLaTacheDansLeCalendrier() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .event)
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: false), .reminder)
  }

  /// Le réglage est ce qui allume la fonction : sans calendrier désigné, une durée ne change rien
  /// — les tâches à durée qui partaient en rappel continuent d'y partir.
  func testSansCalendrierDesigneToutResteUnRappel() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 30
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: false), .reminder)
  }

  /// **Une durée SANS date ne va nulle part.** C'est l'ordre dans lequel on travaille : on estime
  /// souvent avant de planifier, et une estimation n'est pas un rendez-vous. Tant qu'aucun jour
  /// n'est posé, il n'y a tout simplement pas d'heure à réserver — la tâche reste dans l'app, et
  /// le calendrier n'en sait rien. L'événement n'apparaît qu'au moment où la date arrive.
  func testUneDureeSansDateNeVaPasDansLeCalendrier() {
    let task = dated(on: nil)
    task.estimateMinutes = 60
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .none)
    XCTAssertFalse(
      RemindersSync.needsEventPush(
        task, eventStart: nil, eventMinutes: nil, calendar: calendar))
  }

  /// Le même fait vu de l'autre bout : la date arrive APRÈS la durée, et c'est elle qui déclenche
  /// l'écriture. Sans ce test, inverser une condition dans `destination` passerait inaperçu.
  func testLaDatePoseeApresLaDureeDeclencheLEvenement() {
    let task = dated(on: nil)
    task.estimateMinutes = 60
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .none)
    task.when = day(2026, 9, 10)
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .event)
  }

  func testUneTacheSansDureeResteUnRappel() {
    let task = dated(on: day(2026, 9, 10))
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .reminder)
  }

  func testUneTacheCocheeNeVaNullePart() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.isCompleted = true
    XCTAssertEqual(RemindersSync.destination(for: task, eventCalendarChosen: true), .none)
  }

  // MARK: L'arrêt, côté événements

  func testTacheADureeSansEvenementDoitEtrePoussee() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    XCTAssertTrue(
      RemindersSync.needsEventPush(
        task, eventStart: nil, eventMinutes: nil, calendar: calendar))
  }

  func testEvenementDejaConformeNestPasReecrit() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.whenMinutes = 14 * 60 + 30
    let start = calendar.date(bySettingHour: 14, minute: 30, second: 0, of: day(2026, 9, 10))!
    XCTAssertFalse(
      RemindersSync.needsEventPush(
        task, eventStart: start, eventMinutes: 60, calendar: calendar))
  }

  func testDureeChangeeDeclencheUneReecriture() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 120
    task.whenMinutes = 14 * 60
    let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day(2026, 9, 10))!
    XCTAssertTrue(
      RemindersSync.needsEventPush(
        task, eventStart: start, eventMinutes: 60, calendar: calendar))
  }

  /// Le pendant exact de `testMemeJourAUneHeureDifferenteNestPasReecrit` : sans heure à elle, la
  /// tâche ne réclame qu'un JOUR — un événement déplacé à la main dans Calendrier garde son heure.
  func testEvenementDeplaceDansLaJourneeResteOuIlEstSiLaTacheNaPasDHeure() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day(2026, 9, 10))!
    XCTAssertFalse(
      RemindersSync.needsEventPush(
        task, eventStart: start, eventMinutes: 60, calendar: calendar))
  }

  /// Avec une heure, la tâche fait foi : sans cette branche, le sélecteur d'heure n'aurait aucun
  /// effet visible sur le créneau.
  func testHeureDeLaTacheFaitFoiQuandElleEnAUne() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.whenMinutes = 9 * 60
    let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day(2026, 9, 10))!
    XCTAssertTrue(
      RemindersSync.needsEventPush(
        task, eventStart: start, eventMinutes: 60, calendar: calendar))
  }

  // MARK: Le retour arrière — retirer la durée défait ce que la poser avait fait

  func testRetirerLaDureeEffaceLEvenement() {
    let task = dated(on: day(2026, 9, 10))
    task.eventIdentifier = "event-1"
    XCTAssertTrue(RemindersSync.shouldForgetEvent(task))
  }

  func testRetirerLaDateEffaceLEvenement() {
    let task = dated(on: nil)
    task.estimateMinutes = 60
    task.eventIdentifier = "event-1"
    XCTAssertTrue(RemindersSync.shouldForgetEvent(task))
  }

  /// Cocher une tâche n'efface PAS son bloc d'agenda : un événement passé raconte ce qu'on a fait
  /// de sa journée.
  func testCocherUneTacheNeSupprimePasSonEvenement() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.eventIdentifier = "event-1"
    task.isCompleted = true
    XCTAssertFalse(RemindersSync.shouldForgetEvent(task))
  }

  func testUneTacheSansEvenementNaRienAOublier() {
    XCTAssertFalse(RemindersSync.shouldForgetEvent(dated(on: nil)))
  }

  // MARK: L'autre sens — l'événement supprimé dans le Calendrier

  /// Le miroir : effacer le créneau retire la durée, et la tâche redevient un rappel. Sans ça,
  /// l'événement renaissait à la passe suivante et supprimer n'avait aucun effet visible.
  func testEvenementSupprimeRetireLaDuree() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.eventIdentifier = "event-1"
    XCTAssertTrue(RemindersSync.shouldDropDuration(task, vanished: true))
  }

  /// **Le garde-fou du 5 août 2026.** Une absence non confirmée ne retire RIEN : `vanished` doit
  /// être une affirmation prouvée (vu vivant, puis absent deux passes), jamais un simple
  /// « EventKit ne le trouve pas » — c'est cette confusion qui avait effacé trois tâches.
  func testUneAbsenceNonConfirmeeNeRetireRien() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    task.eventIdentifier = "event-1"
    XCTAssertFalse(RemindersSync.shouldDropDuration(task, vanished: false))
  }

  /// Une tâche jamais partie dans l'agenda n'a pas de durée à perdre — sans quoi un verdict égaré
  /// viderait l'estimation d'une tâche qui n'a jamais eu d'événement.
  func testSansEvenementLieLaDureeNeTombePas() {
    let task = dated(on: day(2026, 9, 10))
    task.estimateMinutes = 60
    XCTAssertFalse(RemindersSync.shouldDropDuration(task, vanished: true))
  }

  // MARK: Qui fait foi — la fusion à trois

  /// Le créneau, tel qu'on l'écrit et tel qu'on le relit.
  private func slot(_ start: Date, _ minutes: Int) -> DateInterval {
    DateInterval(start: start, duration: TimeInterval(minutes) * 60)
  }

  private func at(_ hour: Int, _ minute: Int = 0, on day: Date) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
  }

  private func timed(on when: Date, minutes: Int, at hour: Int? = nil) -> TaskItem {
    let task = dated(on: when)
    task.estimateMinutes = minutes
    task.whenMinutes = hour.map { $0 * 60 }
    task.eventIdentifier = "event-1"
    return task
  }

  /// **Le défaut que tout ceci corrige.** L'événement ne porte plus ce qu'on y avait laissé : il a
  /// été déplacé dans Calendrier, et c'est LUI qui fait foi. Avant, la comparaison seule concluait
  /// « la tâche et l'événement diffèrent, donc réécrire » — le créneau revenait à sa place.
  func testEvenementDeplaceDansCalendrierRemonteDansLaTache() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    let accord = slot(at(9, on: day(2026, 9, 10)), 60)
    let deplace = slot(at(9, on: day(2026, 9, 12)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: deplace, lastSeen: accord, calendar: calendar), .pull)
  }

  /// Même règle pour la DURÉE rallongée à la main — le cas nommé par l'utilisateur.
  func testDureeAllongeeDansCalendrierRemonteDansLaTache() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    let accord = slot(at(9, on: day(2026, 9, 10)), 60)
    let rallonge = slot(at(9, on: day(2026, 9, 10)), 90)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: rallonge, lastSeen: accord, calendar: calendar),
      .pull)
  }

  /// Et l'HEURE seule, y compris sur une tâche qui n'en portait pas : l'accord mémorisé rend
  /// l'écart visible là où la comparaison par jour, elle, ne voyait rien.
  func testHeureChangeeDansCalendrierRemonteMemeSansHeureSurLaTache() {
    let task = timed(on: day(2026, 9, 10), minutes: 60)
    let accord = slot(at(9, on: day(2026, 9, 10)), 60)
    let repousse = slot(at(14, 30, on: day(2026, 9, 10)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: repousse, lastSeen: accord, calendar: calendar),
      .pull)
  }

  /// L'autre sens, et c'est le MÊME écart : l'événement est tel qu'on l'avait laissé, donc c'est
  /// la tâche qui a bougé. Sans le troisième terme, rien ne distingue ce cas du précédent.
  func testTacheModifieeDansLAppPousseVersLeCalendrier() {
    let task = timed(on: day(2026, 9, 10), minutes: 120, at: 9)
    let accord = slot(at(9, on: day(2026, 9, 10)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: accord, lastSeen: accord, calendar: calendar), .push)
  }

  /// La condition d'arrêt : après une reprise, la tâche porte ce que porte l'événement, donc la
  /// passe suivante ne trouve plus rien à faire. Sans ce test, une reprise pourrait relancer un
  /// push, qui relancerait une reprise — la boucle exacte que ce fichier existe pour écarter.
  func testUneRepriseEteintLaChaine() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    let deplace = slot(at(14, 30, on: day(2026, 9, 12)), 90)
    RemindersSync.adopt(
      deplace.start, minutes: Int(deplace.duration / 60), on: task, calendar: calendar)
    XCTAssertEqual(task.when, day(2026, 9, 12))
    XCTAssertEqual(task.whenMinutes, 14 * 60 + 30)
    XCTAssertEqual(task.estimateMinutes, 90)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: deplace, lastSeen: deplace, calendar: calendar),
      .agreed)
  }

  /// Au lancement il n'y a aucune mémoire, et l'app ne peut pas avoir modifié une tâche pendant
  /// qu'elle était fermée : l'écart vient forcément du Calendrier.
  func testAuLancementLeCalendrierFaitFoi() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    let deplace = slot(at(9, on: day(2026, 9, 12)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: deplace, lastSeen: nil, calendar: calendar), .pull)
  }

  /// **Le garde-fou du lancement.** Une tâche SANS heure ne réclame qu'un jour : l'heure par
  /// défaut posée sur son événement n'est pas un écart. Sans cette tolérance, chaque lancement
  /// ferait adopter 09:00 à toutes les tâches datées — une heure que personne n'a choisie.
  func testAuLancementLHeurePardefautNestPasUnChangement() {
    let task = timed(on: day(2026, 9, 10), minutes: 60)
    let neuf = slot(at(9, on: day(2026, 9, 10)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: neuf, lastSeen: nil, calendar: calendar), .agreed)
  }

  /// Rien à lire, rien à reprendre : un identifiant périmé (base restaurée) se réécrit, sinon une
  /// sauvegarde remontée perdrait son agenda au lieu de le retrouver.
  func testSansEvenementLisibleOnEcrit() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    XCTAssertEqual(
      RemindersSync.eventVerdict(task, event: nil, lastSeen: nil, calendar: calendar), .push)
  }

  /// Une tâche cochée ne se fait plus rien dicter : son créneau passé raconte sa journée, et le
  /// modifier dans Calendrier ne doit pas rouvrir sa date.
  func testUneTacheCocheeNeReprendRien() {
    let task = timed(on: day(2026, 9, 10), minutes: 60, at: 9)
    task.isCompleted = true
    let deplace = slot(at(9, on: day(2026, 9, 12)), 60)
    XCTAssertEqual(
      RemindersSync.eventVerdict(
        task, event: deplace, lastSeen: slot(at(9, on: day(2026, 9, 10)), 60), calendar: calendar),
      .agreed)
  }

  // MARK: Qui fait foi — côté rappels, la même règle

  func testEchanceChangeeDansRappelsRemonteDansLaTache() {
    let task = dated(on: day(2026, 8, 10))
    task.reminderIdentifier = "reminder-1"
    XCTAssertEqual(
      RemindersSync.reminderVerdict(
        task, due: at(9, on: day(2026, 8, 12)), lastSeen: at(9, on: day(2026, 8, 10)),
        wasSeenAlive: true, calendar: calendar), .pull)
  }

  func testTacheModifieeDansLAppPousseVersRappels() {
    let task = dated(on: day(2026, 8, 10))
    task.whenMinutes = 11 * 60
    task.reminderIdentifier = "reminder-1"
    let accord = at(9, on: day(2026, 8, 10))
    XCTAssertEqual(
      RemindersSync.reminderVerdict(
        task, due: accord, lastSeen: accord, wasSeenAlive: true, calendar: calendar), .push)
  }

  /// Un rappel introuvable ne se REPREND pas : il se recrée ou se laisse mort, selon qu'on l'ait
  /// vu vivant (cf. `needsPush`). C'est ce qui protège la preuve qu'attend `shouldDelete`.
  func testUnRappelIntrouvableNeSeReprendPas() {
    let task = dated(on: day(2026, 8, 10))
    task.reminderIdentifier = "reminder-1"
    XCTAssertEqual(
      RemindersSync.reminderVerdict(
        task, due: nil, lastSeen: at(9, on: day(2026, 8, 10)), wasSeenAlive: true,
        calendar: calendar), .agreed)
    XCTAssertEqual(
      RemindersSync.reminderVerdict(
        task, due: nil, lastSeen: nil, wasSeenAlive: false, calendar: calendar), .push)
  }
}
