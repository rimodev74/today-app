import EventKit
import Foundation

/// Erreurs métier exposées à l'UI — messages compréhensibles, découplés d'EventKit.
enum RemindersError: LocalizedError {
  case accessDenied
  case noWritableList
  case saveFailed(underlying: Error)

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      return "Accès aux rappels refusé. Autorise Today dans "
        + "Réglages Système › Confidentialité et sécurité › Rappels."
    case .noWritableList:
      return "Aucune liste de rappels modifiable n'est disponible."
    case .saveFailed(let underlying):
      return "Impossible d'enregistrer le rappel : \(underlying.localizedDescription)"
    }
  }
}

/// Toute la logique EventKit vit ici. Les vues ne touchent jamais EventKit directement :
/// une future synchro bidirectionnelle (fetch, observation du store, complétion, suppression…)
/// s'ajoutera dans ce service sans réécrire l'UI.
@Observable
@MainActor
final class RemindersService {
  private let store = EKEventStore()

  var authorizationStatus: EKAuthorizationStatus {
    EKEventStore.authorizationStatus(for: .reminder)
  }

  /// Listes de rappels où l'écriture est permise — pour laisser l'utilisateur choisir sa destination.
  /// Vide tant que l'accès n'a pas été accordé.
  var writableLists: [EKCalendar] {
    store.calendars(for: .reminder).filter(\.allowsContentModifications)
  }

  var defaultList: EKCalendar? {
    store.defaultCalendarForNewReminders()
  }

  /// Calendriers d'ÉVÉNEMENTS où l'écriture est permise — la destination des tâches à durée.
  /// Vide tant que l'accès au Calendrier n'a pas été accordé (autorisation distincte de celle des
  /// rappels, cf. `requestEventAccess`).
  var writableEventCalendars: [EKCalendar] {
    store.calendars(for: .event).filter(\.allowsContentModifications)
  }

