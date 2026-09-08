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
///
/// **`needsPush` et `needsEventPush` disent seulement si les deux côtés DIFFÈRENT — pas qui a
/// raison.** C'est `Verdict` qui répond à ça, et il lui faut un troisième terme : ce que portait
/// l'élément Apple au dernier accord. Sans lui, l'app gagnait toujours, et une modification faite
/// dans Calendrier ou dans Rappels était défaite dans la seconde.
enum RemindersSync {
  /// Identifiant de la liste Rappels qui sert de pont. Une seule, et la même dans les deux sens :
  /// c'est ce qui garde l'import borné à ce que l'utilisateur a désigné, au lieu d'aspirer tout ce
  /// que contient l'app Rappels.
  static let listStorageKey = "remindersSyncListIdentifier"
  static let pushStorageKey = "remindersSyncPushEnabled"
  static let importStorageKey = "remindersSyncImportEnabled"

  /// Identifiant du CALENDRIER où partent les tâches à durée, sous forme d'événements. Vide = la
  /// fonction n'existe pas : tout part en rappel, comme avant. Un réglage global et pas un choix
  /// par tâche — même raison que la liste-pont : une destination qu'on désigne une fois.
  static let eventCalendarStorageKey = "remindersSyncEventCalendarIdentifier"

  /// Le NOM du calendrier choisi, gardé à côté de son identifiant. Redondant en apparence, et
  /// pourtant nécessaire : le menu « Durée… » d'une tâche l'AFFICHE, et le lire depuis EventKit
  /// serait un appel synchrone à un service système depuis une rangée — ce que ce projet ne fait
  /// pas (cf. `CLAUDE.md` § Le fil principal). Réécrit à chaque ouverture des Réglages, il ne peut
  /// pas mentir plus d'une visite.
  static let eventCalendarNameStorageKey = "remindersSyncEventCalendarName"

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

  /// Ce qu'une tâche datée doit devenir du côté Apple — et l'exclusivité entre les deux, écrite UNE
  /// fois. Sans arbitre unique, une tâche à durée finirait avec un rappel ET un événement : deux
  /// entrées pour la même chose, chacune poussée par sa propre boucle.
  ///
  /// La DURÉE est ce qui départage, et c'est la seule chose qui manque à un rappel pour être un
  /// bloc d'agenda : un rappel a une échéance, un événement a un début et une fin. Une tâche à
  /// laquelle on donne une durée demande de la place dans la journée, pas une sonnerie.
  enum Destination {
    case none
    case reminder
    case event
  }

  /// `eventCalendarChosen` est le réglage : aucun calendrier désigné, et la durée ne change rien —
  /// tout continue de partir en rappel. C'est ce qui rend la fonction inerte tant qu'on ne l'a pas
  /// demandée, plutôt que de faire disparaître des rappels de tâches à durée déjà existantes.
  static func destination(for task: TaskItem, eventCalendarChosen: Bool) -> Destination {
    guard isPushable(task) else { return .none }
    return eventCalendarChosen && task.estimateMinutes > 0 ? .event : .reminder
  }

  /// Faut-il (ré)écrire l'événement de cette tâche ? `eventStart`/`eventMinutes` décrivent
  /// l'événement lié tel qu'il est en ce moment — `nil` s'il n'existe pas encore, ou si son
  /// identifiant est PÉRIMÉ (base restaurée : cf. `RemindersService.EventPresence`). Un événement
  /// que l'utilisateur vient de supprimer, lui, ne passe jamais par ici : c'est
  /// `shouldDropDuration` qui répond, et la durée tombe au lieu que l'événement renaisse.
  ///
  /// Mêmes deux comparaisons que `needsPush`, et pour la même raison : sans heure à elle, la tâche
  /// ne réclame qu'un JOUR. La durée, elle, se compare toujours — c'est le champ que le menu
  /// « Durée… » vient de poser.
  ///
  /// **Répond « ils diffèrent », jamais « la tâche a raison ».** L'appelant passe par
  /// `eventVerdict`, qui sait lequel des deux a bougé ; cette fonction-là ne sert qu'à mesurer
  /// l'écart, et sa tolérance au JOUR est aussi ce qui empêche l'heure par défaut d'être prise
  /// pour un changement au lancement.
  ///
  /// ponytail: le TITRE n'est pas comparé, exactement comme côté rappels — renommer une tâche ne
  /// renomme pas son événement tant qu'aucune date ni durée ne bouge. L'ajouter demanderait de le
  /// faire des deux côtés d'un coup, sans quoi les deux ponts se mettraient à diverger.
  static func needsEventPush(
    _ task: TaskItem, eventStart: Date?, eventMinutes: Int?, calendar: Calendar = .current
  ) -> Bool {
    guard isPushable(task), task.estimateMinutes > 0, let when = task.when else { return false }
    guard let eventStart, let eventMinutes else { return true }
    guard eventMinutes == task.estimateMinutes else { return true }
    guard let minutes = task.whenMinutes else {
      return !calendar.isDate(eventStart, inSameDayAs: when)
    }
    return !calendar.isDate(
      eventStart, equalTo: due(for: when, minutes: minutes, calendar: calendar),
      toGranularity: .minute)
  }

