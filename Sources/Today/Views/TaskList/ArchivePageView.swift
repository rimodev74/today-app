import SwiftData
import SwiftUI

/// Page « Archives » : les tâches cochées de TOUTES les listes, la plus récente en tête.
///
/// Elle porte la seule suppression définitive de l'app côté tâches terminées — cocher archive
/// (rien n'est détruit, cf. `ListPageView.isArchived`), et c'est ici qu'on jette pour de bon,
/// à l'unité ou d'un coup. Le tri et le filtrage viennent de `SmartList.archive` : la sidebar et
/// cette page lisent la même règle.
struct ArchivePageView: View {
  @Binding var searchPresented: Bool

  @Environment(\.modelContext) private var modelContext
  @Environment(RemindersService.self) private var remindersService
  @Query private var allTasks: [TaskItem]
  @State private var confirmingEmpty = false
  /// La sélection, comme sur toute autre page de tâches (cf. `TaskFocus`). Cette page n'a pas
  /// d'édition : on ne renomme pas une tâche terminée, on la décoche ou on la jette.
  @State private var focus = TaskFocus()

  private var archived: [TaskItem] {
    SmartList.archive.sort(SmartList.archive.filter(allTasks))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        Group {
          if archived.isEmpty {
            Text("Aucune tâche archivée.")
              .foregroundStyle(.tertiary)
          } else {
            ForEach(archiveMonths(archived)) { month in
              ArchiveMonthSection(
                month: month,
                onToggle: { restore($0) },
                onDelete: { delete($0) },
                focus: $focus
              )
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    // Le socle commun : ⌫ pour jeter la sélection, ↑/↓ pour la déplacer, clic dans le vide pour la
    // relâcher. Un pan par mois, dans l'ordre affiché — aucun n'est repliable ici.
    .taskPageBase(
      focus: $focus,
      blocks: { archiveMonths(archived).map { .visible($0.tasks) } },
      delete: delete
    )
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
    // Le seul geste irréversible en masse de l'app : il passe par une confirmation, contrairement
    // à la suppression à l'unité (une seule tâche, sous les yeux).
    .alert("Vider les archives ?", isPresented: $confirmingEmpty) {
      Button("Tout supprimer", role: .destructive) { emptyArchive() }
      Button("Annuler", role: .cancel) {}
    } message: {
      let plural = archived.count > 1 ? "s" : ""
      Text(
        "\(archived.count) tâche\(plural) archivée\(plural) "
          + "seront définitivement supprimées. Cette action est irréversible.")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      PageHeaderIcon(systemImage: SmartList.archive.systemImage, tint: SmartList.archive.color)
      Text(SmartList.archive.label)
        .font(.app(.title).bold())
      Spacer(minLength: 0)
      if !archived.isEmpty {
        Button("Vider les archives") { confirmingEmpty = true }
      }
    }
    .padding(.bottom, 14)
  }

  /// Décocher rend la tâche à sa liste, à sa place : l'archivage ne l'avait jamais déplacée.
  private func restore(_ task: TaskItem) {
    withAnimation(taskInsert) { task.toggleCompletion() }
    Task { await remindersService.pushCompletion(for: task) }
  }

  private func delete(_ task: TaskItem) {
    focus.forget(task)
    withAnimation(taskInsert) { modelContext.delete(task) }
    try? modelContext.save()
  }

  private func emptyArchive() {
    focus.dismiss()
    withAnimation(taskInsert) {
      for task in archived { modelContext.delete(task) }
    }
    try? modelContext.save()
  }
}

// MARK: - Rendu partagé

/// Un mois d'archives. `id` = le premier jour du mois, qui sert aussi de clé de tri.
struct ArchiveMonth: Identifiable {
  let id: Date
  let tasks: [TaskItem]

  /// « Juillet » dans l'année courante, « Juillet 2025 » sinon — l'année n'apparaît que quand elle
  /// apporte quelque chose.
  var label: String {
    let calendar = Calendar.current
    let sameYear = calendar.component(.year, from: id) == calendar.component(.year, from: Date())
    let style = sameYear ? Date.FormatStyle.dateTime.month(.wide) : .dateTime.month(.wide).year()
    return id.formatted(style).capitalized
  }
}

/// Regroupe des tâches archivées par mois de complétion, du plus récent au plus ancien. L'ordre
/// À L'INTÉRIEUR d'un mois est celui reçu (déjà trié par l'appelant).
func archiveMonths(_ tasks: [TaskItem]) -> [ArchiveMonth] {
  let calendar = Calendar.current
  let grouped = Dictionary(grouping: tasks) { task -> Date in
    let components = calendar.dateComponents(
      [.year, .month], from: task.completedAt ?? .distantPast)
    return calendar.date(from: components) ?? .distantPast
  }
  return grouped.keys.sorted(by: >).map { ArchiveMonth(id: $0, tasks: grouped[$0] ?? []) }
}

/// En-tête de mois + ses lignes. Partagé par la page « Archives » et la section repliable d'une
/// page de liste : les deux montrent la même chose, elles ne diffèrent que par le périmètre.
struct ArchiveMonthSection: View {
  let month: ArchiveMonth
  var onToggle: (TaskItem) -> Void
  var onDelete: (TaskItem) -> Void
  /// Sélection — seulement sur la page « Archives ». La section repliable d'une page de liste rend
  /// les mêmes lignes mais n'en a pas : sa page a déjà sa propre sélection, et surtout ses propres
  /// cadres de lignes. Publier ceux des archives dans le socle y ferait relâcher la sélection au
  /// premier clic sur une tâche vivante (elle n'est dans aucun cadre d'archive).
  var focus: Binding<TaskFocus>? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(month.label)
        .font(.app(.headline))
        .padding(.top, 14)
      Divider()
        .padding(.top, 6)

      ForEach(month.tasks) { task in
        if let focus {
          ArchiveRow(
            task: task, isSelected: focus.wrappedValue.isSelected(task),
            onToggle: { onToggle(task) }, onDelete: { onDelete(task) }
          )
          .rowPressGesture(
            isSelected: focus.wrappedValue.isSelected(task),
            isEditing: false,
            onSelect: { withAnimation(taskSelectFade) { focus.wrappedValue.select(task) } },
            onEdit: {}
          )
          .measureTaskRow(task)
        } else {
          ArchiveRow(task: task, onToggle: { onToggle(task) }, onDelete: { onDelete(task) })
        }
      }
      .padding(.top, 8)
    }
  }
}

/// Ligne d'archive : case, date de complétion, puis titre avec son rattachement dessous.
/// Le titre n'est PAS barré ici — dans une page qui ne contient que du terminé, le barré ne
/// distingue plus rien et alourdit la lecture ; la case cochée et la date suffisent.
struct ArchiveRow: View {
  @Bindable var task: TaskItem
  var isSelected: Bool = false
  var onToggle: () -> Void
  var onDelete: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      TaskCheckbox(isCompleted: task.isCompleted, onToggle: onToggle)

      // Colonne de date à largeur FIXE, alignée à droite : c'est elle qui met tous les titres sur
      // la même verticale, quelle que soit la longueur de la date (« 4 juil. » vs « 20 juil. »).
      // Calée au plus juste sur une date pleine : toute largeur en trop se lit comme un trou entre
      // la case et la date, pas comme de la marge.
      Text(task.completedAt?.formatted(.dateTime.day().month(.abbreviated)) ?? "")
        .font(.app(.callout))
        .foregroundStyle(Color.accentColor)
        .frame(width: 46, alignment: .trailing)

      VStack(alignment: .leading, spacing: 1) {
        Text(task.title.isEmpty ? "Sans titre" : task.title)
        if let parent {
          Text(parent)
            .font(.app(.callout))
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .taskRowSelection(isSelected)
    .contentShape(Rectangle())
    .contextMenu {
      Button("Décocher", action: onToggle)
      Divider()
      Button("Supprimer définitivement", role: .destructive, action: onDelete)
    }
  }

  /// D'où venait la tâche : son projet s'il y en a un, sinon sa liste. Sans ce rappel, une archive
  /// n'est qu'un tas de titres sans contexte (« Appeler le client » — pour quel projet ?).
  private var parent: String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
  }
}
