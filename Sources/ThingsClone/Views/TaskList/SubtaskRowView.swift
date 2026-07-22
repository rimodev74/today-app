import SwiftData
import SwiftUI

/// Une sous-tâche dans la carte d'une `TaskItem` : coche RONDE secondaire (cercle vide / cercle
/// coché, volontairement plus discrète que la case carrée pleine d'une tâche — une sous-tâche est un
/// détail de la tâche, pas son égale) + titre. La coche agit au repos comme en édition ; le titre
/// n'est éditable qu'en édition. Suppression : Retour arrière sur un champ vide (cf. `SubtaskField`),
/// clic droit, ou l'icône corbeille au survol.
struct SubtaskRowView: View {
  @Bindable var subtask: Subtask
  let isEditing: Bool
  /// uuid de la sous-tâche à focaliser (partagé par `TaskRow`, cf. `SubtaskField`).
  @Binding var focused: UUID?
  var onEnter: () -> Void
  var onDeleteEmpty: () -> Void
  var onDelete: () -> Void

  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Button {
        subtask.isDone.toggle()
      } label: {
        Image(systemName: subtask.isDone ? "checkmark.circle" : "circle")
          .font(.system(size: 15))
          .foregroundStyle(subtask.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isEditing {
        SubtaskField(
          text: $subtask.title, id: subtask.uuid, focused: $focused,
          onEnter: onEnter, onDeleteEmpty: onDeleteEmpty)
      } else {
        Text(subtask.title)
          .strikethrough(subtask.isDone)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      // Corbeille au survol (comme le ••• d'une tâche) : supprime une sous-tâche même non vide.
      // Opacité (pas insertion/retrait) pour ne pas décaler la rangée au survol.
      Button(action: onDelete) {
        Image(systemName: "trash")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(hovering ? 1 : 0)
    }
    .font(.body)
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Supprimer", role: .destructive, action: onDelete)
    }
  }
}
