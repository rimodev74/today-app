import AppKit
import SwiftUI

struct SettingsView: View {
  @AppStorage(CompletedTaskRetention.storageKey) private var retentionRaw = CompletedTaskRetention
    .untilViewChange.rawValue
  @AppStorage(TodoList.autoSortCompletedStorageKey) private var autoSortCompleted = true
  @AppStorage(PomodoroTimer.autoStartStorageKey) private var pomodoroAutoStart = false
  @AppStorage(PomodoroTimer.alertSoundStorageKey) private var pomodoroAlertSound = PomodoroTimer
    .defaultAlertSound
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue

  var body: some View {
    Form {
      Picker("Thème", selection: $themeRaw) {
        ForEach(AppTheme.allCases) { option in
          Text(option.label).tag(option.rawValue)
        }
      }

      Picker("Tâches cochées", selection: $retentionRaw) {
        ForEach(CompletedTaskRetention.allCases) { option in
          Text(option.label).tag(option.rawValue)
        }
      }

      Toggle("Descendre les tâches cochées en bas de la liste", isOn: $autoSortCompleted)

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
    .frame(width: 380, height: 248)
  }
}
