import Foundation
import SwiftData

@Model
final class TaskItem {
  /// Identité STABLE entre appareils, posée à la création et jamais réécrite.
  ///
  /// `PersistentIdentifier` ne peut pas servir à ça : il n'a de sens que dans le store qui l'a
  /// attribué. Le Mac et l'iPhone en donneraient deux différents à la même tâche, et la synchro
  /// n'aurait aucun moyen de savoir si deux lignes sont la même chose ou deux choses — le mode de
  /// panne classique est que tout se retrouve en double.
  ///
  /// PAS de `@Attribute(.unique)` : CloudKit l'interdit (il ne sait pas tenir une contrainte
  /// d'unicité côté serveur), et un modèle qui en porte une refuse simplement de se synchroniser.
  /// L'unicité vient d'`UUID` lui-même, pas d'une contrainte de base.
  var uuid: UUID = UUID()
  // Valeurs par défaut sur TOUTE propriété non optionnelle : exigence dure de SwiftData + CloudKit,
  // qui doit pouvoir matérialiser une ligne dont un champ n'est pas encore arrivé. Elles ne changent
  // ni la forme du store ni les données — l'app remplit ces champs par `init` de toute façon.
  var title: String = ""
  var notes: Data = Data()
  var isCompleted: Bool = false
  /// Une en-tête est une ligne de séparation titrée dans la liste, pas une tâche.
  var isHeader: Bool = false
  var completedAt: Date?
  var sortIndex: Int = 0
  /// Rang manuel sur les vues intelligentes. **0 = jamais posée à la main**, et c'est la valeur de
  /// tout ce qui existe : l'ajout est absorbé par SwiftData sans rien migrer, et une base d'avant
  /// garde exactement l'ordre qu'elle avait.
  ///
  /// `sortIndex` ne pouvait pas servir : il est attribué PAR LISTE (et le réordonnancement d'une
  /// liste y réécrit 0…n). Sur « Aujourd'hui », les tâches viennent de listes différentes — deux
  /// d'entre elles peuvent porter le même `sortIndex`, elles ne sont pas comparables. Il fallait
  /// donc un second axe, celui des vues qui mélangent les provenances.
  ///
  /// Comparé par `SmartList.sort`, qui range les tâches placées à la main AVANT celles qui ne
  /// l'ont jamais été — cf. son commentaire pour ce que ça veut dire d'une tâche qui arrive.
  var smartOrder: Int = 0
  /// JOUR planifié, jamais une heure : tout ce qui pose une date de l'app (saisie rapide,
  /// sélecteurs, raccourcis) écrit un début de journée. Un champ `hasTime` a existé pour dire
  /// « l'heure de cette date compte » ; rien ne l'a jamais mis à vrai, et son affichage sur
  /// « À venir » était donc inatteignable — retiré au schéma 2.0.0. Le jour où l'app saura poser
  /// une heure, il reviendra AVEC son sélecteur, pas avant.
  var when: Date?
  /// Échéance (deadline) — distincte de `when` (jour planifié). Affichée à droite de la ligne
  /// avec un drapeau, en rouge une fois atteinte ou dépassée.
  var deadline: Date?
  var priorityRaw: Int = 0
  /// Durée estimée en minutes, 0 = non estimée (cf. `Estimate`). C'est elle que la page
  /// « Aujourd'hui » additionne pour confronter la journée planifiée au temps qui reste.
  var estimateMinutes: Int = 0
  var createdAt: Date = Date()
  /// Identifiant du rappel Apple Rappels associé, s'il existe.
  /// Permet de re-modifier le rappel au lieu d'en recréer un.
  var reminderIdentifier: String?
  var list: TodoList?
  /// Couleur de l'en-tête (uniquement significatif si `isHeader`). `nil` = style par défaut.
  /// Stocke `PaletteColor.rawValue` — voir `headerColor` ci-dessous, même pattern que `priority`.
  var headerColorRaw: String?
  @Relationship(deleteRule: .cascade, inverse: \Subtask.task) var subtasks: [Subtask] = []

  init(
    title: String,
    notes: Data = Data(),
    when: Date? = nil,
    isHeader: Bool = false,
    list: TodoList? = nil
  ) {
    self.title = title
    self.notes = notes
    self.isCompleted = false
    self.isHeader = isHeader
    self.when = when
    self.list = list
    self.createdAt = Date()
  }

  /// Fige l'ordre manuel d'une séquence, telle qu'elle doit s'afficher : 1…n.
  ///
  /// Jamais 0 — c'est la valeur de « jamais posée à la main », et la rendre à une tâche qu'on vient
  /// justement de poser la renverrait au tri automatique. Toute la séquence est réécrite, pas la
  /// seule tâche déplacée : c'est ce qui donne à ses voisines des rangs comparables au sien (même
  /// principe que la renumérotation 0…n d'une liste, cf. `TodoList`).
  static func stampSmartOrder(_ tasks: [TaskItem]) {
    for (index, task) in tasks.enumerated() { task.smartOrder = index + 1 }
  }

