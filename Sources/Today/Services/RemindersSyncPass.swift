import EventKit
import Foundation
import SwiftData

/// La synchro avec Rappels et Calendrier, sortie de `ContentView`.
///
/// Elle y vivait — orchestration, ses cinq réglages, sa passe en attente, quatre cents lignes —
/// parce que c'était là que tombaient les deux notifications qui la réveillent. Une vue racine qui
/// porte un service, c'est une vue dont chaque `@AppStorage` abonne TOUTE la fenêtre, et un service
/// qu'aucun test ne peut instancier. La vue ne garde que les déclencheurs (`.EKEventStoreChanged`,
/// `ModelContext.didSave`, retour au premier plan) et appelle `schedule()`.
///
/// Le code des passes est repris tel quel : mêmes règles, même ordre, même verrou.
@MainActor
final class RemindersSyncPass {
  private let service: RemindersService
  private let context: ModelContext
  /// La passe EN ATTENTE — annulée et rearmée à chaque réveil. C'est ce qui empêche l'app de se
  /// réveiller pour son propre bruit (cf. `schedule`).
  private var pending: Task<Void, Never>?

  init(service: RemindersService, context: ModelContext) {
    self.service = service
    self.context = context
  }

  func cancel() { pending?.cancel() }

  /// Les réglages du pont (*Réglages ▸ Tâches*, cf. `RemindersSyncSection`), relus à CHAQUE passe :
  /// un réglage changé entre deux passes vaut dès la suivante, sans abonner personne.
  private struct Settings {
    let defaults = UserDefaults.standard
    var push: Bool { defaults.bool(forKey: RemindersSync.pushStorageKey) }
    var importing: Bool { defaults.bool(forKey: RemindersSync.importStorageKey) }
    var listID: String { defaults.string(forKey: RemindersSync.listStorageKey) ?? "" }
    var eventCalendarID: String {
      defaults.string(forKey: RemindersSync.eventCalendarStorageKey) ?? ""
    }
    var dueHour: Int {
      defaults.object(forKey: RemindersSync.dueHourStorageKey) as? Int ?? RemindersSync.dueHour
    }
  }

  /// Le point de synchro avec l'app Rappels, et le SEUL : les deux sens partent d'ici, réveillés
  /// par `.EKEventStoreChanged` et par le retour au premier plan (cf. `ContentView`).
  ///
  /// Les complétions passent toujours ; les deux autres passes sont des réglages, et demandent une
  /// liste-pont désignée — sans elle il n'y a ni destination pour le push, ni source bornée pour
  /// l'import (cf. `RemindersSync.listStorageKey`).
  ///
  /// Import AVANT push, et ce n'est pas indifférent : une tâche qui vient d'être importée porte
  /// déjà le jour de son rappel, la passe de push la trouve donc à jour et ne la réécrit pas. Dans
  /// l'autre ordre le résultat serait le même — c'est `RemindersSync.needsPush` qui garantit
  /// l'arrêt, pas l'ordre — mais l'enchaînement se lit dans le sens où il converge.
  ///
  /// **Temporisé d'une seconde, et TOUT est sous le verrou.** `.EKEventStoreChanged` sonne à chacune
  /// de NOS propres écritures : une passe qui pousse dix rappels poste dix notifications, et le fil
  /// principal les livre PENDANT la passe (chaque `await` lui rend la main). Le verrou écartait bien
  /// les passes complètes, mais `syncCompletionsFromReminders()` tournait en dehors — donc dix fois
  /// de plus, chacune posant un `calendarItem(withIdentifier:)` synchrone par tâche liée. Le coût
  /// était le carré du nombre de tâches, sur le fil qui dessine.
  ///
  /// La temporisation résout les deux d'un coup : le bruit qu'on fait soi-même retombe avant que la
  /// passe suivante ne parte, et une rafale de notifications n'en déclenche qu'une.
  ///
  /// Si le verrou est PRIS quand la passe se réveille, elle se rearme au lieu d'abandonner : sans
  /// ça, un vrai changement extérieur arrivé pendant une passe serait perdu jusqu'au prochain retour
  /// au premier plan.
  func schedule() {
    pending?.cancel()
    pending = Task {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      let settings = Settings()
      let ran = await service.withSyncLock {
        await syncCompletionsFromReminders()
        // Les événements ne dépendent QUE du calendrier désigné — ni de la liste-pont, ni de la
        // bascule des rappels. Ils en dépendaient, et c'était un piège : poser une durée ne
        // produisait rien tant que TROIS réglages n'étaient pas justes, sans que rien ne le dise.
        // Un réglage qui peut s'oublier en silence est un bug en attente : il n'en reste qu'un,
        // et le menu « Durée… » va le chercher quand il manque.
        let eventCalendar = service.eventCalendar(withIdentifier: settings.eventCalendarID)
        if let eventCalendar { await pushTimedTasks(to: eventCalendar) }
        guard settings.push || settings.importing,
          let list = service.list(withIdentifier: settings.listID)
        else { return }
        deleteTasksWhoseReminderIsGone()
        if settings.importing { await importReminders(from: list) }
        if settings.push { await pushDatedTasks(to: list, eventCalendar: eventCalendar) }
      }
      guard !Task.isCancelled else { return }
      // Deux raisons d'en repasser une : le verrou nous a refusé l'entrée, ou une absence attend sa
      // confirmation. La seconde est ce qui rend la suppression depuis Rappels effective en ~2 s au
      // lieu de « au prochain événement, peut-être ». Les deux convergent : `hasPendingVanishVerdict`
      // retombe dès que le verdict tombe, dans un sens comme dans l'autre.
      if !ran || service.hasPendingVanishVerdict
        || service.hasPendingEventVanishVerdict
      {
        schedule()
      }
    }
  }

