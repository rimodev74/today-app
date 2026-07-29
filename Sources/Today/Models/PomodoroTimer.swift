import AppKit
import Foundation
import Observation

enum PomodoroPhase: Equatable {
  case work
  case shortBreak
  case longBreak

  var label: String {
    switch self {
    case .work: return "Travail"
    case .shortBreak: return "Pause courte"
    case .longBreak: return "Pause longue"
    }
  }
}

@Observable
final class PomodoroTimer {
  static let sessionsBeforeLongBreak = 4

  private static let workMinutesKey = "pomodoroWorkMinutes"
  private static let shortBreakMinutesKey = "pomodoroShortBreakMinutes"
  private static let longBreakMinutesKey = "pomodoroLongBreakMinutes"
  static let autoStartStorageKey = "pomodoroAutoStartNextPhase"
  static let alertSoundStorageKey = "pomodoroAlertSoundName"
  static let defaultAlertSound = "Glass"
  // Sons système macOS (~/System/Library/Sounds), les mêmes que Réglages Système > Son.
  static let availableSounds = [
    "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
    "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
  ]

  var phase: PomodoroPhase = .work
  var remaining: TimeInterval
  var isRunning = false
  private(set) var completedWorkSessions = 0

  var workMinutes: Int {
    didSet { UserDefaults.standard.set(workMinutes, forKey: Self.workMinutesKey) }
  }
  var shortBreakMinutes: Int {
    didSet { UserDefaults.standard.set(shortBreakMinutes, forKey: Self.shortBreakMinutesKey) }
  }
  var longBreakMinutes: Int {
    didSet { UserDefaults.standard.set(longBreakMinutes, forKey: Self.longBreakMinutesKey) }
  }

  var formattedRemaining: String {
    let total = max(0, Int(remaining))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  @ObservationIgnored private var timer: Timer?

  init() {
    let defaults = UserDefaults.standard
    let work = defaults.object(forKey: Self.workMinutesKey) as? Int ?? 25
    workMinutes = work
    shortBreakMinutes = defaults.object(forKey: Self.shortBreakMinutesKey) as? Int ?? 5
    longBreakMinutes = defaults.object(forKey: Self.longBreakMinutesKey) as? Int ?? 15
    remaining = TimeInterval(work * 60)
  }

  func start() {
    guard !isRunning else { return }
    isRunning = true
    let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      self?.tick()
    }
    // .common (pas .default) : continue de tick pendant le tracking du menu (menu bar ouvert, resize, etc.)
    RunLoop.main.add(newTimer, forMode: .common)
    timer = newTimer
  }

  func pause() {
    isRunning = false
    timer?.invalidate()
    timer = nil
  }

  func reset() {
    pause()
    phase = .work
    completedWorkSessions = 0
    remaining = duration(for: .work)
  }

  func advancePhase() {
    switch phase {
    case .work:
      completedWorkSessions += 1
      phase =
        completedWorkSessions.isMultiple(of: Self.sessionsBeforeLongBreak)
        ? .longBreak : .shortBreak
    case .shortBreak, .longBreak:
      phase = .work
    }
    remaining = duration(for: phase)
  }

  private func tick() {
    guard remaining > 0 else { return }
    remaining -= 1
    if remaining <= 0 {
      handlePhaseCompletion()
    }
  }

  // Sépare de `tick()` pour être testable sans attendre un vrai `Timer`.
  func handlePhaseCompletion() {
    let soundName =
      UserDefaults.standard.string(forKey: Self.alertSoundStorageKey) ?? Self.defaultAlertSound
    NSSound(named: soundName)?.play()
    advancePhase()
    if !UserDefaults.standard.bool(forKey: Self.autoStartStorageKey) {
      pause()
    }
  }

  private func duration(for phase: PomodoroPhase) -> TimeInterval {
    switch phase {
    case .work: return TimeInterval(workMinutes * 60)
    case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
    case .longBreak: return TimeInterval(longBreakMinutes * 60)
    }
  }
}
