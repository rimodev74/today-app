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
      Section("Général") {
        Picker("Thème", selection: $themeRaw) {
          ForEach(AppTheme.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

        Picker("Fin de journée", selection: $endOfDayHour) {
          ForEach(6...23, id: \.self) { hour in
            Text("\(hour) h").tag(hour)
          }
        }

        Button("Rechercher une mise à jour") {
          SparkleUpdater.shared.checkForUpdates()
        }
      }

      Section("Tâches") {
        Picker("Tâches cochées", selection: $retentionRaw) {
          ForEach(CompletedTaskRetention.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

        Toggle("Descendre les tâches cochées en bas de la liste", isOn: $autoSortCompleted)
      }

      Section("Pomodoro") {
        Toggle("Enchaîner automatiquement les phases", isOn: $pomodoroAutoStart)

        HStack {
          Picker("Son d'alarme", selection: $pomodoroAlertSound) {
            ForEach(PomodoroTimer.availableSounds, id: \.self) { name in
              Text(name).tag(name)
            }
          }
          Button("Tester") {
            NSSound(named: pomodoroAlertSound)?.play()
          }
        }
      }
    }
    .padding(20)
    .frame(width: 400, height: 320)
  }
}
