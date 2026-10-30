import SwiftUI

struct PomodoroView: View {
  @Environment(PomodoroTimer.self) private var timer
  @Binding var searchPresented: Bool

  var body: some View {
    @Bindable var timer = timer
    VStack(spacing: 24) {
      Text(timer.phase.label)
        .font(.app(.title2))
        .foregroundStyle(.secondary)

      PomodoroCountdown()

      HStack(spacing: 16) {
        Button(timer.isRunning ? "Pause" : "Démarrer") {
          timer.isRunning ? timer.pause() : timer.start()
        }
        Button("Remettre à zéro") { timer.reset() }
      }
      .buttonStyle(.bordered)

      Divider().padding(.vertical, 8)

      VStack(alignment: .leading, spacing: 12) {
        Stepper("Travail : \(timer.workMinutes) min", value: $timer.workMinutes, in: 1...120)
        Stepper(
          "Pause courte : \(timer.shortBreakMinutes) min", value: $timer.shortBreakMinutes,
          in: 1...60)
        Stepper(
          "Pause longue : \(timer.longBreakMinutes) min", value: $timer.longBreakMinutes, in: 1...60
        )
      }
      .frame(maxWidth: 280)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
  }
}

/// Le compte à rebours, et rien d'autre. `remaining` change CHAQUE SECONDE : le lire dans le corps
/// de la page l'abonnait à la seconde — les trois `Stepper`, le titre et la barre du bas se
/// reconstruisaient 60 fois par minute pour changer quatre chiffres. Ici, seule cette sous-vue le
/// lit, donc seule elle est invalidée (cf. `PIEGES.md` § Animations, « Lire le minuteur dans un
/// corps de vue l'abonne à la SECONDE »).
private struct PomodoroCountdown: View {
  @Environment(PomodoroTimer.self) private var timer

  var body: some View {
    Text(timer.formattedRemaining)
      .font(.app(64, weight: .bold, design: .rounded))
      .monospacedDigit()
  }
}

struct PomodoroMenuBarView: View {
  @Environment(PomodoroTimer.self) private var timer

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // La porte d'entrée quand l'icône du Dock est masquée (cf. `DockIcon`).
      Button("Ouvrir Today") { AppCommand.show.run() }

      Divider()

      Text(timer.phase.label)
        .font(.app(.headline))
      Button(timer.isRunning ? "Pause" : "Démarrer") {
        timer.isRunning ? timer.pause() : timer.start()
      }
      Button("Remettre à zéro") { timer.reset() }

      Divider()

      Button("Quitter") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(8)
  }
}
