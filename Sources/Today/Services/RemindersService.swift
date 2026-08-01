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

  /// Relit l'état de complétion des rappels liés (Rappels → app). Renvoie `identifiant: isCompleted`
  /// pour ceux qui existent encore. Vide tant que l'accès n'est pas accordé. Synchrone : le volume
  /// de tâches liées reste petit, et `calendarItem(withIdentifier:)` réinterroge le store.
  func completionStates(for identifiers: [String]) -> [String: Bool] {
    guard authorizationStatus == .fullAccess else { return [:] }
    var states: [String: Bool] = [:]
    for id in identifiers {
      if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
        states[id] = reminder.isCompleted
      }
    }
    return states
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
        continuation.resume(returning: reminders ?? [])
      }
    }
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
