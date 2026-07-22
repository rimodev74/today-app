import AppKit
import SwiftUI

/// Champ de titre d'une sous-tâche, adossé à `NSTextField`. Raison : un `TextField` SwiftUI laisse
/// son field editor AVALER le Retour arrière quand le champ est vide, si bien que `.onKeyPress(.delete)`
/// ne le voit jamais — impossible d'y brancher « Retour arrière sur vide → supprimer ». En NSTextField
/// on intercepte de façon fiable via `control(_:textView:doCommandBy:)` (même approche que
/// `RichTextEditor` pour les notes). Gère aussi Entrée (→ sous-tâche suivante) et le focus par uuid.
struct SubtaskField: NSViewRepresentable {
  @Binding var text: String
  let id: UUID
  /// uuid de la sous-tâche qui doit avoir le focus (partagé par `TaskRow`). Le champ se rend premier
  /// répondeur quand `focused == id`, et publie son id quand il prend le focus (clic).
  @Binding var focused: UUID?
  var onEnter: () -> Void
  var onDeleteEmpty: () -> Void

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: NSFont.systemFontSize)
    field.textColor = .secondaryLabelColor
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.cell?.isScrollable = true
    field.placeholderString = "Sous-tâche"
    field.stringValue = text
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    guard focused == id, field.currentEditor() == nil else { return }
    // Poser le focus quand c'est à cette sous-tâche de l'avoir et qu'elle ne l'a pas déjà.
    // `async` : à la création d'une nouvelle rangée, la vue n'est pas encore dans sa fenêtre au
    // premier `updateNSView` (window nil) — on repose au tour de runloop suivant.
    DispatchQueue.main.async {
      guard focused == id, field.currentEditor() == nil else { return }
      field.window?.makeFirstResponder(field)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: SubtaskField
    init(_ parent: SubtaskField) { self.parent = parent }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
      parent.focused = parent.id
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      // Ne pas laisser traîner un focus périmé quand on quitte le champ (clic ailleurs) : sinon
      // `updateNSView` le reprendrait. Si un autre champ a déjà pris le focus, il l'a déjà réécrit.
      if parent.focused == parent.id { parent.focused = nil }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        parent.onEnter()
        return true
      case #selector(NSResponder.deleteBackward(_:)):
        // Retour arrière sur un champ vide → supprimer ; sinon comportement natif (efface un caractère).
        guard textView.string.isEmpty else { return false }
        parent.onDeleteEmpty()
        return true
      default:
        return false
      }
    }
  }
}