  /// Rappels → app : une tâche dont le rappel a été SUPPRIMÉ côté Apple est supprimée ici aussi.
  ///
  /// Sans elle, le push la voyait « sans rappel » — exactement le même fait qu'une tâche jamais
  /// poussée (cf. `RemindersSync.needsPush`, qui traite `nil` comme « (re)créer ») — et la recréait
  /// dans la seconde. Supprimer un rappel n'avait donc aucun effet visible : il repoussait aussitôt.
  ///
  /// AVANT le push, sans quoi la passe suivante recréerait le rappel de la tâche qu'on s'apprête à
  /// effacer. Le périmètre exact, lui, est dans `RemindersSync.shouldDelete`.
  ///
  /// **C'est le seul endroit de l'app qui détruit des données sans que l'utilisateur l'ait
  /// demandé**, et il l'a fait pour de vrai : le 5 août 2026, trois tâches d'une base fraîchement
  /// restaurée sont parties en quelques minutes, parce que « EventKit ne trouve pas ce rappel »
  /// suffisait alors à conclure « l'utilisateur l'a supprimé ». Le niveau de preuve exigé est
  /// désormais dans `RemindersService.reminderVanished(_:)` : vu vivant pendant CETTE session, puis
  /// absent deux passes de suite. Tout le reste ne supprime rien.
  ///
  /// Les gardes d'ensemble tiennent toujours, en amont : sans accès accordé `reminderVanished`
  /// répond `false` pour tout le monde, et l'appelant a déjà exigé que la liste-pont se RÉSOLVE
  /// encore — un compte iCloud momentanément absent la fait disparaître de `writableLists`, et la
  /// synchro s'arrête avant d'arriver ici.
  /// **`deleteCascadeAndSave` et pas `delete` + `save`, alors qu'on ne supprime qu'une tâche.**
  /// C'est le seul endroit de l'app qui supprime HORS du chemin de l'affichage : la tâche vient
  /// d'un fetch, personne n'a rendu sa ligne, et surtout personne n'a lu ses SOUS-TÂCHES. Or c'est
  /// leur instantané qui manque à SwiftData quand l'`UndoManager` est branché — mesuré le 6 août
  /// 2026, `CascadeDeleteTests` le garde. Une tâche à sous-tâches dont le rappel disparaissait
  /// faisait donc tomber le processus, sans que rien dans le code ne le laisse voir.
  ///
  /// Perdre ⌘Z ici ne coûte rien : annuler « un rappel a été supprimé dans une autre app » ne veut
  /// rien dire, et la tâche reviendrait pour repartir à la passe suivante.
  private func deleteTasksWhoseReminderIsGone() {
    for task in linkedTasks() {
      // `reminderVanished` est appelé pour CHAQUE tâche liée, y compris celles qu'on ne supprimera
      // pas : c'est lui qui tient la mémoire « vu vivant », et elle ne vaut que si on la nourrit.
      guard let identifier = task.reminderIdentifier,
        RemindersSync.shouldDelete(task, vanished: service.reminderVanished(identifier))
      else { continue }
      context.deleteCascadeAndSave(task)
    }
  }

