import AppKit
import SwiftUI

/// `TextEditor` de SwiftUI grandit avec le texte mais ne RÉTRÉCIT jamais après suppression de
/// lignes : le `NSTextView` sous-jacent ne réinvalide pas sa taille intrinsèque vers le bas (bug
/// connu du framework). On enveloppe donc directement NSTextView — comme `TaskCheckbox` le fait
/// pour la case à cocher quand le contrôle SwiftUI natif ne convient pas — et on rapporte sa
/// taille exacte à SwiftUI via `sizeThatFits` à chaque frappe, ce qui grandit ET rétrécit sans
/// jamais faire apparaître de scrollbar interne.
struct AutoGrowingTextEditor: NSViewRepresentable {
  @Binding var text: String
  var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
  var textColor: NSColor = .labelColor
  /// Appelé sur Entrée ; `true` = géré (le retour à la ligne par défaut est supprimé),
  /// `false`/`nil` = comportement natif (insère un retour à la ligne).
  var handleReturn: ((_ shiftHeld: Bool) -> Bool)?

  func makeNSView(context: Context) -> NSTextView {
    let textView = NSTextView()
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.string = text
    textView.font = font
    textView.textColor = textColor
    return textView
  }

  func updateNSView(_ nsView: NSTextView, context: Context) {
    context.coordinator.parent = self
    if nsView.string != text { nsView.string = text }
    nsView.font = font
    nsView.textColor = textColor
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0,
      let textContainer = nsView.textContainer, let layoutManager = nsView.layoutManager
    else { return nil }
    textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
    layoutManager.ensureLayout(for: textContainer)
    let contentHeight = layoutManager.usedRect(for: textContainer).height
    let lineHeight = layoutManager.defaultLineHeight(for: nsView.font ?? font)
    return CGSize(width: width, height: ceil(max(contentHeight, lineHeight)))
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: AutoGrowingTextEditor
    init(_ parent: AutoGrowingTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }

    // Intercepte Entrée avant l'insertion native : `handleReturn` décide si elle doit être
    // avalée (retour `true`) ou laissée insérer un retour à la ligne comme d'habitude.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard selector == #selector(NSResponder.insertNewline(_:)), let handleReturn = parent.handleReturn
      else { return false }
      let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      return handleReturn(shiftHeld)
    }
  }
}
