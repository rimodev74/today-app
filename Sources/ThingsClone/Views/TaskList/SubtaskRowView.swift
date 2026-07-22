import SwiftData
import SwiftUI

/// Une sous-tâche dans la carte d'une `TaskItem` : coche CARRÉE secondaire (case vide / cochée,
/// grise — volontairement plus discrète que la case pleine accentuée d'une tâche) + titre. La coche
/// agit au repos comme en édition ; le titre n'est éditable qu'en édition. Suppression : uniquement
/// via l'icône corbeille au survol ou le clic droit (pas de suppression au clavier).
struct SubtaskRowView: View {
  @Bindable var subtask: Subtask
  let isEditing: Bool
  /// Focus partagé avec `TaskRow`, clé = uuid stable (pas `persistentModelID`, qui mute à l'autosave
  /// et ferait sauter le focus).
  @FocusState.Binding var focus: UUID?
  var onEnter: () -> Void
  var onDelete: () -> Void

  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      Button {
        subtask.isDone.toggle()
      } label: {
        Image(systemName: subtask.isDone ? "checkmark.square" : "square")
          .font(.system(size: 15))
          .foregroundStyle(subtask.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isEditing {
        TextField("Sous-tâche", text: $subtask.title)
          .textFieldStyle(.plain)
          .foregroundStyle(.secondary)
          .focused($focus, equals: subtask.uuid)
          .onSubmit(onEnter)
      } else {
        Text(subtask.title)
          .strikethrough(subtask.isDone)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      // Corbeille au survol (comme le ••• d'une tâche) : supprime une sous-tâche, vide ou non.
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