  /// Le calendrier désigné dans les Réglages, s'il existe ENCORE — même précaution que
  /// `list(withIdentifier:)` : un calendrier supprimé laisse derrière lui un identifiant qui ne
  /// pointe plus sur rien, et rien ne prévient.
  func eventCalendar(withIdentifier identifier: String?) -> EKCalendar? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return writableEventCalendars.first { $0.calendarIdentifier == identifier }
  }

  /// Demande l'accès complet. Full (et non write-only) est nécessaire pour relire un rappel
  /// par son identifiant afin de le modifier plus tard (bonus + socle de la synchro).
  /// Lève `RemindersError.accessDenied` en cas de refus.
  func requestAccess() async throws {
    switch authorizationStatus {
    case .fullAccess:
      return
    case .denied, .restricted, .writeOnly:
      throw RemindersError.accessDenied
    case .notDetermined:
      fallthrough
    @unknown default:
      let granted = try await store.requestFullAccessToReminders()
      guard granted else { throw RemindersError.accessDenied }
    }
  }

  /// Crée le rappel — ou met à jour celui déjà associé si `existingIdentifier` pointe vers un
  /// rappel encore présent (bonus). Retourne le `calendarItemIdentifier` à conserver côté tâche.
  @discardableResult
  func schedule(
    title: String,
    start: Date,
    due: Date,
    list: EKCalendar? = nil,
    existingIdentifier: String? = nil
  ) async throws -> String {
    try await requestAccess()

    // Réutilise le rappel existant si on le retrouve, sinon en crée un neuf
    // (couvre le cas où l'utilisateur l'aurait supprimé côté Rappels).
    let reminder =
      existingIdentifier
      .flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
      ?? EKReminder(eventStore: store)

    guard let destination = list ?? reminder.calendar ?? defaultList else {
      throw RemindersError.noWritableList
    }

    let calendar = Calendar.current
    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]

    reminder.title = title
    reminder.calendar = destination
    reminder.startDateComponents = calendar.dateComponents(fields, from: start)
    reminder.dueDateComponents = calendar.dateComponents(fields, from: due)

    // Une échéance datée ne déclenche pas de notification seule : on pose une alarme à l'heure
    // d'échéance. On purge d'abord les anciennes pour ne pas les empiler lors d'une mise à jour.
    reminder.alarms?.forEach(reminder.removeAlarm)
    reminder.addAlarm(EKAlarm(absoluteDate: due))

    do {
      try store.save(reminder, commit: true)
    } catch {
      throw RemindersError.saveFailed(underlying: error)
    }
    return reminder.calendarItemIdentifier
  }

  // MARK: Écriture — les tâches à DURÉE, qui partent en événements et non en rappels

  /// Crée le bloc d'agenda de cette tâche — ou déplace celui qui existe déjà si `existingIdentifier`
  /// pointe encore sur un événement. Retourne l'`eventIdentifier` à conserver côté tâche, `nil` si
  /// l'accès est refusé ou l'enregistrement impossible.
  ///
  /// Muet, contrairement à `schedule(…)` qui lève : le seul appelant est la passe de synchro, qui
  /// n'a personne à qui montrer une erreur (elle tourne toute seule, réveillée par une notification).
  /// Une erreur laisse simplement la tâche sans son événement, et la passe suivante réessaie.
  ///
  /// `.thisEvent` et pas `.futureEvents` : nos événements ne sont jamais récurrents. Sur un
  /// événement qui le serait devenu (l'utilisateur peut l'éditer dans Calendrier), c'est aussi le
  /// span le plus prudent — on ne touche que l'occurrence qu'on a créée.
  @discardableResult
  func scheduleEvent(
    title: String,
    start: Date,
    minutes: Int,
    calendar: EKCalendar?,
    existingIdentifier: String? = nil
  ) async -> String? {
    guard await requestEventAccess() else { return nil }

    // `existing` est distinct de `event` parce que c'est LUI qui dit où écrire : un événement
    // retrouvé garde son calendrier (déplacé à la main, il y reste), un événement neuf prend celui
    // des Réglages. L'appelant passe donc toujours le calendrier désigné — sans cette distinction,
    // un événement supprimé côté Calendrier se recréait dans le calendrier PAR DÉFAUT du système
    // au lieu de celui qu'on avait choisi.
    let existing = existingIdentifier.flatMap { store.event(withIdentifier: $0) }
    let event = existing ?? EKEvent(eventStore: store)
    guard let destination = existing?.calendar ?? calendar ?? store.defaultCalendarForNewEvents
    else { return nil }

    event.title = title
    event.calendar = destination
    event.startDate = start
    event.endDate = start.addingTimeInterval(TimeInterval(minutes) * 60)

    guard (try? store.save(event, span: .thisEvent, commit: true)) != nil else { return nil }
    return event.eventIdentifier
  }

  /// Ce que portent les événements liés, relus en UNE requête sur la fenêtre qui les contient.
  ///
  /// **Un `event(withIdentifier:)` par tâche est exactement le défaut mesuré côté Rappels** (cf.
  /// `passSnapshot` : 97 échantillons de fil principal gelés dans un aller-retour XPC synchrone,
  /// app AU REPOS), et il se rejouerait ici à chaque `.EKEventStoreChanged` comme à chaque
  /// `ModelContext.didSave`. Une requête bornée à UN calendrier et aux jours des tâches concernées
  /// coûte le même aller-retour, une fois.
  ///
  /// Un événement déplacé HORS de la fenêtre n'est pas retrouvé ici — c'est `eventTime(_:)` qui
  /// va le chercher, une lecture à l'unité pour ce seul cas. Sans elle, « absent de la fenêtre »
  /// se lisait « pas d'événement », donc « réécrire », et déplacer un créneau de plus de deux
  /// jours dans Calendrier le ramenait au jour de sa tâche.
  func linkedEventTimes(
    _ identifiers: Set<String>, from start: Date, to end: Date, in calendar: EKCalendar
  ) -> [String: DateInterval] {
    guard eventAuthorizationStatus == .fullAccess, !identifiers.isEmpty, start < end else {
      return [:]
    }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
    return store.events(matching: predicate).reduce(into: [:]) { times, event in
      guard let id = event.eventIdentifier, identifiers.contains(id),
        let from = event.startDate, let to = event.endDate, from <= to
      else { return }
      times[id] = DateInterval(start: from, end: to)
    }
  }

  /// Ce que l'app sait de l'événement lié, et le NIVEAU DE PREUVE qui va avec.
  ///
  /// Quatre réponses et pas un booléen, parce que « introuvable » recouvre trois situations qui
  /// appellent des gestes opposés — et que les confondre a déjà coûté des données réelles (cf.
  /// `reminderVanished`, et les trois tâches effacées le 5 août 2026).
  enum EventPresence {
    /// Il est là.
    case alive
    /// Introuvable, et jamais vu vivant de la session : l'identifiant est périmé, pas orphelin.
    /// C'est le cas d'une base restaurée. On RECRÉE — c'est ce qui rend son agenda à une sauvegarde.
    case unknownIdentifier
    /// Vu vivant, puis absent UNE fois. Un compte iCloud qui se resynchronise fait disparaître et
    /// revenir des éléments : une absence isolée ne tranche rien. On ne touche à rien, et surtout
    /// on ne RÉÉCRIT pas — réécrire effacerait la preuve qu'attend la passe suivante.
    case missingOnce
    /// Vu vivant, puis absent DEUX passes de suite : l'utilisateur vient de le supprimer.
    case vanished
  }

  /// L'état de l'événement lié, avec ses preuves. `foundInWindow` vient de `linkedEventTimes` :
  /// trouvé là, il est vivant et l'on n'interroge personne. Ce n'est QUE pour une absence qu'on
  /// paie une lecture directe — rare par construction, et c'est ce qui évite de conclure « supprimé »
  /// sur un événement simplement déplacé hors de la fenêtre relue.
  func eventPresence(_ identifier: String, foundInWindow: Bool) -> EventPresence {
    guard eventAuthorizationStatus == .fullAccess else { return .alive }
    if foundInWindow || store.event(withIdentifier: identifier) != nil {
      eventsSeenAlive.insert(identifier)
      eventsMissedOnce.remove(identifier)
      return .alive
    }
    guard eventsSeenAlive.contains(identifier) else { return .unknownIdentifier }
    guard eventsMissedOnce.contains(identifier) else {
      eventsMissedOnce.insert(identifier)
      return .missingOnce
    }
    // Verdict rendu : on oublie cet événement, sinon `hasPendingEventVanishVerdict` réarmerait la
    // synchro indéfiniment pour un dossier clos (même piège que côté rappels).
    eventsMissedOnce.remove(identifier)
    eventsSeenAlive.remove(identifier)
    lastAgreed.removeValue(forKey: identifier)
    return .vanished
  }

  /// Une absence attend sa confirmation : il manque UNE passe pour trancher. L'appelant en relance
  /// une (cf. `ContentView.syncWithReminders`), sans quoi la durée resterait en sursis jusqu'au
  /// prochain réveil venu d'ailleurs — c'est-à-dire peut-être jamais.
  var hasPendingEventVanishVerdict: Bool { !eventsMissedOnce.isEmpty }

  /// En mémoire seulement, comme leurs équivalents côté rappels : la question posée est
  /// « l'utilisateur vient-il de le supprimer ? », qui n'a de sens que dans une session.
  private var eventsSeenAlive: Set<String> = []
  private var eventsMissedOnce: Set<String> = []

  /// Le créneau de l'événement lié, relu AU COUP PAR COUP — le repli quand la requête bornée ne
  /// l'a pas trouvé (cf. `linkedEventTimes`).
  ///
  /// C'est l'aller-retour XPC synchrone qu'on refuse de payer PAR TÂCHE, et il reste borné à ce
  /// qui manque : un événement déplacé hors de la fenêtre relue, donc de plusieurs jours, ce qui
  /// n'arrive qu'au geste de l'utilisateur et se résorbe à la passe suivante (la tâche adopte le
  /// nouveau jour, la fenêtre le contient à nouveau). `eventPresence` payait déjà exactement cette
  /// lecture pour la même absence : on la lui évite en lui passant le résultat (`foundInWindow:`).
  func eventTime(_ identifier: String) -> DateInterval? {
    guard eventAuthorizationStatus == .fullAccess,
      let event = store.event(withIdentifier: identifier),
      let start = event.startDate, let end = event.endDate, start <= end
    else { return nil }
    return DateInterval(start: start, end: end)
  }

  /// Ce que portait l'élément Apple lié la dernière fois que la tâche et lui étaient d'accord — le
  /// troisième terme sans lequel « qui a changé ? » n'a pas de réponse (cf.
  /// `RemindersSync.Verdict`). Un événement y range son créneau, un rappel son échéance seule
  /// (durée nulle) : les identifiants de rappel et d'événement ne vivent pas dans le même espace
  /// de noms, aucun ne peut être pris pour l'autre.
  ///
  /// En mémoire seulement, comme `eventsSeenAlive` et pour la même raison : la persister ferait
  /// croire au lancement qu'on sait qui a bougé pendant que l'app était fermée, alors que la
  /// réponse est toujours « pas nous ».
  private var lastAgreed: [String: DateInterval] = [:]

  func lastSeenEvent(_ identifier: String) -> DateInterval? { lastAgreed[identifier] }

  /// `nil` OUBLIE l'accord (l'affectation d'un `nil` retire la clé) : c'est ce qu'on veut d'un
  /// élément devenu illisible — au retour, on ne prétendra pas savoir ce qu'il portait avant.
  func rememberEvent(_ identifier: String, _ interval: DateInterval?) {
    lastAgreed[identifier] = interval
  }

  func lastSeenReminderDue(_ identifier: String) -> Date? { lastAgreed[identifier]?.start }

  func rememberReminderDue(_ identifier: String, _ due: Date?) {
    lastAgreed[identifier] = due.map { DateInterval(start: $0, duration: 0) }
  }

  /// Efface les événements dont la tâche n'a plus de durée (ou plus de date), et ceux des tâches
  /// qu'on supprime. Même contrat que `forgetReminders` : synchrone, muet, par IDENTIFIANT — donc
  /// utilisable APRÈS que SwiftData a effacé les objets (cf. sa doc, et le plantage du 6 août 2026).
  func forgetEvents(_ identifiers: [String]) {
    guard eventAuthorizationStatus == .fullAccess, !identifiers.isEmpty else { return }
    for identifier in identifiers {
      lastAgreed.removeValue(forKey: identifier)
      guard let event = store.event(withIdentifier: identifier) else { continue }
      try? store.remove(event, span: .thisEvent, commit: true)
    }
  }

  /// Relit l'état de complétion des rappels liés (Rappels → app). Renvoie `identifiant: isCompleted`
  /// pour ceux qui existent encore. Vide tant que l'accès n'est pas accordé.
  ///
  /// **UNE requête asynchrone, et non un `calendarItem(withIdentifier:)` par tâche.** Ce dernier est
  /// un aller-retour XPC **synchrone** vers le démon Rappels : posé sur le fil principal, il le GÈLE
  /// le temps de la réponse. Mesuré le 6 août 2026 (`sample` sur l'app AU REPOS, personne n'y
  /// touchait) : 43 échantillons de fil principal arrêtés dans
  /// `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` sur une fenêtre de 4 s — soit ~40 %
  /// de tout le travail non-oisif du fil qui dessine. Et le coût est LINÉAIRE en tâches liées,
  /// rejoué à chaque `.EKEventStoreChanged` **et** à chaque `ModelContext.didSave` (cf.
  /// `ContentView.syncWithReminders`), c'est-à-dire après chaque titre validé, chaque case cochée,
  /// chaque dépôt. Le commentaire d'avant pariait « le volume de tâches liées reste petit » : il
  /// l'est, et ça coûtait quand même des images entières.
  ///
  /// `fetchReminders` rend la main tout de suite et rappelle hors du fil principal — même idiome
  /// que `reminders(dueFrom:to:)`, `UncheckedBox` compris et pour la même raison.
  ///
  /// ponytail: le prédicat balaye TOUS les calendriers de rappels, faute de savoir dans lequel vit
  /// chacun des liés. Un aller-retour plus gros si l'utilisateur a des milliers de rappels — mais
  /// hors du fil qui dessine, ce qui est tout le sujet. Le borner le jour où ça se mesure.
  ///
  /// Pendant une passe, l'instantané de `withSyncLock` sert de source : la passe entière ne coûte
  /// alors qu'UN aller-retour, partagé avec `reminderDay(for:)` et `reminderVanished(_:)`.
  func completionStates(for identifiers: [String]) async -> [String: Bool] {
    guard authorizationStatus == .fullAccess, !identifiers.isEmpty else { return [:] }
    // Pas de `??` : son opérande droit est une autoclosure, qui n'accepte pas d'`await`.
    let all: [String: EKReminder]
    if let passSnapshot {
      all = passSnapshot
    } else {
      all = await fetchedSnapshot()
    }
    return identifiers.reduce(into: [:]) { states, id in
      guard let reminder = all[id] else { return }
      states[id] = reminder.isCompleted
    }
  }

  // MARK: L'instantané d'une passe

  /// Tous les rappels du store, relus UNE fois au début d'une passe et interrogés ensuite par
  /// identifiant. `nil` hors passe.
  ///
  /// Il existe parce que trois fonctions posaient chacune un `calendarItem(withIdentifier:)` PAR
  /// tâche, et que cet appel est un aller-retour XPC **synchrone** vers le démon Rappels : sur le
  /// fil principal, il le gèle le temps de la réponse. Mesuré au `sample`, app au repos, personne
  /// n'y touchant : 97 échantillons de fil principal arrêtés dans
  /// `__NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__` sur une fenêtre de 4 s, soit la
  /// moitié de tout le travail non-oisif du fil qui dessine. Et c'est LINÉAIRE en tâches liées,
  /// rejoué à chaque `.EKEventStoreChanged` **et** à chaque `ModelContext.didSave` — donc après
  /// chaque titre validé, chaque case cochée, chaque dépôt.
  ///
  /// `fetchReminders` rend la main tout de suite et rappelle hors du fil principal : le coût
  /// devient une requête par passe, et elle ne bloque plus personne.
  private var passSnapshot: [String: EKReminder]?

  /// Le rappel d'identifiant donné : dans l'instantané si une passe est en cours, sinon relu au
  /// coup par coup. Le repli garde EXACTEMENT le comportement d'avant hors passe — c'est ce qui
  /// permet d'installer l'instantané sans rien changer à ce que voient les appelants.
  private func reminder(_ identifier: String) -> EKReminder? {
    if let passSnapshot { return passSnapshot[identifier] }
    return store.calendarItem(withIdentifier: identifier) as? EKReminder
  }

  private func fetchedSnapshot() async -> [String: EKReminder] {
    guard authorizationStatus == .fullAccess else { return [:] }
    // `predicateForReminders(in:)` ramène les complétés comme les autres — c'est indispensable,
    // `completionStates` n'existe que pour lire des complétions.
    //
    // ponytail: tous les calendriers, faute de savoir dans lequel vit chaque rappel lié. Requête
    // plus grosse pour qui a des milliers de rappels — mais hors du fil qui dessine, ce qui est
    // tout le sujet. La borner le jour où ça se mesure.
    let predicate = store.predicateForReminders(in: nil)
    let fetched = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { reminders in
        continuation.resume(returning: UncheckedBox(reminders ?? []))
      }
    }.value
    return Dictionary(
      fetched.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: Lecture — page « Aujourd'hui » (rappels + événements Apple, affichage seul)

  var eventAuthorizationStatus: EKAuthorizationStatus {
    EKEventStore.authorizationStatus(for: .event)
  }

  /// Demande l'accès au Calendrier. Autorisation séparée de celle des Rappels. Pas de type
  /// d'erreur dédié : rien n'affiche l'échec à l'écran (section informative, silencieuse si
  /// refusée) — le booléen suffit à l'appelant pour savoir s'il peut fetcher.
  @discardableResult
  func requestEventAccess() async -> Bool {
    switch eventAuthorizationStatus {
    case .fullAccess: return true
    case .denied, .restricted, .writeOnly: return false
    case .notDetermined: fallthrough
    @unknown default: return (try? await store.requestFullAccessToEvents()) ?? false
    }
  }

  /// Événements du calendrier compris entre `start` et `end`, triés par heure de début. Vide tant
  /// que l'accès n'est pas accordé — même convention que `writableLists`.
  func events(from start: Date, to end: Date) -> [EKEvent] {
    guard eventAuthorizationStatus == .fullAccess else { return [] }
    let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
    // `EKEvent.startDate` est déclaré `null_unspecified` côté EventKit, donc importé en `Date!` :
    // un événement détaché d'une récurrence ou venu d'un calendrier distant mal formé peut n'en
    // porter aucune, et le déréférencement force au premier tri PLANTE l'app. On l'écarte ICI,
    // à l'unique porte d'entrée des événements : tout ce qui sort d'ici a une date de début, et
    // les vues (groupement par jour, heure affichée) n'ont aucune garde à répéter.
    return store.events(matching: predicate)
      .filter { $0.startDate != nil }
      .sorted { $0.startDate < $1.startDate }
  }

  /// Événements qui touchent `day` — cf. `events(from:to:)`.
  func events(on day: Date) -> [EKEvent] {
    let start = Calendar.current.startOfDay(for: day)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? day
    return events(from: start, to: end)
  }

  /// Rappels dont l'échéance tombe entre `start` et `end` et pas encore complétés — même règle
  /// que la liste intelligente « Aujourd'hui » de l'app Rappels. `fetchReminders` d'EventKit est
  /// à callback, d'où la continuation.
  func reminders(dueFrom start: Date, to end: Date) async -> [EKReminder] {
    try? await requestAccess()
    guard authorizationStatus == .fullAccess else { return [] }
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: start, ending: end, calendars: nil)
    return await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { reminders in
        // `EKReminder` n'est pas Sendable et EventKit répond sur une file à lui. Ce tableau n'est
        // pourtant partagé avec personne : il naît dans ce rappel, traverse la continuation, et
        // n'est plus touché que par l'appelant. Le convoyeur dit exactement ça, et rien de plus.
        continuation.resume(returning: UncheckedBox(reminders ?? []))
      }
    }.value
  }

  /// Rappels dont l'échéance tombe le `day` donné — cf. `reminders(dueFrom:to:)`.
  func reminders(dueOn day: Date) async -> [EKReminder] {
    let start = Calendar.current.startOfDay(for: day)
    let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? day
    return await reminders(dueFrom: start, to: end)
  }

  // MARK: Cache Aujourd'hui / À venir — survit aux démontages de page. `TodayPageView` et
  // `UpcomingPageView` sont recréées à chaque fois que l'onglet redevient la sélection (branches
  // d'un `switch`, cf. `TaskListView`) : sans ce cache, leur `@State` repartait de zéro et la page
  // s'affichait vide le temps du refetch EventKit, à CHAQUE ouverture. Ce service, lui, vit au
  // niveau de l'app (cf. `ThingsCloneApp`) et n'est jamais démonté.
  private(set) var todayEvents: [EKEvent] = []
  private(set) var todayReminders: [EKReminder] = []
  private(set) var upcomingEvents: [EKEvent] = []
  private(set) var upcomingReminders: [EKReminder] = []

  func refreshToday(now: Date) async {
    todayReminders = await reminders(dueOn: now)
    if await requestEventAccess() {
      todayEvents = events(on: now)
    }
  }

  func refreshUpcoming(from start: Date, to end: Date) async {
    upcomingReminders = await reminders(dueFrom: start, to: end)
    if await requestEventAccess() {
      upcomingEvents = events(from: start, to: end)
    }
  }

  /// Retrait optimiste immédiat (cf. `TodayPageView`/`UpcomingPageView.completeReminder`) : on ne
  /// montre jamais un rappel déjà coché, pas d'attendre le prochain refresh pour le faire sortir.
  func removeTodayReminder(_ identifier: String) {
    todayReminders.removeAll { $0.calendarItemIdentifier == identifier }
  }

  func removeUpcomingReminder(_ identifier: String) {
    upcomingReminders.removeAll { $0.calendarItemIdentifier == identifier }
  }

  /// Pousse la complétion d'une tâche vers son rappel (app → Rappels), en miroir du retour
  /// `completionStates`. No-op si la tâche n'est pas liée ou si l'accès n'est pas accordé.
  /// Silencieux : cocher une tâche ne doit jamais lever d'alerte. Sans ce push, le retour
  /// Rappels → app relit un rappel resté coché et ré-écrase le décochage local.
  func pushCompletion(for task: TaskItem) async {
    guard let id = task.reminderIdentifier, authorizationStatus == .fullAccess else { return }
    try? await setCompleted(task.isCompleted, identifier: id)
  }

  // MARK: Pont continu avec l'app Rappels — les FAITS dont la synchro a besoin
  // (la décision, elle, est dans `RemindersSync` ; l'orchestration dans `ContentView`).

  /// La liste-pont réglée par l'utilisateur, si elle existe ENCORE : une liste supprimée côté
  /// Rappels laisse derrière elle un identifiant qui ne pointe plus sur rien, et rien ne prévient.
  func list(withIdentifier identifier: String?) -> EKCalendar? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return writableLists.first { $0.calendarIdentifier == identifier }
  }

  /// Jour d'échéance du rappel lié — `nil` s'il a disparu, n'a pas d'échéance, ou si l'accès n'est
  /// pas accordé. C'est la seule chose que `RemindersSync.needsPush` a besoin de savoir du rappel.
  func reminderDay(for identifier: String) -> Date? {
    guard authorizationStatus == .fullAccess, let reminder = reminder(identifier)
    else { return nil }
    return reminder.dueDateComponents.flatMap(Calendar.current.date(from:))
  }

  /// Le rappel lié a-t-il été SUPPRIMÉ côté Apple ? La seule question dont la réponse autorise à
  /// effacer une tâche (cf. `RemindersSync.shouldDelete`), et elle demande donc des preuves.
  ///
  /// **Absent ne veut pas dire supprimé.** Le 5 août 2026, la version qui répondait simplement
  /// « EventKit ne le trouve pas » a effacé trois tâches d'une base fraîchement restaurée, en
  /// quelques minutes et sans un mot. Leurs identifiants pointaient des rappels nettoyés depuis
  /// longtemps — un fait sur l'HISTOIRE du rappel, jamais un geste de l'utilisateur. Toute
  /// sauvegarde restaurée porte des identifiants périmés : supprimer là-dessus, c'est punir la
  /// restauration au moment précis où l'on en avait besoin.
  ///
  /// Deux preuves exigées, et chacune écarte un faux positif distinct :
  /// 1. **vu vivant pendant CETTE session** — sinon on ne sait rien de ce rappel, on sait seulement
  ///    qu'il n'est pas là. C'est le cas de la base restaurée, et celui d'un accès accordé après
  ///    coup ;
  /// 2. **absent DEUX passes de suite** — un compte iCloud qui se resynchronise fait disparaître
  ///    puis revenir des éléments, et `.EKEventStoreChanged` sonne précisément pendant ces
  ///    remaniements. Une absence isolée ne tranche rien.
  ///
  /// Sans accès, la réponse est toujours `false` : un accès révoqué ferait sinon passer TOUTES les
  /// tâches liées pour supprimées d'un coup.
  ///
  /// Distinct de `reminderDay(for:)`, qui rend déjà `nil` pour un rappel SANS échéance : « pas
  /// d'échéance » et « plus de rappel » appellent des réponses opposées (réécrire vs supprimer).
  func reminderVanished(_ identifier: String) -> Bool {
    guard authorizationStatus == .fullAccess else { return false }
    guard reminder(identifier) == nil else {
      seenAlive.insert(identifier)
      missedOnce.remove(identifier)
      return false
    }
    guard seenAlive.contains(identifier) else { return false }
    guard missedOnce.contains(identifier) else {
      missedOnce.insert(identifier)
      return false
    }
    // Verdict rendu : on oublie ce rappel. Sans ça, son identifiant resterait dans `missedOnce`
    // pour toujours — or c'est lui qui dit « une passe de plus est attendue » (cf.
    // `hasPendingVanishVerdict`), et la synchro se rearmerait indéfiniment pour un dossier clos.
    missedOnce.remove(identifier)
    seenAlive.remove(identifier)
    lastAgreed.removeValue(forKey: identifier)
    return true
  }

  /// Ce rappel a-t-il été vu VIVANT pendant cette session ? La seule chose qui distingue un
  /// identifiant périmé (base restaurée — à repousser) d'un rappel que l'utilisateur vient de
  /// supprimer (à laisser mort, cf. `RemindersSync.needsPush`).
  func reminderWasSeenAlive(_ identifier: String) -> Bool { seenAlive.contains(identifier) }

  /// Une absence attend sa confirmation : il manque UNE passe pour trancher. L'appelant s'en sert
  /// pour en repasser une (cf. `ContentView.syncWithReminders`) — sans quoi la tâche resterait en
  /// sursis jusqu'à ce qu'un autre événement réveille la synchro, c'est-à-dire peut-être jamais.
  var hasPendingVanishVerdict: Bool { !missedOnce.isEmpty }

  /// Les rappels vus VIVANTS depuis le lancement, et ceux qui ont manqué à l'appel une fois.
  /// En mémoire seulement, et c'est voulu : la question posée est « l'utilisateur vient-il de le
  /// supprimer ? », qui n'a de sens que dans une session. Les persister rendrait au redémarrage le
  /// jugement hâtif qu'on vient justement de retirer.
  private var seenAlive: Set<String> = []
  private var missedOnce: Set<String> = []

  /// Efface les rappels de tâches qu'on supprime — la suppression dans le sens app → Rappels.
  ///
  /// Sans elle, la tâche part mais son rappel RESTE dans la liste-pont, et il n'est alors plus
  /// rattaché à personne : les sections « Rappels » d'« Aujourd'hui » et d'« À venir », qui ne
  /// montrent QUE les rappels non liés, se mettent à l'afficher — supprimer une tâche donnait
  /// l'impression de la faire « passer dans Rappels ». Et si l'import est actif, la passe suivante
  /// la recrée en tâche, dans la boîte de réception cette fois.
  ///
  /// Synchrone et sans demande d'accès (comme `reminderDay(for:)`) : supprimer une tâche ne doit
  /// ni ouvrir une boîte d'autorisation, ni faire attendre l'animation de la ligne.
  ///
  /// Vaut aussi bien pour UNE tâche que pour une suppression EN CASCADE — une liste ou un projet
  /// emporte ses tâches.
  ///
  /// Ce second cas était laissé de côté (le service ne vit pas dans `Models/`, où la cascade est
  /// écrite), et la conséquence se voyait : les rappels des tâches emportées restaient dans la
  /// liste-pont,
  /// rattachés à plus personne. Les sections « Rappels » d'« Aujourd'hui » et d'« À venir », qui ne
  /// montrent QUE les rappels non liés, se mettaient donc à les afficher — supprimer un projet
  /// donnait l'impression d'y avoir envoyé ses tâches. Et avec l'import actif, la passe suivante
  /// les recréait en tâches, dans la boîte de réception cette fois.
  ///
  /// C'est l'appelant qui la fournit à `TodoList.delete(from:in:forget:)`, sans valeur par défaut :
  /// l'omission ne doit pas compiler (même règle que `TaskPageBase.reorder` et `newTask`).
  /// Efface des rappels par IDENTIFIANT, sans jamais toucher à un `@Model`.
  ///
  /// C'est ce qui la rend utilisable APRÈS une suppression en cascade, quand les tâches n'existent
  /// plus : une chaîne de caractères survit à ce que SwiftData efface, un objet non.
  ///
  /// **Et il FAUT que ce soit après.** Le 6 août 2026, effacer les rappels au milieu de la
  /// suppression d'un projet faisait planter l'app à tous les coups, dans SwiftData, sur le
  /// `save()` de la cascade. La chaîne : `store.remove` écrit dans EventKit → EventKit poste
  /// `.EKEventStoreChanged` → `ContentView` relance sa synchro → celle-ci relit et RÉENREGISTRE le
  /// même contexte SwiftData, en plein milieu de la cascade qu'on était en train d'écrire. Deux
  /// écritures imbriquées sur le même contexte, et l'assertion tombe.
  ///
  /// Sortir EventKit de la fenêtre de mutation supprime la classe entière de problème : quand ces
  /// lignes s'exécutent, SwiftData a fini et enregistré.
  func forgetReminders(_ identifiers: [String]) {
    guard authorizationStatus == .fullAccess, !identifiers.isEmpty else { return }
    for identifier in identifiers {
      lastAgreed.removeValue(forKey: identifier)
      guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
        continue
      }
      try? store.remove(reminder, commit: true)
    }
  }

  /// Les identifiants Apple de ces tâches — rappels ET événements — à lire AVANT de les supprimer,
  /// et à passer ensuite à `forgetAppleItems(_:)`. Les deux dans une seule liste : les chemins de
  /// suppression n'ont pas à savoir lequel des deux champs était rempli.
  nonisolated static func appleIdentifiers(of tasks: [TaskItem]) -> [String] {
    tasks.compactMap(\.reminderIdentifier) + tasks.compactMap(\.eventIdentifier)
  }

  /// Efface ce qu'une tâche supprimée laisse derrière elle, quelle que soit sa forme côté Apple.
  /// Chacune des deux passes ignore ce qui n'est pas de son type : les identifiants de rappel et
  /// d'événement ne vivent pas dans le même espace de noms, aucun ne peut être pris pour l'autre.
  func forgetAppleItems(_ identifiers: [String]) {
    forgetReminders(identifiers)
    forgetEvents(identifiers)
  }

  /// Rappels non complétés et DATÉS de `list`, titre non vide — la source de l'import.
  ///
  /// `predicateForIncompleteReminders` accepte une fenêtre ouverte des deux côtés, et ramène alors
  /// aussi les rappels SANS échéance : on les écarte, l'import étant le miroir du push, qui
  /// n'envoie que des tâches datées. Le titre est écarté ICI et pas chez l'appelant : `title` est
  /// `null_unspecified` côté EventKit (donc importé en `String!`), et tout ce qui sort de cette
  /// porte en a un — la vue n'a aucune garde à répéter.
  func datedReminders(in list: EKCalendar) async -> [EKReminder] {
    guard authorizationStatus == .fullAccess else { return [] }
    let predicate = store.predicateForIncompleteReminders(
      withDueDateStarting: nil, ending: nil, calendars: [list])
    let fetched = await withCheckedContinuation { continuation in
      store.fetchReminders(matching: predicate) { reminders in
        continuation.resume(returning: UncheckedBox(reminders ?? []))
      }
    }.value
    return fetched.filter {
      $0.dueDateComponents != nil && !(($0.title as String?) ?? "").isEmpty
    }
  }

  /// Exécute une passe de synchro, et une seule à la fois.
  ///
  /// Deux raisons, pas une : `.EKEventStoreChanged` sonne à CHACUNE de nos propres écritures (donc
  /// une passe qui écrit se rappelle elle-même), et chaque fenêtre ouverte a son `ContentView` qui
  /// l'écoute. Sans ce verrou, deux passes concurrentes importeraient le même rappel deux fois —
  /// chacune l'a lu avant que l'autre n'ait inséré sa tâche. Ce service vit au niveau de l'app, le
  /// verrou couvre donc bien toutes les fenêtres ; un `@State` de vue n'en aurait couvert qu'une.
  /// Rend `false` quand une passe tournait déjà et que `body` n'a donc PAS été exécuté — à charge
  /// de l'appelant de repasser plus tard. Sans ce retour, un changement extérieur tombé au milieu
  /// d'une passe disparaissait sans un mot (cf. `ContentView.syncWithReminders`, qui se rearme).
  /// C'est aussi ici que se prend l'instantané des rappels (cf. `passSnapshot`) : la passe est
  /// justement le bloc pendant lequel il est valable, et le seul endroit où toutes les lectures
  /// tombent. Pris AVANT `body`, rendu après, quoi qu'il arrive.
  ///
  /// **Un instantané VIDE ne s'installe pas.** Un fetch qui revient vide pour une raison passagère
  /// (démon Rappels qui redémarre, compte iCloud qui se resynchronise) ferait passer TOUS les
  /// rappels liés pour introuvables d'un coup, et c'est précisément l'entrée de
  /// `reminderVanished(_:)` — la fonction qui a effacé trois tâches le 5 août 2026. Ses deux
  /// preuves encaissent une absence isolée, mais une requête groupée rate pour tout le monde en
  /// même temps là où les lectures une par une échouaient chacune de leur côté. Vide, on retombe
  /// donc sur la lecture au coup par coup, c'est-à-dire sur le comportement d'avant, exactement.
  @discardableResult
  func withSyncLock(_ body: () async -> Void) async -> Bool {
    guard !isSyncing else { return false }
    isSyncing = true
    let snapshot = await fetchedSnapshot()
    passSnapshot = snapshot.isEmpty ? nil : snapshot
    await body()
    passSnapshot = nil
    isSyncing = false
    return true
  }

  private var isSyncing = false

  /// Reporte l'état de complétion de la tâche sur le rappel associé (app → Rappels).
  /// Sans effet si aucun rappel n'existe encore, ou s'il a été supprimé côté Rappels.
  func setCompleted(_ completed: Bool, identifier: String) async throws {
    try await requestAccess()

    guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
      return
    }

    reminder.isCompleted = completed  // met aussi à jour completionDate automatiquement

    do {
      try store.save(reminder, commit: true)
    } catch {
      throw RemindersError.saveFailed(underlying: error)
    }
  }
}

/// Fait traverser une frontière de concurrence à une valeur non-`Sendable` dont on sait qu'elle
/// n'est partagée avec personne.
///
/// Réservé aux objets EventKit : ils ne sont pas `Sendable` (ce sont des classes mutables), mais
/// ceux qui passent par ici naissent dans un rappel d'EventKit et ne sont lus qu'après, par un seul
/// appelant. C'est une affirmation du programmeur — d'où le nom explicite plutôt qu'un
/// `@unchecked Sendable` posé sur un type du domaine, qui l'aurait rendue invisible.
struct UncheckedBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
