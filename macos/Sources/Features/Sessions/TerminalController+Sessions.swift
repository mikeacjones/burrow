import AppKit

extension TerminalController {
    /// End the session displayed in this window, confirming first if any of
    /// its processes are still running. The window then switches to another
    /// session or closes if none are left.
    func closeSession(withConfirmation: Bool) {
        guard withConfirmation, surfaceTree.contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately()
            return
        }

        confirmClose(
            messageText: "Close Session?",
            informativeText: "The session still has a running process. If you close it the process will be killed."
        ) {
            self.closeTabImmediately()
        }
    }
}
