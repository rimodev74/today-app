import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Aiguillage du panneau de détail. Seule la page d'une to-do list est construite pour
/// l'instant ; les vues intelligentes sont à rebrancher. La recherche vit dans la sidebar
/// (cf. `SearchPopover`) et pilote la sélection, elle n'a plus de branche ici.
struct TaskListView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  var body: some View { page }

  @ViewBuilder
  private var page: some View {
    switch selection {
    case .smartList(.all):
      // N'était que la page de l'Inbox : indiscernable d'une liste, et les tâches des projets n'y
      // apparaissaient jamais. C'est désormais l'inventaire complet (cf. `AllTasksPageView`).
      AllTasksPageView(searchPresented: $searchPresented)
    case .list(let list):
      // PAS de `.id(list.persistentModelID)` ici : il forçait SwiftUI à détruire et reconstruire
      // toute la page à chaque changement de liste (TextEditor/NSTextView, tous les TextField, le
      // ScrollView) → l'à-coup ressenti au clic. On réutilise la vue (switch instantané) ; l'état
      // transitoire par liste (brouillons, sélection, édition) est remis à zéro dans ListPageView
      // via `.onChange(of: list)`.
      ListPageView(
        list: list, selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus)
    case .project(let project):
      ProjectPageView(
        project: project, selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus)
    case .pomodoro:
      PomodoroView(searchPresented: $searchPresented)
    case .smartList(.archive):
      ArchivePageView(searchPresented: $searchPresented)
    case .smartList(.today):
      TodayPageView(searchPresented: $searchPresented)
    case .smartList(.upcoming):
      UpcomingPageView(searchPresented: $searchPresented)
    case nil:
      // Aucune destination : le seul état sans page. `selection` démarre sur « Aujourd'hui » et
      // rien ne la remet à nil aujourd'hui — la branche existe parce que le type l'autorise, pas
      // parce qu'un chemin y mène.
      comingSoon("Sélectionne une liste", searchPresented: $searchPresented)
    }
  }
}

@MainActor func comingSoon(_ title: String, searchPresented: Binding<Bool>) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    // Le titre de l'onglet reste hors du fondu, comme partout ailleurs.
    Text(title).font(.app(.title).bold())
    Text("À rebrancher.").foregroundStyle(.tertiary)
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  .padding(.top, 30)
  .padding(.horizontal, gutter)
  .safeAreaInset(edge: .bottom, spacing: 0) {
    BottomToolbar(
      onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented.wrappedValue = true })
  }
}
