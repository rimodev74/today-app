import SwiftData
import SwiftUI

/// Une sous-tâche dans la carte d'une `TaskItem` : case RONDE + titre. La case fonctionne au repos
/// comme en édition ; le titre n'est éditable qu'en édition (au repos il est en lecture seule, seule
/// la coche agit). Aligné sous le titre de la tâche par le retrait porté côté `TaskRow`.
struct SubtaskRowView: View {
  @Bindable var subtask: Subtask
  let isEditing: Bool
  /// Focus partagé avec `TaskRow`, clé = identifiant persistant de la sous-tâche (pour poser le
  /// focus sur celle qu'on vient de créer).
  @FocusState.Binding var focus: PersistentIdentifier?
  /// Entrée dans le champ (ajouter la suivante / terminer — logique côté `TaskRow`).
  var onEnter: () -> Void
  /// Retour arrière sur un champ vide (supprimer — logique côté `TaskRow`).
  var onDeleteEmpty: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      TaskCheckbox(isCompleted: subtask.isDone, circular: true) {
        subtask.isDone.toggle()
      }

      if isEditing {
        TextField("Sous-tâche", text: $subtask.title)
          .textFieldStyle(.plain)
          .focused($focus, equals: subtask.persistentModelID)
          .onSubmit(onEnter)
          // Retour arrière sur un champ vide → supprimer (sinon laisser le champ effacer un
          // caractère). `.delete` = la touche Retour arrière (0x7F), pas la suppression avant.
          .onKeyPress(.delete) {
            guard subtask.title.isEmpty else { return .ignored }
            onDeleteEmpty()
            return .handled
          }
      } else {
        Text(subtask.title)
          .strikethrough(subtask.isDone)
          .foregroundStyle(subtask.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
      }
    }
    .font(.body)
  }
}
