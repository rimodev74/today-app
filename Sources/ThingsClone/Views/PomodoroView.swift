import SwiftUI

struct PomodoroView: View {
  @Environment(PomodoroTimer.self) private var timer

  var body: some View {
    @Bindable var timer = timer
    VStack(spacing: 24) {
      Text(timer.phase.label)
        .font(.title2)
        .foregroundStyle(.secondary)

      Text(timer.formattedRemaining)
        .font(.system(size: 64, weight: .bold, design: .rounded))
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
  }
}

struct PomodoroMenuBarView: View {
  @Environment(PomodoroTimer.self) private var timer

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(timer.phase.label)
        .font(.headline)
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
