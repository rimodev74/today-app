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
  @AppStorage(DayCapacity.endOfDayHourKey) private var endOfDayHour = DayCapacity
    .defaultEndOfDayHour

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

      // Borne du compte à rebours de la barre de capacité d'« Aujourd'hui ». 6 h → 23 h : au-delà
      // la barre n'aurait plus de sens (une journée qui finit à 2 h du matin n'a pas de fin).
      Picker("Fin de journée", selection: $endOfDayHour) {
        ForEach(6...23, id: \.self) { hour in
          Text("\(hour) h").tag(hour)
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
    .frame(width: 380, height: 248)
  }
}
