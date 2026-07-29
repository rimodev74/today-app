import AppKit
import EventKit
import SwiftUI

/// Feuille pour transformer une tâche en rappel Apple Rappels.
/// Ne connaît que `RemindersService` — aucune API EventKit manipulée ici hors le type `EKCalendar`
/// (simple valeur de sélection dans le Picker de liste).
struct SchedulePlannerView: View {
  @Bindable var task: TaskItem
  let remindersService: RemindersService
  @Environment(\.dismiss) private var dismiss

  @State private var day = Date()
  @State private var startTime = Date()
  @State private var dueTime = Date().addingTimeInterval(3600)
  @State private var selectedList: EKCalendar?

  @State private var accessDenied = false
  @State private var errorMessage: String?
  @State private var isSaving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Créer un rappel")
        .font(.title2).bold()

      if accessDenied {
        deniedView
      } else {
        formView
      }
    }
    .padding(24)
    .frame(width: 360)
    .task { await prepare() }
    .alert("Erreur", isPresented: .constant(errorMessage != nil)) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  // MARK: - Formulaire

  private var formView: some View {
    VStack(alignment: .leading, spacing: 12) {
      TextField("Titre", text: $task.title)
        .textFieldStyle(.roundedBorder)

      DatePicker("Date", selection: $day, displayedComponents: .date)
      DatePicker("Début", selection: $startTime, displayedComponents: .hourAndMinute)
      DatePicker("Échéance", selection: $dueTime, displayedComponents: .hourAndMinute)

      Picker("Liste", selection: $selectedList) {
        ForEach(remindersService.writableLists, id: \.calendarIdentifier) { list in
          Text(list.title).tag(list as EKCalendar?)
        }
      }

      HStack {
        Spacer()
        Button("Annuler") { dismiss() }
        Button(task.reminderIdentifier == nil ? "Créer le rappel" : "Mettre à jour") {
          Task { await save() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || task.title.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  private var deniedView: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(RemindersError.accessDenied.errorDescription ?? "")
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Fermer") { dismiss() }
        Button("Ouvrir les Réglages") {
          let url = URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
          NSWorkspace.shared.open(url)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
  }

  // MARK: - Actions

  /// Demande l'accès à l'ouverture et pré-remplit le formulaire depuis la tâche.
  private func prepare() async {
    do {
      try await remindersService.requestAccess()
    } catch {
      accessDenied = true
      return
    }

    if let when = task.when {
      day = when
      startTime = when
      dueTime = when.addingTimeInterval(3600)
    }
    selectedList = remindersService.defaultList ?? remindersService.writableLists.first
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }

    // Recompose date + heures : le jour vient du DatePicker « Date », les heures des deux autres.
    let start = combine(day: day, time: startTime)
    let due = combine(day: day, time: dueTime)

    do {
      let id = try await remindersService.schedule(
        title: task.title,
        start: start,
        due: max(due, start.addingTimeInterval(60)),  // garde-fou : échéance ≥ début
        list: selectedList,
        existingIdentifier: task.reminderIdentifier
      )
      task.reminderIdentifier = id  // conserve l'identifiant pour une modif ultérieure (bonus)
      dismiss()
    } catch {
      errorMessage = (error as? RemindersError)?.errorDescription ?? error.localizedDescription
    }
  }

  private func combine(day: Date, time: Date) -> Date {
    let calendar = Calendar.current
    let d = calendar.dateComponents([.year, .month, .day], from: day)
    let t = calendar.dateComponents([.hour, .minute], from: time)
    return calendar.date(
      from: DateComponents(
        year: d.year, month: d.month, day: d.day, hour: t.hour, minute: t.minute
      )) ?? day
  }
}