  /// Rappels → app : chaque rappel daté de la liste-pont qui n'est rattaché à aucune tâche en
  /// devient une, dans « Tâches » (l'Inbox). C'est `reminderIdentifier` qui l'empêche de revenir à
  /// la passe suivante — et accessoirement qui le fait disparaître des sections « Rappels »
  /// d'« Aujourd'hui » et d'« À venir », qui n'y montrent que les rappels NON liés.
  ///
  /// ponytail: une tâche importée puis supprimée dans l'app revient à la synchro suivante, tant
  /// que son rappel existe côté Apple. Supprimer des deux côtés est la marche à suivre ; retenir
  /// les identifiants effacés demanderait un champ de plus au schéma, donc une montée de version.
  private func importReminders(from list: EKCalendar) async {
    let reminders = await service.datedReminders(in: list)
    guard !reminders.isEmpty else { return }

    let linked = Set(linkedTasks().compactMap(\.reminderIdentifier))
    let inbox =
      (try? context.fetch(
        FetchDescriptor<TodoList>(predicate: #Predicate { $0.isInbox })))?.first
    // Calculé une fois puis incrémenté : `inbox.tasks` ne verra les insertions qu'après
    // enregistrement, le relire par tour donnerait le même rang à tout le lot.
    var nextIndex = (inbox?.tasks.map(\.sortIndex).max() ?? -1) + 1

    var changed = false
    for reminder in reminders where !linked.contains(reminder.calendarItemIdentifier) {
      guard let due = reminder.dueDateComponents.flatMap(Calendar.current.date(from:))
      else { continue }
      // Le jour dans `when`, l'heure dans `whenMinutes` — jamais mêlés (cf. `TaskItem.when`).
      // L'heure du rappel arrive donc DANS la tâche depuis la 5.0.0 : l'aller-retour ne perd plus
      // rien, et la passe de push la retrouve identique, donc ne réécrit pas. Même geste que le
      // retour d'une échéance modifiée dans Rappels — c'est le même fait, à sa première passe.
      let task = TaskItem(title: reminder.title, when: nil, list: inbox)
      RemindersSync.adopt(due, minutes: nil, on: task)
      task.reminderIdentifier = reminder.calendarItemIdentifier
      task.sortIndex = nextIndex
      nextIndex += 1
      context.insert(task)
      changed = true
    }
    if changed { try? context.save() }
  }

  /// App → Rappels : toute tâche datée qui n'a pas encore son rappel, ou dont le rappel porte un
  /// AUTRE jour, est (ré)écrite dans la liste-pont.
  ///
  /// La liste n'est imposée qu'à la création. Un rappel déjà existant garde la sienne : sans ça,
  /// un rappel créé à la main depuis une tâche (cf. `SchedulePlannerView`, qui laisse choisir sa
  /// destination) se ferait déménager dans la liste-pont au premier changement de date.
  ///
  /// Les tâches à DURÉE, elles, partent en événements et sont écartées d'ici — c'est
  /// `RemindersSync.destination` qui tranche, et l'exclusivité entre les deux tient à ce qu'un seul
  /// endroit la prononce. Leur écriture, elle, a déjà eu lieu (cf. `pushTimedTasks`, appelé en
  /// amont) : `eventCalendar` ne sert ici qu'à savoir QUI ne doit pas partir en rappel.
  private func pushDatedTasks(to list: EKCalendar, eventCalendar: EKCalendar?) async {
    let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.when != nil })
    guard let dated = try? context.fetch(descriptor) else { return }

    var changed = false
    for task in dated {
      guard
        RemindersSync.destination(for: task, eventCalendarChosen: eventCalendar != nil) == .reminder
      else { continue }
      let reminderDue = task.reminderIdentifier.flatMap(service.reminderDay(for:))
      let seenAlive =
        task.reminderIdentifier.map(service.reminderWasSeenAlive) ?? false
      switch RemindersSync.reminderVerdict(
        task, due: reminderDue,
        lastSeen: task.reminderIdentifier.flatMap(service.lastSeenReminderDue),
        wasSeenAlive: seenAlive)
      {
      case .agreed:
        // L'accord se MÉMORISE, et c'est tout l'objet du troisième terme : sans cette ligne, la
        // prochaine modification faite dans Rappels serait indiscernable d'une modification faite
        // ici, et l'app la réécraserait comme avant.
        if let id = task.reminderIdentifier {
          service.rememberReminderDue(id, reminderDue)
        }
      case .pull:
        // Rappels → app : l'échéance changée là-bas devient le jour (et l'heure) de la tâche.
        guard let id = task.reminderIdentifier, let reminderDue else { continue }
        RemindersSync.adopt(reminderDue, minutes: nil, on: task)
        service.rememberReminderDue(id, reminderDue)
        changed = true
      case .push:
        guard let when = task.when else { continue }
        let due = RemindersSync.due(for: when, minutes: task.whenMinutes, hour: Settings().dueHour)
        // Capturé AVANT l'`await` : la frappe continue pendant l'écriture, et mémoriser un autre
        // titre que celui écrit ferait lire l'écart comme un renommage dans Rappels — la passe
        // suivante reprendrait alors le titre tronqué SUR la tâche.
        let title = task.title
        guard
          let id = try? await service.schedule(
            title: title,
            start: when,
            due: due,
            list: task.reminderIdentifier == nil ? list : nil,
            existingIdentifier: task.reminderIdentifier)
        else { continue }
        task.reminderIdentifier = id
        // Ce qu'on vient d'écrire EST le nouvel accord. L'oublier ferait lire l'écriture suivante
        // comme un changement venu de Rappels.
        service.rememberReminderDue(id, due)
        service.rememberReminderTitle(id, title)
        changed = true
        continue
      }
      if syncTitle(of: task) { changed = true }
    }
    if changed { try? context.save() }
  }

  /// Le titre, tranché À PART de l'échéance (cf. `RemindersSync.titleVerdict`) — c'est ce qui
  /// rend son titre complet à un rappel parti en pleine frappe. Rend `true` si la TÂCHE a changé.
  private func syncTitle(of task: TaskItem) -> Bool {
    guard let id = task.reminderIdentifier,
      let apple = service.reminderTitle(for: id)
    else { return false }
    switch RemindersSync.titleVerdict(
      task: task.title, apple: apple, lastSeen: service.lastSeenReminderTitle(id))
    {
    case .agreed:
      service.rememberReminderTitle(id, apple)
      return false
    case .pull:
      task.title = apple
      service.rememberReminderTitle(id, apple)
      return true
    case .push:
      let title = task.title
      service.renameReminder(id, to: title)
      service.rememberReminderTitle(id, title)
      return false
    }
  }

  /// App → Calendrier : une tâche datée QUI PORTE UNE DURÉE prend sa place dans l'agenda.
  ///
  /// C'est la différence de nature entre les deux objets d'Apple, et elle vient de la durée : un
  /// rappel a une échéance et sonne, un événement occupe un créneau. Donner une durée à une tâche,
  /// c'est dire « ça me prendra ce temps-là » — donc réserver, pas être prévenu.
  ///
  /// Quatre gestes, dans cet ordre, et l'ordre compte :
  /// 1. effacer les événements qui n'ont plus lieu d'être (durée retirée, date retirée) ;
  /// 2. relire l'état des événements liés, en UNE requête ;
  /// 3. retirer la durée des tâches dont l'événement a été SUPPRIMÉ dans le Calendrier — et ne rien
  ///    réécrire tant qu'une absence n'est pas confirmée, sous peine d'effacer sa propre preuve ;
  /// 4. (ré)écrire les autres, et effacer le rappel qu'elles avaient AVANT de devenir des
  ///    événements — sinon la même tâche existe des deux côtés, sonne dans Rappels et occupe un
  ///    créneau dans Calendrier.
  ///
  /// EventKit n'écrit qu'APRÈS l'enregistrement SwiftData pour les SUPPRESSIONS : effacer un
  /// élément fait poster `.EKEventStoreChanged`, qui relance cette passe, qui réenregistre ce même
  /// contexte — au milieu de la mutation qu'on écrit (cf. `ModelContext.deleteTasksAndSave`).
  private func pushTimedTasks(to calendar: EKCalendar) async {
    let descriptor = FetchDescriptor<TaskItem>(
      predicate: #Predicate<TaskItem> { $0.when != nil || $0.eventIdentifier != nil })
    guard let candidates = try? context.fetch(descriptor) else { return }

    var changed = false

    // 1. Retirer la durée (ou la date) DÉFAIT ce que la poser avait fait : l'événement s'en va.
    let stale = candidates.filter(RemindersSync.shouldForgetEvent)
    let doomedEvents = stale.compactMap(\.eventIdentifier)
    for task in stale {
      task.eventIdentifier = nil
      changed = true
    }

    // 2. Ce qui doit exister dans l'agenda, et à quelle heure. L'état actuel des événements liés
    // est relu en UNE requête, bornée aux jours concernés (cf. `linkedEventTimes`).
    let due = candidates.filter {
      RemindersSync.destination(for: $0, eventCalendarChosen: true) == .event
    }
    // Bornes prises sur les tâches DÉJÀ liées à un événement, pas sur toutes les tâches dues :
    // ce sont les seules que `times` peut retrouver. Une tâche datée dans un an sans événement
    // étirait la requête EventKit sur un an — un aller-retour d'autant plus long, à chaque passe
    // (hors du fil qui dessine désormais, mais la passe l'attend).
    let days = due.filter { $0.eventIdentifier != nil }.compactMap(\.when)
    var times: [String: DateInterval] = [:]
    if !days.isEmpty {
      times = await service.linkedEventTimes(
        Set(due.compactMap(\.eventIdentifier)),
        from: Calendar.current.startOfDay(for: days.min() ?? Date()),
        to: Calendar.current.date(
          byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: days.max() ?? Date()))
          ?? Date(),
        in: calendar)
    }

    var doomedReminders: [String] = []
    for task in due {
      // Le créneau que porte l'événement lié EN CE MOMENT. La requête bornée l'a presque toujours ;
      // le repli à l'unité ne sert qu'à un événement déplacé de plus de deux jours — sans lui,
      // « absent de la fenêtre » se lisait « pas d'événement », donc « réécrire », et le geste
      // était défait (cf. `RemindersService.eventTime`).
      let interval = task.eventIdentifier.flatMap { times[$0] ?? service.eventTime($0) }

      // 3. L'événement a-t-il été SUPPRIMÉ dans le Calendrier ? La question se pose avant tout le
      // reste, parce que ses deux autres réponses interdisent d'écrire quoi que ce soit.
      switch task.eventIdentifier.map({
        service.eventPresence($0, foundInWindow: interval != nil)
      }) {
      case .vanished:
        // Le miroir du geste inverse : l'événement effacé, la durée tombe et la tâche redevient un
        // rappel à la passe suivante. La règle et son niveau de preuve sont dans
        // `RemindersSync.shouldDropDuration`.
        if RemindersSync.shouldDropDuration(task, vanished: true) {
          task.estimateMinutes = 0
          task.eventIdentifier = nil
          changed = true
        }
        continue
      case .missingOnce:
        // Une absence non confirmée : on ne réécrit RIEN. Réécrire recréerait l'événement, donc
        // effacerait la preuve qu'attend la passe suivante — et la suppression n'aurait jamais
        // d'effet visible (c'est très exactement ce qui empêchait la suppression d'un rappel de
        // marcher, cf. `RemindersSync.needsPush`).
        continue
      case .alive, .unknownIdentifier, nil:
        break
      }

      // 4. Elle n'est plus un rappel : celui qu'elle avait n'a plus personne derrière lui. AVANT le
      // test de mise à jour, et pas après : un rappel posé à la main (cf. `SchedulePlannerView`)
      // sur une tâche dont l'événement est déjà à jour survivrait à toutes les passes suivantes.
      if let reminder = task.reminderIdentifier {
        doomedReminders.append(reminder)
        task.reminderIdentifier = nil
        changed = true
      }

      // 5. Qui fait foi ? Comparer la tâche et son créneau ne suffit pas à le dire — c'est la
      // mémoire du dernier accord qui tranche (cf. `RemindersSync.Verdict`).
      switch RemindersSync.eventVerdict(
        task, event: interval,
        lastSeen: task.eventIdentifier.flatMap(service.lastSeenEvent))
      {
      case .agreed:
        if let id = task.eventIdentifier { service.rememberEvent(id, interval) }
        continue
      case .pull:
        // Calendrier → app : le créneau déplacé ou rallongé à la main donne à la tâche son jour,
        // son heure et sa durée. C'est le sens qui manquait : l'app imposait, elle synchronise.
        guard let id = task.eventIdentifier, let interval else { continue }
        RemindersSync.adopt(interval.start, minutes: Int(interval.duration / 60), on: task)
        service.rememberEvent(id, interval)
        changed = true
        continue
      case .push:
        break
      }

      guard let when = task.when else { continue }
      let start = RemindersSync.due(for: when, minutes: task.whenMinutes, hour: Settings().dueHour)
      // Le calendrier désigné est passé à TOUS les coups : c'est `scheduleEvent` qui sait si
      // l'événement existe encore et garde alors le sien (déplacé à la main, il y reste).
      guard
        let id = await service.scheduleEvent(
          title: task.title,
          start: start,
          minutes: task.estimateMinutes,
          calendar: calendar,
          existingIdentifier: task.eventIdentifier)
      else { continue }
      // Ce qu'on vient d'écrire EST le nouvel accord (cf. la branche `.agreed`).
      service.rememberEvent(
        id, DateInterval(start: start, duration: TimeInterval(task.estimateMinutes) * 60))
      if task.eventIdentifier != id {
        task.eventIdentifier = id
        changed = true
      }
    }

    if changed { try? context.save() }
    service.forgetEvents(doomedEvents)
    service.forgetReminders(doomedReminders)
  }

  /// Recopie la complétion des rappels liés sur leurs tâches (Rappels → app).
  ///
  /// Fetch à la demande et PAS un `@Query` : quand ce code vivait dans la vue racine, un `@Query`
  /// y aurait fait dépendre TOUT l'arbre (sidebar comprise) de la moindre mutation d'une tâche. Les tâches liées se relisent deux fois par notification,
  /// c'est le seul endroit qui en a besoin.
  private func syncCompletionsFromReminders() async {
    let linked = linkedTasks()
    guard !linked.isEmpty else { return }
    let states = await service.completionStates(
      for: linked.compactMap(\.reminderIdentifier))
    var changed = false
    for task in linked {
      guard let id = task.reminderIdentifier, let done = states[id], task.isCompleted != done
      else { continue }
      task.isCompleted = done
      task.completedAt = done ? Date() : nil
      changed = true
    }
    if changed { try? context.save() }
  }

  /// Les tâches déjà rattachées à un rappel Apple — le retour de complétion les relit, l'import
  /// s'en sert pour ne pas réimporter ce qui est déjà là.
  private func linkedTasks() -> [TaskItem] {
    let descriptor = FetchDescriptor<TaskItem>(
      predicate: #Predicate { $0.reminderIdentifier != nil })
    return (try? context.fetch(descriptor)) ?? []
  }
}
