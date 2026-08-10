import SwiftData
import SwiftUI

/// Le sélecteur « Quand » : un JOUR, et une HEURE facultative.
///
/// Sorti de `TaskRow` parce qu'il s'ouvre depuis trois endroits (l'icône au survol, l'icône de la
/// carte d'édition, le menu ▸ *Quand…*) et qu'il devait être le même partout — un second sélecteur
/// posé « juste pour le survol » aurait divergé au premier réglage ajouté.
///
/// **La grille du mois était le `DatePicker` natif** (`.graphical`) — elle ne l'est plus, et
/// `CalendarGrid` dit en tête pourquoi le natif ne convenait pas ici. Ce qui reste écrit dans CE
/// fichier, c'est ce qui n'a jamais été à la grille : les raccourcis du haut, l'heure, l'effacement.
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

      CalendarGrid(selection: task.when, onPick: pick)

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
  /// tient — la grille rend un jour, la tâche exige un début de journée.
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
  private func pick(_ day: Date) {
    task.when = calendar.startOfDay(for: day)
    onClose()
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
      HStack(spacing: 6) {
        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
        Picker("", selection: hourBinding(minutes)) {
          ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        Text(":").foregroundStyle(.secondary)
        Picker("", selection: minuteBinding(minutes)) {
          ForEach(Self.minuteChoices(including: minutes % 60), id: \.self) {
            Text(String(format: "%02d", $0)).tag($0)
          }
        }
        .labelsHidden()
        .fixedSize()
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

  /// Deux menus déroulants, et SURTOUT PAS un `DatePicker(.hourAndMinute)`.
  ///
  /// Sur macOS ce `DatePicker` est un `NSDatePicker` en style champ+incrémenteur : un CHAMP DE
  /// TEXTE. Le focaliser fait créer la liste de complétion d'AppKit, qui vit hors process
  /// (`SPCompletionListServiceViewController`, via ViewBridge) et s'abonne à « une fenêtre va
  /// s'afficher ». Ce panneau étant un popover, donc une fenêtre JETÉE à chaque fermeture, chaque
  /// heure réglée laissait un abonné sans fenêtre conteneur — et la prochaine fenêtre ordonnée à
  /// l'écran (ici le réveil de l'icône de barre de menus) faisait lever l'assertion dans
  /// `-[NSRemoteView containingWindowWillOrderOnScreen:]` : « Abort trap: 6 ». D'où le décalage qui
  /// égare — l'app meurt à la 5e heure réglée, pas à la 1re. Pile :
  /// `Today-2026-08-10-115358.ips`, même famille que les 27 plantages d'août 2026
  /// (→ `PIEGES.md` § Fenêtres). Un menu déroulant, lui, ne prend jamais le premier répondeur texte.
  ///
  /// ponytail: minutes au pas de 5, plus la valeur courante si elle tombe ailleurs (une heure venue
  /// des Rappels). Passer au pas de 1 si le besoin se fait sentir — c'est une liste plus longue,
  /// rien de plus.
  private static func minuteChoices(including current: Int) -> [Int] {
    let steps = Array(stride(from: 0, to: 60, by: 5))
    return steps.contains(current) ? steps : (steps + [current]).sorted()
  }

  private func hourBinding(_ minutes: Int) -> Binding<Int> {
    Binding(get: { minutes / 60 }, set: { task.whenMinutes = $0 * 60 + minutes % 60 })
  }

  private func minuteBinding(_ minutes: Int) -> Binding<Int> {
    Binding(get: { minutes % 60 }, set: { task.whenMinutes = minutes / 60 * 60 + $0 })
  }
}
