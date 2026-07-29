import Foundation

/// Le sommeil d'une tâche : depuis combien de temps elle est posée sans qu'on en ait rien décidé.
///
/// C'est la matière que toutes les to-do lists laissent grossir en silence — et la raison pour
/// laquelle on finit par ne plus les ouvrir. Ici elle se voit : une tâche dont personne ne veut
/// pâlit jusqu'à devenir un fantôme, au lieu de rester aussi nette que celle d'hier.
enum Dormancy {
  /// Trois semaines : au-delà, une tâche ni datée ni faite n'attend plus rien, elle survit par
  /// inertie.
  static let thresholdDays = 21
  /// Huit semaines : plancher de l'effacement. Au-delà, inutile de pâlir davantage — une tâche
  /// illisible ne serait plus qu'un bug à l'écran.
  static let floorDays = 56
  static let minOpacity = 0.45

  static func days(since date: Date, now: Date = Date()) -> Int {
    Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0
  }

  /// Opacité de la ligne : pleine jusqu'au seuil, puis décroissance linéaire jusqu'au plancher.
  static func fade(days: Int) -> Double {
    guard days > thresholdDays else { return 1 }
    guard days < floorDays else { return minOpacity }
    let progress = Double(days - thresholdDays) / Double(floorDays - thresholdDays)
    return 1 - progress * (1 - minOpacity)
  }
}

extension TaskItem {
  /// Une tâche endormie : posée il y a longtemps, jamais datée, jamais faite.
  ///
  /// Lui donner un jour (`when`) la réveille — c'est ce geste, et pas le simple fait d'y toucher,
  /// qui vaut décision.
  ///
  /// ponytail: l'ancienneté se lit sur `createdAt`, pas sur une vraie date de dernier contact.
  /// Renommer une tâche ou lui ajouter une note ne la réveille donc pas. Ajouter un
  /// `lastTouchedAt` si l'écart se voit à l'usage — il coûte un `touch()` à chaque mutation.
  var isDormant: Bool {
    guard !isCompleted, !isHeader, when == nil else { return false }
    return Dormancy.days(since: createdAt) > Dormancy.thresholdDays
  }

  var dormancyFade: Double {
    guard !isCompleted, !isHeader, when == nil else { return 1 }
    return Dormancy.fade(days: Dormancy.days(since: createdAt))
  }
}
