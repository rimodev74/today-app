import Foundation

/// Ce qui doit traverser entre Today et l'app Rappels — décidé ici, exécuté ailleurs. Ce type
/// n'écrit rien, ne connaît pas EventKit, et se vérifie donc sans store ni autorisation
/// (cf. `RemindersSyncTests`) ; `RemindersService` fournit les faits, `ContentView` orchestre.
///
/// **La règle qui empêche la boucle, et pourquoi elle est indispensable.** Les deux sens sont
/// branchés au MÊME point (cf. `ContentView.syncWithReminders`), lui-même réveillé par
/// `.EKEventStoreChanged` — qui sonne à chacune de NOS propres écritures. Sans condition d'arrêt,
/// chaque passe en déclencherait une autre indéfiniment. La condition, c'est `needsPush` : une
/// tâche dont le rappel porte déjà son jour n'est pas réécrite, la passe suivante ne trouve donc
/// plus rien à faire et la chaîne s'éteint d'elle-même.
///
/// C'est aussi ce qui protège l'HEURE d'un rappel importé. Un rappel Apple échu à 18 h devient une
/// tâche qui ne retient que le jour (`TaskItem.when` est un jour, jamais une heure) ; réécrire ce
/// rappel derrière l'import lui reposerait `dueHour` et écraserait l'heure choisie par
/// l'utilisateur. Comparer les JOURS, et seulement eux, laisse l'heure tranquille.
enum RemindersSync {
  /// Identifiant de la liste Rappels qui sert de pont. Une seule, et la même dans les deux sens :
  /// c'est ce qui garde l'import borné à ce que l'utilisateur a désigné, au lieu d'aspirer tout ce
  /// que contient l'app Rappels.
  static let listStorageKey = "remindersSyncListIdentifier"
  static let pushStorageKey = "remindersSyncPushEnabled"
  static let importStorageKey = "remindersSyncImportEnabled"

  /// Heure d'échéance posée sur un rappel créé depuis une tâche, quand rien n'est réglé. L'app ne
  /// pose que des JOURS (cf. `TaskItem.when`), donc il en faut une : une échéance à 00:00 fait
  /// sonner l'alarme la veille au soir pour l'utilisateur, ce qu'aucune tâche « pour demain » ne
  /// demande.
  static let dueHour = 9

  /// L'heure choisie dans les Réglages. Un réglage et pas un champ par tâche : l'app ne stocke que
  /// des jours, et lui donner une heure PAR TÂCHE demanderait une montée de version du schéma.
  static let dueHourStorageKey = "remindersSyncDueHour"

