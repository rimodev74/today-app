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

      Text(timer.formattedRemaining)
        .font(.app(64, weight: .bold, design: .rounded))
        .monospacedDigit()

      HStack(spacing: 16) {
        Button(timer.isRunning ? "Pause" : "Start") {
          timer.isRunning ? timer.pause() : timer.start()
        }
        Button("Reset") { timer.reset() }
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
    // Fondu sur TOUTE la vue, contrairement aux autres onglets : Pomodoro n'a ni anneau de
    // progression, ni titre de page, ni encadré de notes — rien à préserver du fondu (cf.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
  }
}

struct PomodoroMenuBarView: View {
  @Environment(PomodoroTimer.self) private var timer

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(timer.phase.label)
        .font(.app(.headline))
      Button(timer.isRunning ? "Pause" : "Start") {
        timer.isRunning ? timer.pause() : timer.start()
      }
      Button("Reset") { timer.reset() }

      Divider()

      Button("Quitter") {
        NSApplication.shared.terminate(nil)
      }
    }
    .padding(8)
  }
}
