import AppKit
import EventKit
import SwiftUI

/// Feuille pour transformer une tâche en rappel Apple Rappels.
/// Ne connaît que `RemindersService` — aucune API EventKit manipulée ici hors le type `EKCalendar`
/// (simple valeur de sélection dans le Picker de liste).
///
/// **Une feuille macOS, pas une vue posée dans une fenêtre.** Trois manquements se voyaient à
/// l'usage, et aucun n'était visible en lisant le code :
/// 1. **Échap ne fermait pas.** Le bouton « Annuler » n'avait pas `.cancelAction` ; or toute feuille
///    du système se referme à Échap, sans exception. C'est le raccourci qu'on essaie en premier ;
/// 2. **« Annuler » n'annulait pas.** Le champ Titre écrivait DIRECTEMENT dans la tâche
///    (`@Bindable`), donc renommer puis annuler laissait le nouveau nom. Le brouillon vit désormais
///    ici, et n'atteint la tâche qu'à l'enregistrement ;
/// 3. **les libellés n'étaient pas alignés** — un `VStack` d'espacements inventés là où `Form`
///    aligne sa colonne de libellés et pose les marges du système. Écrire les siennes, c'était
///    réimplémenter ce que macOS fait déjà (cf. « Natif d'abord » dans `CLAUDE.md`).
struct SchedulePlannerView: View {
  let task: TaskItem
  let remindersService: RemindersService
  @Environment(\.dismiss) private var dismiss

  /// Brouillon du titre : la tâche n'est touchée qu'à l'enregistrement (cf. point 2 ci-dessus).
  @State private var title = ""
  @State private var day = Date()
  @State private var startTime = Date()
  @State private var dueTime = Date().addingTimeInterval(3600)
  @State private var selectedList: EKCalendar?

  @State private var accessDenied = false
  @State private var errorMessage: String?
  @State private var isSaving = false

  private var isUpdate: Bool { task.reminderIdentifier != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Le titre disait « Créer un rappel » y compris en modifiant un rappel existant, alors que
      // le bouton, lui, disait bien « Mettre à jour ». Les deux se lisent d'un coup d'œil.
      Text(isUpdate ? "Modifier le rappel" : "Nouveau rappel")
        .font(.app(.title2)).bold()
        .padding(.horizontal, 20)
        .padding(.top, 20)

      if accessDenied {
        deniedView
      } else {
        formView
      }
    }
    .frame(width: 420)
    .task { await prepare() }
    .alert("Erreur", isPresented: errorPresented, presenting: errorMessage) { _ in
      Button("OK") { errorMessage = nil }
    } message: {
      Text($0)
    }
  }

  /// Un vrai binding, et pas `.constant(...)` : avec un binding constant, l'alerte ne peut être
  /// refermée que par son propre bouton — Échap et un clic dehors la laissaient à l'écran.
  private var errorPresented: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }

  // MARK: - Formulaire

  private var formView: some View {
    VStack(spacing: 0) {
      Form {
        TextField("Titre", text: $title)
        DatePicker("Date", selection: $day, displayedComponents: .date)
        DatePicker("Début", selection: $startTime, displayedComponents: .hourAndMinute)
        DatePicker("Échéance", selection: $dueTime, displayedComponents: .hourAndMinute)

        Picker("Liste", selection: $selectedList) {
          ForEach(remindersService.writableLists, id: \.calendarIdentifier) { list in
            Text(list.title).tag(list as EKCalendar?)
          }
        }
      }
      .formStyle(.grouped)

      actionBar
    }
  }

  private var deniedView: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(RemindersError.accessDenied.errorDescription ?? "")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Fermer") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Ouvrir les Réglages") {
          let url = URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
          NSWorkspace.shared.open(url)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
  }

  /// Ordre macOS : le bouton par défaut à droite, l'annulation à sa gauche. `.cancelAction` ne sert
  /// pas qu'à Échap — c'est aussi lui qui dit au système lequel des deux est l'échappatoire.
  private var actionBar: some View {
    HStack {
      Spacer()
      Button("Annuler") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button(isUpdate ? "Mettre à jour" : "Créer le rappel") {
        Task { await save() }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding(20)
  }

  // MARK: - Actions

  /// Demande l'accès à l'ouverture et pré-remplit le formulaire depuis la tâche.
  private func prepare() async {
    title = task.title
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
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let id = try await remindersService.schedule(
        title: trimmed,
        start: start,
        due: max(due, start.addingTimeInterval(60)),  // garde-fou : échéance ≥ début
        list: selectedList,
        existingIdentifier: task.reminderIdentifier
      )
      // Le brouillon n'atteint la tâche qu'ici : l'écriture est le seul chemin qui la modifie.
      task.title = trimmed
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
