import Foundation

/// Les preuves qu'un élément Apple lié (rappel ou événement) a été SUPPRIMÉ par l'utilisateur, et
/// pas seulement perdu de vue un instant. C'est d'elles que dépendent les deux gestes destructeurs
/// que la synchro fait sans qu'on les lui demande : effacer une tâche (`RemindersSync.shouldDelete`)
/// et retirer une durée (`RemindersSync.shouldDropDuration`).
///
/// **Absent ne veut pas dire supprimé**, et chaque preuve écarte un faux positif déjà payé ou
/// plausible :
/// 1. **vu vivant pendant CETTE session** — sinon l'identifiant est seulement périmé (base
///    restaurée, accès accordé après coup). Le 5 août 2026, supprimer sur « EventKit ne le trouve
///    pas » a effacé trois tâches d'une base fraîchement restaurée ;
/// 2. **absent sur une DURÉE réelle** (`minimumAbsence`) **et sur plusieurs passes distinctes**
///    (`minimumPasses`). « Deux passes de suite » ne prouvait rien : la seconde était le réarmement
///    à une seconde, soit 2 à 3 s d'absence — exactement la durée d'une resynchro iCloud, pendant
///    laquelle `.EKEventStoreChanged` sonne précisément. Le temps écarte le hoquet, le nombre de
///    passes écarte une passe isolée qui tomberait tard ;
/// 3. **pas de disparition EN MASSE** (`isHeld`) — un conteneur (liste-pont, calendrier) absent, ou
///    une part anormale des éléments vivants manquant d'un coup, c'est le compte qui se
///    resynchronise, pas l'utilisateur qui supprime. Ces passes-là ne comptent pas : ni le temps
///    qu'elles couvrent ne suffit, ni leur nombre ne s'ajoute.
///
/// Type de valeur sans EventKit ni horloge : l'instant arrive par paramètre, ce qui rend la règle
/// vérifiable seconde par seconde (cf. `VanishEvidenceTests`). En mémoire seulement, chez
/// `RemindersService` : la question « l'utilisateur vient-il de le supprimer ? » n'a de sens que
/// dans une session — persister ces preuves rendrait au lancement le jugement hâtif qu'on refuse.
struct VanishEvidence {
  /// ponytail: deux minutes. Assez pour qu'une resynchro iCloud retombe, assez court pour qu'une
  /// suppression faite dans Rappels se voie dans l'app avant qu'on ait oublié l'avoir faite.
  static let minimumAbsence: TimeInterval = 120
  static let minimumPasses = 3
  /// Au-delà de cette PART des éléments vivants manquant dans la même passe (et d'au moins
  /// `massMinimum`), la passe est tenue pour une panne, pas pour des suppressions.
  ///
  /// ponytail: supprimer d'un coup dans Rappels plus du quart des rappels liés (trois au moins)
  /// laisse donc les tâches en place, liées à des rappels morts. Pendant la session ils ne sont pas
  /// recréés (vus vivants, cf. `RemindersSync.needsPush`) ; au RELANCEMENT, la mémoire « vu
  /// vivant » est perdue et `needsPush` les recrée. Le prix de ne jamais effacer en masse sur un
  /// hoquet ; une suppression en masse se refait donc aussi dans l'app.
  static let massShare = 0.25
  static let massMinimum = 3

  /// Ce que l'app sait de l'élément lié, et le NIVEAU DE PREUVE qui va avec. Quatre réponses et pas
  /// un booléen, parce que « introuvable » recouvre trois situations qui appellent des gestes
  /// opposés.
  enum Presence: Equatable {
    /// Il est là.
    case alive
    /// Introuvable, et jamais vu vivant de la session : l'identifiant est périmé, pas orphelin.
    /// C'est le cas d'une base restaurée. On RECRÉE — c'est ce qui lui rend ses rappels et son agenda.
    case unknownIdentifier
    /// Vu vivant, puis absent — mais les preuves ne sont pas réunies. On ne touche à rien, et
    /// surtout on ne RÉÉCRIT pas : réécrire recréerait l'élément, donc effacerait la preuve.
    case missing
    /// Vu vivant, puis absent assez longtemps, sur assez de passes, hors de toute disparition en
    /// masse : l'utilisateur l'a supprimé. Le dossier est clos — l'identifiant est oublié.
    case vanished
  }

