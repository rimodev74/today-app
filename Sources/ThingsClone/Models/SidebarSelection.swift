import SwiftUI

enum SmartList: Hashable, CaseIterable {
  case all
  case today
  case upcoming
  case archive

  var label: String {
    switch self {
    case .all: return "Tâches"
    case .today: return "Aujourd'hui"
    case .upcoming: return "À venir"
    case .archive: return "Archives"
    }
  }

  var systemImage: String {
    switch self {
    case .all: return "square.stack.fill"
    case .today: return "star.fill"
    case .upcoming: return "calendar"
    case .archive: return "checkmark.square.fill"
    }
  }

  var color: Color {
    switch self {
    case .all: return .teal
    case .today: return .yellow
    case .upcoming: return .red
    case .archive: return .green
    }
  }
}

enum SidebarSelection: Hashable {
  case smartList(SmartList)
  case project(Project)
  case list(TodoList)
  case pomodoro
}

extension SmartList {
  /// Une tâche appartient-elle à cette liste, indépendamment de son statut isCompleted ?
  func scopeMatches(_ task: TaskItem) -> Bool {
    guard !task.isHeader else { return false }
    let calendar = Calendar.current
    let startOfTomorrow = calendar.date(
      byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())
    )!
    switch self {
    case .all, .archive: return true
    case .today: return task.when.map { $0 < startOfTomorrow } ?? false
    case .upcoming: return task.when.map { $0 >= startOfTomorrow } ?? false
    }
  }

  /// ponytail: filtrage en mémoire tant que le volume reste petit — passer en #Predicate si lent.
  func filter(_ all: [TaskItem]) -> [TaskItem] {
    switch self {
    case .archive:
      return all.filter { $0.isCompleted && !$0.isHeader }
    default:
      return all.filter { !$0.isCompleted && scopeMatches($0) }
    }
  }

  /// Ordre d'affichage. Ces vues n'ont pas d'ordre manuel : la priorité y sert de
  /// tri (haute d'abord), puis la date, puis la création.
  func sort(_ tasks: [TaskItem]) -> [TaskItem] {
    if self == .archive {
      return tasks.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }
    return tasks.sorted { a, b in
      if a.priorityRaw != b.priorityRaw { return a.priorityRaw > b.priorityRaw }
      let da = a.when ?? .distantFuture
      let db = b.when ?? .distantFuture
      if da != db { return da < db }
      return a.createdAt < b.createdAt
    }
  }
}
