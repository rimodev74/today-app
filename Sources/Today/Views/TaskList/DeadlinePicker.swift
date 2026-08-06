import SwiftData
import SwiftUI

/// Le sélecteur « Échéance » (la date LIMITE, le drapeau rouge) — distinct du jour planifié, qui a
/// son propre panneau (`WhenPicker`).
///
/// Sorti de `TaskRow` pour la même raison que lui : depuis que les deux panneaux sont présentés par
/// le socle de page (cf. `TaskPageBase`) et non plus par la rangée, leur contenu ne peut plus vivre
/// dans la rangée non plus.
struct DeadlinePicker: View {
  @Bindable var task: TaskItem
  /// Referme le panneau. Posé par l'appelant, qui seul sait ce qui le présente.
  var onClose: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      DatePicker("", selection: dayBinding, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()

      if task.deadline != nil {
        Divider()
        Button("Retirer l'échéance") {
          task.deadline = nil
          onClose()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
  }

  /// Le panneau se referme derrière le choix, comme `WhenPicker` — et pour la même raison, qui n'a
  /// rien d'esthétique : écrire une date peut retrier la liste, donc déplacer la rangée sous le
  /// panneau. Cf. `WhenPicker.dayBinding` pour la pile de plantage qui l'a établi.
  private var dayBinding: Binding<Date> {
    Binding(
      get: { task.deadline ?? Date() },
      set: {
        task.deadline = $0
        onClose()
      })
  }
}
