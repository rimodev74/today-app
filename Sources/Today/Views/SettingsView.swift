import AppKit
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsTab()
        .tabItem { Label("Général", systemImage: "gearshape") }

      TasksSettingsTab()
        .tabItem { Label("Tâches", systemImage: "checklist") }

      PomodoroSettingsTab()
        .tabItem { Label("Pomodoro", systemImage: "timer") }
    }
    .frame(width: 460)
  }
}

// ponytail: shared sizing only, pas de wrapper générique de pane
private struct SettingsPane<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .frame(height: 300)
      // En sombre, le fond gris par défaut du `Form` groupé (windowBackgroundColor) jure avec le
      // canvas quasi noir de l'app : on repose le fond de page des listes, les cartes de `Section`
      // restant plus claires par-dessus — même étagement à deux tons que sidebar/page. En clair,
      // les valeurs système sont déjà celles de l'app, rien à surcharger.
      .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
      .background(colorScheme == .dark ? pageBackground : .clear)
  }
}

private struct GeneralSettingsTab: View {
  @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
  @AppStorage(DayCapacity.endOfDayHourKey) private var endOfDayHour = DayCapacity
    .defaultEndOfDayHour
  @State private var autoCheckUpdates = SparkleUpdater.shared.automaticallyChecksForUpdates

  private var version: String {
    let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
  }

  var body: some View {
    SettingsPane {
      Section("Apparence") {
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
      }

      Section("Mises à jour") {
        LabeledContent("Version installée", value: version)

        Toggle("Vérifier automatiquement", isOn: $autoCheckUpdates)
          .onChange(of: autoCheckUpdates) { _, value in
            SparkleUpdater.shared.automaticallyChecksForUpdates = value
          }

        Button("Rechercher une mise à jour") {
          SparkleUpdater.shared.checkForUpdates()
        }
      }
    }
  }
}

private struct TasksSettingsTab: View {
  @AppStorage(CompletedTaskRetention.storageKey) private var retentionRaw = CompletedTaskRetention
    .untilViewChange.rawValue
  @AppStorage(TodoList.autoSortCompletedStorageKey) private var autoSortCompleted = true

  var body: some View {
    SettingsPane {
      Section("Tâches cochées") {
        Picker("Conserver", selection: $retentionRaw) {
          ForEach(CompletedTaskRetention.allCases) { option in
            Text(option.label).tag(option.rawValue)
          }
        }

        Toggle("Descendre en bas de la liste", isOn: $autoSortCompleted)
      }
    }
  }
}

private struct PomodoroSettingsTab: View {
  @AppStorage(PomodoroTimer.autoStartStorageKey) private var pomodoroAutoStart = false
  @AppStorage(PomodoroTimer.alertSoundStorageKey) private var pomodoroAlertSound = PomodoroTimer
    .defaultAlertSound

  var body: some View {
    SettingsPane {
      Section("Minuteur") {
        Toggle("Enchaîner automatiquement les phases", isOn: $pomodoroAutoStart)
      }

      Section("Alerte") {
        Picker("Son d'alarme", selection: $pomodoroAlertSound) {
          ForEach(PomodoroTimer.availableSounds, id: \.self) { name in
            Text(name).tag(name)
          }
        }

        Button("Tester le son") {
          NSSound(named: pomodoroAlertSound)?.play()
        }
      }
    }
  }
}