  // Stocké en Int : SwiftData persiste les propriétés stockées, pas les calculées.
  var priority: Priority {
    get { Priority(rawValue: priorityRaw) ?? .none }
    set { priorityRaw = newValue.rawValue }
  }

  /// Stocké en String (rawValue) : SwiftData persiste les propriétés stockées, pas les calculées.
  var headerColor: PaletteColor? {
    get { headerColorRaw.flatMap(PaletteColor.init(rawValue:)) }
    set { headerColorRaw = newValue?.rawValue }
  }

  var project: Project? { list?.project }

  /// Une tâche qui ne porte RIEN : refermer son édition la supprime plutôt que de laisser une
  /// ligne « Sans titre » derrière soi (cf. `TaskPageBase`).
  ///
  /// ⌘N crée la tâche AVANT qu'on ait tapé quoi que ce soit — c'est ce qui permet d'ouvrir la carte
  /// d'édition tout de suite. Le prix, c'est qu'un ⌘N suivi d'Échap laissait un déchet en base, sur
  /// les trois pages qui savent créer.
  ///
  /// **`when` n'entre PAS dans le compte, et c'est délibéré.** Une page peut dater une tâche
  /// d'office à sa création : « Aujourd'hui » le fait, sans quoi la tâche neuve ne s'afficherait
  /// même pas sur la page qui vient de la créer. Une date posée par la PAGE ne prouve donc rien sur
  /// ce que l'utilisateur a saisi, et le modèle ne sait pas distinguer les deux. Conséquence
  /// assumée : une tâche à laquelle on n'aurait donné qu'une date, sans titre ni rien d'autre,
  /// disparaît aussi — elle ne portait de toute façon aucune information lisible.
  ///
  /// Tout le RESTE compte, y compris ce qui ne se voit pas sur la ligne au repos (notes, rappel
  /// Apple) : ce sont des choses que seul l'utilisateur a pu poser.
  var isBlank: Bool {
    !isHeader
      && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && notes.isEmpty
      && subtasks.isEmpty
      && deadline == nil
      && priorityRaw == 0
      && estimateMinutes == 0
      && reminderIdentifier == nil
      && !isCompleted
  }

  func toggleCompletion() {
    isCompleted.toggle()
    completedAt = isCompleted ? Date() : nil
  }

  /// Ordre manuel des sous-tâches ; `createdAt` départage les ex æquo (même pattern que
  /// `TodoList.orderedTasks`).
  var orderedSubtasks: [Subtask] {
    sortedByKey(subtasks, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
  }

  /// Copie complète de la tâche, posée dans `list` — contenu, réglages et checklist.
  ///
  /// SEUL endroit qui sait ce qu'est « la même tâche ». Les deux chemins de duplication (une
  /// tâche via son menu, une liste entière via le sien) recopiaient chacun leur propre liste de
  /// champs et divergeaient à chaque ajout au modèle : la couleur d'en-tête, puis les sous-tâches,
  /// puis la durée estimée ont chacune été oubliées d'un côté ou de l'autre. Un champ ajouté à
  /// `TaskItem` se recopie désormais ici, ou nulle part.
  ///
  /// Volontairement NON copiés : la complétion (`isCompleted`/`completedAt` — une copie est une
  /// tâche à faire) et `reminderIdentifier` (un rappel Apple appartient à une seule tâche ; le
  /// partager ferait que cocher la copie cocherait l'originale).
  func copy(into list: TodoList?) -> TaskItem {
    let clone = TaskItem(title: title, notes: notes, when: when, isHeader: isHeader, list: list)
    clone.deadline = deadline
    clone.estimateMinutes = estimateMinutes
    clone.sortIndex = sortIndex
    // Les bruts (`…Raw`) et pas les propriétés calculées : ce sont eux que SwiftData persiste,
    // les lire ici rend la liste des champs à recopier vérifiable d'un coup d'œil sur le modèle.
    clone.priorityRaw = priorityRaw
    clone.headerColorRaw = headerColorRaw
    for sub in orderedSubtasks {
      let subCopy = Subtask(title: sub.title)
      subCopy.isDone = sub.isDone
      subCopy.sortIndex = sub.sortIndex
      clone.subtasks.append(subCopy)
    }
    return clone
  }

  /// Crée une sous-tâche vide en fin de liste et la renvoie (pour poser le focus dessus).
  @discardableResult
  func addSubtask() -> Subtask {
    let subtask = Subtask()
    subtask.sortIndex = (orderedSubtasks.last?.sortIndex ?? -1) + 1
    subtasks.append(subtask)
    return subtask
  }
}
