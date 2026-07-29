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
        subtaskCheckbox
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
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .opacity(hovering ? 1 : 0)
    }
    // `.callout` (~1 pt sous `.body` du titre de tâche) : une sous-tâche est visuellement plus petite
    // que sa tâche parente.
    .font(.callout)
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Supprimer", role: .destructive, action: onDelete)
    }
  }

  /// Case carrée mais NETTEMENT plus arrondie que celle d'une tâche (rayon 5,5 sur 14 vs 4,5 sur 16),
  /// sans fond plein. Cochée : contour + ✓ en bleu accent — le même bleu que le FOND d'une tâche
  /// cochée, mais ici en contour, pour rester distinct.
  private var subtaskCheckbox: some View {
    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
      .strokeBorder(
        subtask.isDone ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary),
        lineWidth: 1.5
      )
      .overlay {
        if subtask.isDone {
          Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .frame(width: 14, height: 14)
      .contentShape(Rectangle())
  }
}

/// Petit anneau de progression (fraction 0…1) pour l'en-tête du dépliant de sous-tâches : l'arc bleu
/// se remplit au fur et à mesure des sous-tâches cochées.
struct SubtaskProgressRing: View {
  let fraction: Double

  var body: some View {
    ZStack {
      Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
      Circle()
        .trim(from: 0, to: max(0, min(1, fraction)))
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        // Départ à midi plutôt qu'à 3 h (l'arc de `trim` commence à droite par défaut).
        .rotationEffect(.degrees(-90))
    }
  }
}