  private struct Absence {
    let since: Date
    var passes: Int
  }

  private var seenAlive: Set<String> = []
  private var absences: [String: Absence] = [:]

  /// La dernière passe a été retenue (disparition en masse) : rien n'a été compté. Les preuves en
  /// cours attendent alors un réveil venu d'ailleurs — le retour du compte poste lui-même
  /// `.EKEventStoreChanged` — au lieu de réarmer la synchro sur une panne.
  private(set) var isHeld = false

  func wasSeenAlive(_ identifier: String) -> Bool { seenAlive.contains(identifier) }

  /// UNE passe : l'état de TOUS les éléments liés suivis, d'un coup — c'est ce qui permet au
  /// garde-fou de masse de les voir ensemble. Un appel = une passe : l'appelant n'appelle qu'une
  /// fois par passe de synchro.
  ///
  /// `present` porte TOUS les identifiants suivis (`true` = trouvé). Ceux qui n'y sont plus sont
  /// oubliés au passage : un identifiant que plus aucune tâche ne porte ne sera plus jamais tranché,
  /// et une absence en attente pour lui réarmerait la synchro sans fin.
  ///
  /// `containerPresent` : le conteneur que la passe a relu (liste-pont, calendrier désigné) y était
  /// bien. Absent, rien n'est compté — c'est le cas d'un compte iCloud qui se resynchronise.
  mutating func assess(
    _ present: [String: Bool], containerPresent: Bool, at now: Date
  ) -> [String: Presence] {
    let tracked = Set(present.keys)
    seenAlive.formIntersection(tracked)
    absences = absences.filter { tracked.contains($0.key) }

    let aliveBefore = seenAlive.count
    let missingAlive = present.filter { !$0.value && seenAlive.contains($0.key) }.count
    let mass =
      missingAlive >= Self.massMinimum
      && Double(missingAlive) > Self.massShare * Double(aliveBefore)
    isHeld = !containerPresent || mass

    var verdicts: [String: Presence] = [:]
    for (identifier, found) in present {
      if found {
        seenAlive.insert(identifier)
        absences.removeValue(forKey: identifier)
        verdicts[identifier] = .alive
        continue
      }
      guard seenAlive.contains(identifier) else {
        verdicts[identifier] = .unknownIdentifier
        continue
      }
      // Passe retenue : l'absence n'est ni ouverte ni comptée. Une absence déjà ouverte garde son
      // point de départ — ce n'est pas la panne qui la prolonge, c'est ce qui suivra.
      guard !isHeld else {
        verdicts[identifier] = .missing
        continue
      }
      var absence = absences[identifier] ?? Absence(since: now, passes: 0)
      absence.passes += 1
      if absence.passes >= Self.minimumPasses
        && now.timeIntervalSince(absence.since) >= Self.minimumAbsence
      {
        absences.removeValue(forKey: identifier)
        seenAlive.remove(identifier)
        verdicts[identifier] = .vanished
      } else {
        absences[identifier] = absence
        verdicts[identifier] = .missing
      }
    }
    return verdicts
  }

  /// L'instant où la passe suivante peut faire avancer une absence en cours — `nil` s'il n'y en a
  /// pas, ou si la dernière passe a été retenue.
  ///
  /// Les passes sont ÉTALÉES sur la durée exigée (une à mi-parcours, une à l'échéance) plutôt que
  /// tirées à la seconde : `minimumPasses` passes coup sur coup ne prouveraient rien de plus
  /// qu'une seule. C'est aussi ce qui remplace l'ancien réarmement à 1 Hz, qui tournait sans fin
  /// pour un identifiant jamais tranché.
  var nextCheck: Date? {
    guard !isHeld else { return nil }
    let step = Self.minimumAbsence / Double(Self.minimumPasses - 1)
    return absences.values
      .map { $0.since.addingTimeInterval(min(Double($0.passes) * step, Self.minimumAbsence)) }
      .min()
  }

  /// Oublie ces identifiants : l'élément a été effacé d'ici (tâche supprimée, durée retirée), il n'y
  /// a plus rien à prouver à son sujet.
  mutating func forget<S: Sequence>(_ identifiers: S) where S.Element == String {
    for identifier in identifiers {
      seenAlive.remove(identifier)
      absences.removeValue(forKey: identifier)
    }
  }
}
