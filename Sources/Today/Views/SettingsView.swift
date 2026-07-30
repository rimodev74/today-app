import AppKit
import Carbon.HIToolbox
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
  @ViewBuilder var content: Content

  var body: some View {
    Form { content }
      .formStyle(.grouped)
      .frame(height: 300)
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

      Section("Saisie rapide") {
        LabeledContent("Raccourci global") { HotKeyRecorder() }
      }

      Section("Mises à jour") {
        LabeledContent("Version installée", value: version)

        Toggle("Vérifier automatiquement", isOn: $autoCheckUpdates)
          .onChange(of: autoCheckUpdates) { _, value in
            SparkleUpdater.shared.automaticallyChecksForUpdates = value
          }

        // `LabeledContent` et pas un `HStack` : c'est lui qui aligne le bouton sur la colonne des
        // autres rangées du formulaire groupé, seul, il flottait à gauche.
        LabeledContent("Recherche manuelle") {
          Button("Rechercher une mise à jour") {
            SparkleUpdater.shared.checkForUpdates()
          }
        }
      }
    }
  }
}

/// Enregistreur de raccourci : le bouton passe en écoute et capture la PROCHAINE combinaison
/// frappée.
///
/// Moniteur `NSEvent` local et pas `.onKeyPress` : le second ne voit que ce que SwiftUI veut bien
/// lui laisser (une combinaison à modificateurs part d'abord au menu — ⌘Q quitterait l'app en pleine
/// saisie), alors qu'un moniteur local voit l'événement AVANT le menu et peut le consommer
/// (`return nil`).
private struct HotKeyRecorder: View {
  @State private var label = GlobalHotKey.current.label
  @State private var monitor: Any?

  var body: some View {
    HStack(spacing: 8) {
      Button(buttonTitle) {
        if monitor == nil { start() } else { stop() }
      }
      .frame(minWidth: 150)

      Button("Réinitialiser") {
        GlobalHotKey.store(
          keyCode: GlobalHotKey.defaultKeyCode,
          modifiers: NSEvent.ModifierFlags(rawValue: UInt(GlobalHotKey.defaultModifiers)),
          label: GlobalHotKey.defaultLabel)
        label = GlobalHotKey.defaultLabel
      }
      .buttonStyle(.link)
    }
    // Un moniteur laissé installé continuerait d'avaler les frappes de toute l'app.
    .onDisappear(perform: stop)
  }

  private var buttonTitle: String {
    if monitor != nil { return "Tapez la combinaison…" }
    return label.isEmpty ? "Aucun" : label
  }

  private func start() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
      let keyCode = Int(event.keyCode)
      if keyCode == kVK_Escape && modifiers.isEmpty {
        stop()
        return nil
      }
      // Un raccourci GLOBAL sans modificateur volerait la touche à toutes les apps : on en exige
      // au moins un.
      guard !modifiers.isEmpty else {
        NSSound.beep()
        return nil
      }
      let text = GlobalHotKey.label(
        keyCode: keyCode, modifiers: modifiers, characters: event.charactersIgnoringModifiers)
      GlobalHotKey.store(keyCode: keyCode, modifiers: modifiers, label: text)
      label = text
      stop()
      return nil
    }
  }

  private func stop() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
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
