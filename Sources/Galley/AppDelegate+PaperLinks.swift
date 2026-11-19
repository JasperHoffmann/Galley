// AppDelegate+PaperLinks.swift
// Opening `galleypdf://open?rel=…` links, the papers root setting, and the few cases that need
// the user: several files of the same name, or none found.

import AppKit

extension AppDelegate {
    /// Opens the paper linked as `rel` under the papers root at `page`. Silent when it is where the
    /// link says; a short note when it was found elsewhere; a dialog only when it cannot decide.
    func openPaper(rel: String, page: Int?, activate: Bool) {
        guard PaperLinks.root != nil else {
            let alert = NSAlert()
            alert.messageText = "No papers root is set"
            alert.informativeText = "This link points to \(rel) relative to a papers root. Set one with File > Set Papers Root…"
            alert.runModal()
            return
        }
        Task { @MainActor in
            let resolution = await Task.detached(priority: .userInitiated) {
                PaperLinks.resolve(rel: rel)
            }.value
            switch resolution {
            case .found(let url, let moved):
                self.openResolved(url, page: page, activate: activate)
                if moved {
                    let now = PaperLinks.relativePath(of: url) ?? url.path
                    self.showNotification("Found at \(now)", duration: 4)
                }
            case .ambiguous(let candidates):
                if let url = self.choose(among: candidates, for: rel) {
                    PaperLinks.remember(rel: rel, at: url)
                    self.openResolved(url, page: page, activate: activate)
                }
            case .missing:
                if let url = self.locate(rel) {
                    PaperLinks.remember(rel: rel, at: url)
                    self.openResolved(url, page: page, activate: activate)
                }
            }
        }
    }

    private func openResolved(_ url: URL, page: Int?, activate: Bool) {
        loadPDF(url: url, activate: activate, restorePosition: page == nil)
        if let page { goToPage(page) }
    }

    private func choose(among candidates: [URL], for rel: String) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Several files match \((rel as NSString).lastPathComponent)"
        alert.informativeText = "Which one does this link mean? Galley will remember your choice."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26), pullsDown: false)
        popup.addItems(withTitles: candidates.map { PaperLinks.relativePath(of: $0) ?? $0.path })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return candidates[popup.indexOfSelectedItem]
    }

    private func locate(_ rel: String) -> URL? {
        let alert = NSAlert()
        alert.messageText = "Couldn't find \((rel as NSString).lastPathComponent)"
        alert.informativeText = "It is neither at \(rel) nor anywhere else under the papers root."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = PaperLinks.root
        panel.message = "Where is \((rel as NSString).lastPathComponent) now?"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @objc func setPapersRoot(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = PaperLinks.root
        panel.prompt = "Set as Papers Root"
        panel.message = "Snippet links to PDFs under this folder store their path relative to it, "
            + "and Galley searches it when a linked PDF has moved."
            + (PaperLinks.root.map { "\nCurrent: \($0.path)" } ?? "")
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: PaperLinks.rootKey)
            showNotification("Papers root: \(url.lastPathComponent)", duration: 4)
        }
    }
}