  /// Une tâche a-t-elle vocation à exister dans Rappels ?
  ///
  /// Le titre vide n'est pas un détail : ⌘N crée une tâche VIDE puis la page « Aujourd'hui » la
  /// date d'office (cf. `TaskItem.isBlank`). Sans ce filtre, chaque ⌘N suivi d'Échap laisserait un
  /// rappel sans titre derrière lui, dans une app que l'utilisateur ne regardait même pas.
  static func isPushable(_ task: TaskItem) -> Bool {
    !task.isHeader && !task.isCompleted && task.when != nil
      && !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Faut-il (ré)écrire le rappel de cette tâche ? `reminderDue` est l'échéance que porte le rappel
  /// lié en ce moment — `nil` s'il n'y en a pas encore, ou s'il est introuvable.
  ///
  /// **`wasSeenAlive` départage les deux façons d'être introuvable**, et sans lui la suppression
  /// depuis l'app Rappels ne marchait PAS (mesuré le 6 août 2026 : le rappel supprimé réapparaissait
  /// dans la seconde, et la tâche restait) :
  /// - **jamais vu vivant** — l'identifiant est périmé, pas orphelin. C'est le cas d'une base
  ///   restaurée : ses identifiants pointent des rappels nettoyés depuis longtemps. (Re)créer est
  ///   la bonne réponse, et c'est ce qui rend ses rappels à une sauvegarde qu'on remonte ;
  /// - **vu vivant dans cette session, puis disparu** — l'utilisateur vient de le supprimer. Le
  ///   recréer serait déjà faux en soi, mais le vrai dégât est ailleurs : ça EFFACE LA PREUVE que
  ///   `shouldDelete` attend. La passe suivante retrouve un rappel bien vivant (le nôtre, tout
  ///   neuf, avec un identifiant neuf), donc plus rien n'a jamais disparu, donc la tâche n'est
  ///   jamais supprimée. Les deux preuves de `RemindersService.reminderVanished` ne pouvaient
  ///   simplement pas être réunies tant que le push tournait.
  ///
  /// Sans valeur par défaut, comme `TaskPageBase.reorder` : un `false` implicite ramènerait
  /// exactement le défaut ci-dessus, sans un mot à la compilation.
  ///
  /// **Deux comparaisons, selon que la tâche porte une heure ou non**, et c'est ce qui garde la
  /// chaîne silencieuse dans les deux cas :
  /// - sans heure, on ne compare que les JOURS. C'est ce qui protège l'heure d'un rappel réglée
  ///   ailleurs (importée, ou changée à la main dans Rappels) : même jour, on ne touche à rien ;
  /// - avec heure, la tâche fait foi, jour ET heure. Sans cette branche, changer seulement l'heure
  ///   d'une tâche ne partirait jamais — même jour, donc « rien à faire », et le sélecteur d'heure
  ///   n'aurait aucun effet visible côté Rappels.
  ///
  /// ponytail: une tâche dont on RETIRE la date laisse son rappel derrière elle. Le supprimer
  /// demanderait de retenir qu'elle en avait un après que `when` soit repassé à `nil`, donc un
  /// champ de plus au schéma — et tout changement de forme d'un `@Model` coûte une montée de
  /// version. À faire le jour où le schéma bouge pour une autre raison.
  static func needsPush(
    _ task: TaskItem, reminderDue: Date?, wasSeenAlive: Bool, calendar: Calendar = .current
  ) -> Bool {
    guard isPushable(task), let when = task.when else { return false }
    guard let reminderDue else { return !(task.reminderIdentifier != nil && wasSeenAlive) }
    guard let minutes = task.whenMinutes else {
      return !calendar.isDate(reminderDue, inSameDayAs: when)
    }
    return !calendar.isDate(
      reminderDue, equalTo: due(for: when, minutes: minutes, calendar: calendar),
      toGranularity: .minute)
  }

  /// Cette tâche doit-elle DISPARAÎTRE parce que son rappel a été supprimé côté Apple ?
  ///
  /// **`vanished` est une affirmation FORTE, pas une simple absence.** Elle vient de
  /// `RemindersService.reminderVanished(_:)`, qui n'y répond `true` qu'après avoir vu le rappel
  /// VIVANT pendant cette session, puis absent DEUX passes de suite. La distinction a coûté des
  /// données réelles le 5 août 2026 : la version précédente supprimait sur un simple « EventKit ne
  /// le trouve pas », et trois tâches d'une base fraîchement RESTAURÉE sont parties en quelques
  /// minutes — leurs identifiants pointaient des rappels nettoyés depuis, ce qui n'a jamais voulu
  /// dire que l'utilisateur venait de les supprimer. Une sauvegarde qu'on restaure porte
  /// TOUJOURS des identifiants périmés ; supprimer sur cette base-là, c'est punir la restauration.
  ///
  /// Bornée à `isPushable` — c'est-à-dire à ce que `needsPush` recréerait — parce que c'est cette
  /// paire-là qui bouclait : le rappel disparu et la tâche jamais poussée sont le MÊME fait pour
  /// `needsPush` (pas de rappel ⇒ créer), donc supprimer côté Rappels n'avait aucun effet visible.
  /// Hors de ce périmètre, un rappel disparu reste sans conséquence : une tâche cochée garde sa
  /// place dans les archives, une tâche dont on a retiré la date garde son lien mort.
  static func shouldDelete(_ task: TaskItem, vanished: Bool) -> Bool {
    vanished && isPushable(task) && task.reminderIdentifier != nil
  }

  /// L'échéance à poser sur le rappel : le jour de la tâche, à SON heure (`minutes`) si elle en a
  /// une, à l'heure réglée dans les Réglages sinon.
  ///
  /// L'heure ARRIVE par paramètre plutôt que d'être lue ici : ce type reste une valeur pure, donc
  /// vérifiable sans défauts ni store (c'est toute sa raison d'être). Bornée quand même — une
  /// valeur hors plage rendrait `date(bySettingHour:)` incapable de construire la date, et le repli
  /// serait `day`, c'est-à-dire minuit, exactement l'heure que ce réglage sert à éviter.
  static func due(
    for day: Date, minutes: Int? = nil, hour: Int = dueHour, calendar: Calendar = .current
  ) -> Date {
    let total = minutes.map { min(max($0, 0), 24 * 60 - 1) } ?? min(max(hour, 0), 23) * 60
    return calendar.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: day) ?? day
  }
}
