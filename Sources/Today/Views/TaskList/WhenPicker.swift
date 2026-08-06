import SwiftData
import SwiftUI

/// Le sélecteur « Quand » : un JOUR, et une HEURE facultative.
///
/// Sorti de `TaskRow` parce qu'il s'ouvre depuis trois endroits (l'icône au survol, l'icône de la
/// carte d'édition, le menu ▸ *Quand…*) et qu'il devait être le même partout — un second sélecteur
/// posé « juste pour le survol » aurait divergé au premier réglage ajouté.
///
/// **La grille du mois reste le `DatePicker` natif** (`.graphical`), pas une grille maison : c'est
/// la règle du projet (natif d'abord), et c'est elle qui apporte gratuitement la navigation de mois,
/// les semaines du calendrier de l'utilisateur, la localisation et le clavier. Ce qui est écrit ici,
/// c'est ce que le natif ne donne pas : les raccourcis du haut, l'heure, et l'effacement.
///
/// **Le jour et l'heure ne se mélangent jamais** : `when` reçoit toujours un début de journée,
/// l'heure vit dans `whenMinutes` (cf. `TaskItem.when`). Toute l'app compare des jours ; une date
/// qui traînerait une heure ferait sortir la tâche des pages qui la cherchent par son jour.
struct WhenPicker: View {
  @Bindable var task: TaskItem
  /// Referme le popover. Posé par l'appelant, qui seul sait ce qui le présente.
  var onClose: () -> Void

  /// L'heure proposée quand on en ajoute une : celle des Réglages (9 h par défaut, cf.
  /// `RemindersSync.dueHour`). Autrement dit, l'heure à laquelle le rappel serait parti de toute
  /// façon — l'ajouter ne CHANGE donc rien tant qu'on n'y touche pas, elle rend juste visible et
  /// modifiable ce qui était implicite.
  @AppStorage(RemindersSync.dueHourStorageKey) private var defaultHour = RemindersSync.dueHour

  private var calendar: Calendar { .current }
  private var today: Date { calendar.startOfDay(for: Date()) }
  private var tomorrow: Date { calendar.date(byAdding: .day, value: 1, to: today) ?? today }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Quand")
        .font(.app(.subheadline).weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 10)

      // Les deux jours qu'on choisit neuf fois sur dix : à portée directe, avant la grille.
      quickRow("Aujourd'hui", symbol: "star.fill", tint: .yellow, day: today)
      quickRow("Demain", symbol: "sunrise.fill", tint: .orange, day: tomorrow)

      Divider().padding(.vertical, 8)

      DatePicker("", selection: dayBinding, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .labelsHidden()

      Divider().padding(.vertical, 8)

      timeRow

      if task.when != nil {
        Divider().padding(.vertical, 8)
        Button("Effacer") {
          task.when = nil
          task.whenMinutes = nil
          onClose()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
      }
    }
    .padding(12)
  }

  /// Le jour, TOUJOURS ramené à son début : c'est l'invariant de `when`, et c'est ici qu'il se
  /// tient — le `DatePicker` rend, lui, l'instant qu'il avait reçu, heure comprise.
  ///
  /// **Et le panneau se REFERME derrière le choix**, comme les raccourcis « Aujourd'hui » et
  /// « Demain » au-dessus. Ce n'est pas qu'une préférence : écrire `when` retrie la liste
  /// (`SmartList.sort`), donc la RANGÉE qui sert d'ancre à ce panneau se déplace ou se démonte sous
  /// lui. Un popover est une fenêtre accrochée à une vue ; quand cette vue s'en va, macOS le
  /// ré-affiche en plein calcul de mise en page et lève une exception dans `NSRemoteView` — deux
  /// plantages mesurés le 5 août 2026, pile à l'appui. Fermer d'abord, laisser le tri se faire
  /// ensuite : il n'y a plus de fenêtre accrochée à quoi que ce soit quand la ligne bouge.
  ///
  /// ponytail: l'heure demande donc de rouvrir le panneau. Poser jour ET heure d'une traite
  /// supposerait d'ancrer le panneau ailleurs que sur la rangée — un chantier sur le socle des cinq
  /// pages, à faire si l'aller-retour se sent à l'usage.
  private var dayBinding: Binding<Date> {
    Binding(
      get: { task.when ?? today },
      set: {
        task.when = calendar.startOfDay(for: $0)
        onClose()
      })
  }

  private func quickRow(_ title: String, symbol: String, tint: Color, day: Date) -> some View {
    Button {
      task.when = day
      onClose()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: symbol)
          .foregroundStyle(tint)
          .frame(width: 18)
        Text(title)
        Spacer(minLength: 12)
        if let when = task.when, calendar.isDate(when, inSameDayAs: day) {
          Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
        }
      }
      .font(.app(.body))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 4)
  }

  /// Trois états, et l'ordre compte : sans jour, une heure ne veut rien dire (« à 14 h », mais
  /// quel jour ?). La ligne le DIT plutôt que d'offrir un réglage sans effet.
  @ViewBuilder private var timeRow: some View {
    if task.when == nil {
      Label("Choisis un jour pour lui donner une heure.", systemImage: "clock")
        .font(.app(.callout))
        .foregroundStyle(.tertiary)
    } else if let minutes = task.whenMinutes {
      HStack(spacing: 8) {
        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
        DatePicker("", selection: timeBinding(minutes), displayedComponents: .hourAndMinute)
          .labelsHidden()
        Spacer(minLength: 0)
        Button {
          task.whenMinutes = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Retirer l'heure")
      }
    } else {
      Button {
        task.whenMinutes = defaultHour * 60
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "clock").frame(width: 18)
          Text("Ajouter une heure")
          Spacer(minLength: 0)
        }
        .font(.app(.body))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  /// Le `DatePicker` d'heure travaille sur des `Date` ; la tâche, elle, ne retient que des minutes
  /// depuis minuit. La conversion se fait ICI, aux deux bouts : le jour porté par la date rendue au
  /// picker n'a aucune importance, seule son heure est relue.
  private func timeBinding(_ minutes: Int) -> Binding<Date> {
    Binding(
      get: {
        calendar.date(
          bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: task.when ?? today)
          ?? today
      },
      set: { newValue in
        let time = calendar.dateComponents([.hour, .minute], from: newValue)
        task.whenMinutes = (time.hour ?? 0) * 60 + (time.minute ?? 0)
      })
  }
}