  /// L'événement lié n'a plus lieu d'être : la tâche a perdu sa durée ou sa date. Il est alors
  /// EFFACÉ du calendrier et la tâche repart en rappel à la passe suivante — retirer la durée
  /// défait exactement ce que la poser avait fait.
  ///
  /// Volontairement muet sur la COMPLÉTION : cocher une tâche n'efface pas son bloc d'agenda. Un
  /// événement passé raconte ce qu'on a fait de sa journée, et le supprimer effacerait cette
  /// trace — là où un rappel coché, lui, reste coché de son côté.
  static func shouldForgetEvent(_ task: TaskItem) -> Bool {
    task.eventIdentifier != nil && !(task.estimateMinutes > 0 && task.when != nil)
  }

  /// La DURÉE doit-elle tomber parce que son événement a été supprimé dans le Calendrier ?
  ///
  /// Le miroir exact de `shouldForgetEvent` : retirer la durée efface l'événement, effacer
  /// l'événement retire la durée. C'est la seule réponse qui garde vraie la règle « durée + date +
  /// calendrier ⇒ un événement » ; laisser la durée sans son événement mettrait l'app dans un état
  /// qu'aucune de ses fonctions ne sait décrire.
  ///
  /// La TÂCHE, elle, reste — contrairement à ce que fait `shouldDelete` pour un rappel supprimé.
  /// Un créneau qu'on efface d'un ⌫ dans le Calendrier ne dit rien de la tâche, de ses notes ni de
  /// ses sous-tâches ; il dit seulement qu'on ne veut plus de ce bloc-là.
  ///
  /// `vanished` est une affirmation FORTE, pas une absence : elle vient de
  /// `RemindersService.eventPresence`, qui exige d'avoir vu l'événement VIVANT dans cette session
  /// puis absent deux passes de suite.
  static func shouldDropDuration(_ task: TaskItem, vanished: Bool) -> Bool {
    vanished && task.eventIdentifier != nil && task.estimateMinutes > 0
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

  // MARK: Qui fait foi — la fusion à trois, sans laquelle un seul côté peut gagner

  /// Qui fait foi, quand la tâche et son élément Apple ne disent plus la même chose.
  ///
  /// **Les comparer ne suffit pas à répondre.** « La tâche a changé » et « l'élément a changé »
  /// produisent exactement le même écart. Sans troisième terme il fallait donc désigner un
  /// vainqueur d'avance, et c'était la tâche : un événement déplacé à la main dans le Calendrier
  /// revenait à sa place dans la seconde, une durée rallongée était rabotée. L'app ne
  /// synchronisait pas, elle imposait.
  ///
  /// Le troisième terme est la MÉMOIRE de ce que portait l'élément la dernière fois que les deux
  /// étaient d'accord (cf. `RemindersService.lastSeenEvent` / `lastSeenReminderDue`). Un élément
  /// ne bouge pas tout seul : s'il ne porte plus ce qu'on y avait laissé, c'est l'utilisateur qui
  /// l'a modifié dans l'app d'Apple, et c'est LUI qui fait foi. S'il le porte encore, l'écart ne
  /// peut venir que d'ici, et on pousse.
  ///
  /// **Première rencontre — aucune mémoire : Apple fait foi**, à condition qu'il y ait quelque
  /// chose à lire. La mémoire ne survit pas au lancement, et l'app ne peut pas avoir modifié une
  /// tâche pendant qu'elle était fermée : l'écart trouvé au réveil vient forcément de l'autre côté.
  /// C'est ce cas-là qui rend une soirée passée à réorganiser son agenda dans Calendrier.
  ///
  /// La condition d'arrêt ne change pas : après un `.pull`, la tâche porte ce que porte l'élément,
  /// donc la passe suivante répond `.agreed` et la chaîne s'éteint — exactement comme après un
  /// `.push` (cf. l'en-tête de ce fichier).
  ///
  /// ponytail: les deux modifiés depuis le dernier accord, Apple gagne. Trancher autrement
  /// demanderait une date de modification de chaque côté, donc un champ de plus au schéma.
  enum Verdict {
    /// Les deux disent la même chose : ne rien écrire.
    case agreed
    /// L'app fait foi : (ré)écrire l'élément Apple.
    case push
    /// Apple fait foi : recopier sur la tâche ce que porte l'élément (cf. `adopt`).
    case pull
  }

  /// Le verdict pour une tâche à durée et son événement. `event` est le créneau que porte
  /// l'événement lié EN CE MOMENT (`nil` s'il n'est pas lisible), `lastSeen` celui du dernier
  /// accord.
  ///
  /// Rien à lire ⇒ rien à reprendre : un identifiant périmé se réécrit (c'est ce qui rend son
  /// agenda à une base restaurée), et une tâche sans événement en obtient un. Un événement
  /// SUPPRIMÉ, lui, ne passe jamais par ici — c'est `shouldDropDuration` qui répond.
  static func eventVerdict(
    _ task: TaskItem, event: DateInterval?, lastSeen: DateInterval?, calendar: Calendar = .current
  ) -> Verdict {
    guard isPushable(task) else { return .agreed }
    let wantsPush = needsEventPush(
      task, eventStart: event?.start, eventMinutes: event.map { Int($0.duration / 60) },
      calendar: calendar)
    guard let event else { return wantsPush ? .push : .agreed }
    // Sans mémoire, c'est `needsEventPush` qui sert de test d'écart — et sa tolérance est ce qui
    // évite la fausse reprise du lancement : une tâche SANS heure ne réclame qu'un jour, donc
    // l'heure par défaut posée sur son événement n'est pas un écart, et elle ne remonte pas.
    if lastSeen.map({ $0 != event }) ?? wantsPush { return .pull }
    return wantsPush ? .push : .agreed
  }

  /// Le même verdict côté rappels. `due` est l'échéance que porte le rappel lié en ce moment,
  /// `lastSeen` celle du dernier accord.
  ///
  /// `wasSeenAlive` continue de départager les deux façons d'être introuvable (cf. `needsPush`) :
  /// un rappel absent ne se reprend pas, il se recrée ou se laisse mort.
  static func reminderVerdict(
    _ task: TaskItem, due: Date?, lastSeen: Date?, wasSeenAlive: Bool, calendar: Calendar = .current
  ) -> Verdict {
    guard isPushable(task) else { return .agreed }
    let wantsPush = needsPush(
      task, reminderDue: due, wasSeenAlive: wasSeenAlive, calendar: calendar)
    guard let due else { return wantsPush ? .push : .agreed }
    if lastSeen.map({ $0 != due }) ?? wantsPush { return .pull }
    return wantsPush ? .push : .agreed
  }

  /// Recopie sur la tâche ce que porte l'élément Apple — le geste du verdict `.pull`, et celui de
  /// l'import d'un rappel, qui est le même fait vu à sa première passe.
  ///
  /// Le jour et l'heure ne se mêlent jamais : `TaskItem.when` est un jour, `whenMinutes` la minute
  /// dans ce jour (cf. `TaskItem`). `minutes` est la durée de l'événement — `nil` pour un rappel,
  /// qui n'en a pas, et la durée de la tâche reste alors telle quelle.
  static func adopt(
    _ start: Date, minutes: Int?, on task: TaskItem, calendar: Calendar = .current
  ) {
    task.when = calendar.startOfDay(for: start)
    let time = calendar.dateComponents([.hour, .minute], from: start)
    task.whenMinutes = (time.hour ?? 0) * 60 + (time.minute ?? 0)
    if let minutes { task.estimateMinutes = minutes }
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
