import AppKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(CompletedTaskRetention.storageKey) private var retentionRaw = CompletedTaskRetention
    .untilViewChange.rawValue
  @AppStorage(PomodoroTimer.autoStartStorageKey) private var pomodoroAutoStart = false
  @AppStorage(PomodoroTimer.alertSoundStorageKey) private var pomodoroAlertSound = PomodoroTimer
    .defaultAlertSound

  var body: some View {
    Form {
      Picker("Tâches cochées", selection: $retentionRaw) {
        ForEach(CompletedTaskRetention.allCases) { option in
          Text(option.label).tag(option.rawValue)
        }
      }

      Toggle("Pomodoro : enchaîner automatiquement les phases", isOn: $pomodoroAutoStart)

      HStack {
        Picker("Pomodoro : son d'alarme", selection: $pomodoroAlertSound) {
          ForEach(PomodoroTimer.availableSounds, id: \.self) { name in
            Text(name).tag(name)
          }
        }
        Button("Tester") {
          NSSound(named: pomodoroAlertSound)?.play()
        }
      }
    }
    .padding(20)
    .frame(width: 380, height: 190)
  }
}
