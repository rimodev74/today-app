import SwiftData
import SwiftUI

/// Page « Aujourd'hui » : les tâches planifiées pour aujourd'hui, précédées d'une barre qui
/// confronte leur durée totale au temps qu'il reste réellement dans la journée.
///
/// C'est le seul endroit de l'app qui refuse de mentir sur la journée. Le reste (listes, projets)
/// accepte n'importe quel volume ; ici, planifier neuf heures dans un après-midi de trois se voit.
///
/// ponytail: page en lecture + estimation seulement — pas d'édition, de réordonnancement ni de
/// drag, contrairement à une page de liste. C'est une sonde : si la barre change la façon de
/// planifier, on lui branchera la machinerie complète de `ListPageView`.
struct TodayPageView: View {
  @Binding var searchPresented: Bool

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  @Query private var allTasks: [TaskItem]
  @AppStorage(DayCapacity.endOfDayHourKey) private var endOfDayHour = DayCapacity
    .defaultEndOfDayHour
  // Le temps restant fond pendant que la page est ouverte : sans re-rendu régulier, la barre
  // affiche la capacité de l'instant où l'on a ouvert la page, pas celle de maintenant.
  @State private var now = Date()
  // `@State` et pas un `let` construit dans le body : le tick change `now`, donc le body se
  // ré-évalue, donc un publisher construit là serait remplacé à chaque minute — `onReceive` se
  // réabonnerait, invalidant puis recréant un Timer à chaque fois. Ici il est créé une seule fois.
  @State private var ticker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
  /// Brouillon de la tâche libre (sans liste ni projet) créable depuis cette page.
  @State private var draft = ""
  @FocusState private var draftFocused: Bool

  private var tasks: [TaskItem] {
    SmartList.today.sort(SmartList.today.filter(allTasks))
  }

  private var capacity: DayCapacity {
    DayCapacity(estimates: tasks.map(\.estimateMinutes), now: now, endOfDayHour: endOfDayHour)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        if !tasks.isEmpty {
          capacityBar
            .padding(.bottom, 18)
        }
        ForEach(tasks) { task in
          TodayRow(task: task, onToggle: { toggle(task) })
        }
        newTaskRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        onNewTask: { draftFocused = true }, onInsertHeader: nil,
        onSearch: { searchPresented = true })
    }
    .onReceive(ticker) { now = $0 }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: SmartList.today.systemImage)
        .font(.title2)
        .foregroundStyle(SmartList.today.color)
      Text(SmartList.today.label)
        .font(.title.bold())
      Spacer(minLength: 0)
    }
    .padding(.bottom, 14)
  }

  /// La barre de réalité. `ProgressView` linéaire plutôt qu'un tracé maison : teinte, hauteur et
  /// contraste suivent le système (et le mode sombre) sans une ligne de plus.
  private var capacityBar: some View {
    let capacity = capacity
    return VStack(alignment: .leading, spacing: 6) {
      ProgressView(value: capacity.fill)
        .tint(capacity.isOverbooked ? .red : .accentColor)

      HStack(spacing: 6) {
        Text(planned(capacity))
          .foregroundStyle(capacity.isOverbooked ? Color.red : .secondary)
        Text("·").foregroundStyle(.tertiary)
        Text(remaining(capacity))
          .foregroundStyle(.secondary)
        if capacity.unestimatedCount > 0 {
          Text("·").foregroundStyle(.tertiary)
          Text("\(capacity.unestimatedCount) sans durée")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.callout)
    }
  }

  private func planned(_ capacity: DayCapacity) -> String {
    guard let total = Estimate.label(capacity.plannedMinutes) else { return "Rien d'estimé" }
    guard capacity.isOverbooked else { return "\(total) planifiées" }
    // Le chiffre qui compte est le dépassement, pas le total : c'est lui qui appelle une décision.
    return "\(total) planifiées, \(Estimate.label(capacity.overflowMinutes) ?? "") de trop"
  }

  private func remaining(_ capacity: DayCapacity) -> String {
    guard let left = Estimate.label(capacity.availableMinutes) else {
      return "journée finie (\(endOfDayHour) h)"
    }
    return "\(left) avant \(endOfDayHour) h"
  }

  private func toggle(_ task: TaskItem) {
    withAnimation(taskInsert) {
      task.toggleCompletion()
      if task.isCompleted { task.list?.moveToEndOfSection(task) }
    }
    Task { await remindersService.pushCompletion(for: task) }
  }

  /// Champ de création d'une tâche libre : ni liste ni projet, seulement datée d'aujourd'hui.
  /// Même retrait que `TodayRow` (case à cocher fantôme) pour rester aligné avec les titres.
  private var newTaskRow: some View {
    HStack(spacing: 10) {
      Color.clear.frame(width: 16, height: 16)
      TextField("Nouvelle tâche…", text: $draft)
        .textFieldStyle(.plain)
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    .padding(.vertical, 4)
  }

  private func createTask() {
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = ""
    guard !title.isEmpty else {
      draftFocused = false
      return
    }
    let task = TaskItem(title: title, when: Calendar.current.startOfDay(for: Date()))
    withAnimation(taskInsert) { modelContext.insertAndSave(task) }
    draftFocused = true
  }
}

/// Ligne d'« Aujourd'hui » : case, titre, rattachement, et le contrôle de durée à droite —
/// toujours visible (pas au survol) : sans durée, la barre du haut ne veut rien dire, l'estimation
/// doit donc être le geste le plus offert de la page.
private struct TodayRow: View {
  @Bindable var task: TaskItem
  var onToggle: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      TaskCheckbox(isCompleted: task.isCompleted, onToggle: onToggle)

      VStack(alignment: .leading, spacing: 1) {
        Text(task.title.isEmpty ? "Sans titre" : task.title)
        if let parent {
          Text(parent)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      estimateControl
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }

  private var estimateControl: some View {
    Menu {
      ForEach(Estimate.presets, id: \.self) { minutes in
        Button(Estimate.label(minutes) ?? "") { task.estimateMinutes = minutes }
      }
      if task.estimateMinutes > 0 {
        Divider()
        Button("Retirer la durée") { task.estimateMinutes = 0 }
      }
    } label: {
      EstimateTag(minutes: task.estimateMinutes)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  private var parent: String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }
}

/// Pastille de durée. Estimée : teintée. Vide : un tiret gris qui reste cliquable — une tâche
/// sans durée doit se voir dans la liste, c'est elle qui fausse le compte.
struct EstimateTag: View {
  let minutes: Int

  var body: some View {
    Text(Estimate.label(minutes) ?? "—")
      .font(.callout)
      .monospacedDigit()
      .foregroundStyle(minutes > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Color.primary.opacity(minutes > 0 ? 0.06 : 0.03),
        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .fixedSize()
  }
}
