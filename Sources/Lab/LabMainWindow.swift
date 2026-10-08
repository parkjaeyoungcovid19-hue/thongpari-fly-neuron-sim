import Cocoa

/// Edit ▸ Undo/Redo (⌘Z/⇧⌘Z). NSWindow answers undo: itself, so the Lab
/// window routes it: typing not yet undone in the field being edited keeps
/// its own undo; otherwise (including right after Return applied a value,
/// when the field is still focused) the world history steps.
final class LabMainWindow: NSWindow {
    var worldUndo: ((WorldEditHistory.Direction) -> Void)?
    var worldHistory: (() -> WorldEditHistory)?

    /// The window's undo manager when a text field has typing to undo/redo.
    private func textUndo(_ direction: WorldEditHistory.Direction) -> UndoManager? {
        guard firstResponder is NSTextView, let manager = undoManager else { return nil }
        return (direction == .undo ? manager.canUndo : manager.canRedo) ? manager : nil
    }

    @objc func undo(_ sender: Any?) {
        if let text = textUndo(.undo) { text.undo() } else { worldUndo?(.undo) }
    }
    @objc func redo(_ sender: Any?) {
        if let text = textUndo(.redo) { text.redo() } else { worldUndo?(.redo) }
    }
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let isUndo = item.action == Selector(("undo:")), isRedo = item.action == Selector(("redo:"))
        guard isUndo || isRedo else { return super.validateMenuItem(item) }
        if let text = textUndo(isUndo ? .undo : .redo) {
            item.title = isUndo ? text.undoMenuItemTitle : text.redoMenuItemTitle
            return true
        }
        let history = worldHistory?() ?? WorldEditHistory()
        item.title = isUndo ? history.undoTitle : history.redoTitle
        return isUndo ? history.canUndo : history.canRedo
    }
}
