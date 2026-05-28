import AppKit

@main
struct PeekApp {
    static func main() {
        let args = CommandLine.arguments
        let autoStart = args.contains("--start-server") || args.contains("-s")

        let app = NSApplication.shared
        let delegate = AppDelegate()
        if autoStart {
            delegate.autoStartServer = true
        }
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let mcpServer = MCPServer()
    var autoStartServer = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        if autoStartServer {
            do {
                try mcpServer.start()
            } catch {
                // Fall through - menu will show stopped state
            }
        }
        updateMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "Peek")
            button.imagePosition = .imageLeft
        }
        updateMenu()
    }

    private func updateMenu() {
        let menu = NSMenu()

        // Status line
        let statusMenuItem = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Start/Stop server
        let toggleItem = NSMenuItem(
            title: serverToggleTitle(),
            action: #selector(toggleServer),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Peek",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func statusText() -> String {
        switch mcpServer.state {
        case .stopped:
            return "Status: Stopped ○"
        case .running(let port):
            return "Server: Running on :\(port)"
        }
    }

    private func serverToggleTitle() -> String {
        switch mcpServer.state {
        case .stopped:
            return "Start Server"
        case .running:
            return "Stop Server"
        }
    }

    @objc private func toggleServer() {
        switch mcpServer.state {
        case .stopped:
            do {
                try mcpServer.start()
            } catch {
                showAlert(message: "Failed to start server: \(error.localizedDescription)")
            }
        case .running:
            mcpServer.stop()
        }
        updateMenu()
    }

    @objc private func quitApp() {
        mcpServer.stop()
        NSApplication.shared.terminate(nil)
    }

    private func showAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Peek"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
