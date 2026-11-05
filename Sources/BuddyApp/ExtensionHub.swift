import Foundation
import BuddyCore

/// Connected VS Code / Cursor extensions and their terminals.
@MainActor
final class ExtensionHub {
    private struct Client { let conn: Connection; var editor: String; var version: String; var terminals: [ExtTerminal]; var folders: [String]; var workspaceFile: String? }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var acks: [String: (conn: ObjectIdentifier, cont: CheckedContinuation<AckMessage, Never>)] = [:]
    /// The editor app process above the extension peer; claimed terminals must descend from it.
    private var roots: [ObjectIdentifier: Int32] = [:]
    var onChange: (() -> Void)?

    func hello(_ m: ExtHelloMessage, from conn: Connection) {
        let root = conn.peerPid.flatMap(Jumper.terminalApp(above:))?.processIdentifier
        roots[ObjectIdentifier(conn)] = root
        clients[ObjectIdentifier(conn)] = Client(conn: conn, editor: m.editor, version: Activity.clip(m.version, 32),
                                                   terminals: owned(m.terminals, root: root),
                                                   folders: JumpTarget.validFolders(m.workspaceFolders),
                                                   workspaceFile: JumpTarget.validWorkspaceFile(m.workspaceFile))
        // Socket text is untrusted: logged clipped.
        log.info("Extension connected: \(Activity.clip(m.editor, 32), privacy: .public) \(Activity.clip(m.version, 32), privacy: .public)")
        onChange?()
    }

    func terminals(_ m: ExtTerminalsMessage, from conn: Connection) {
        let id = ObjectIdentifier(conn)
        clients[id]?.terminals = owned(m.terminals, root: roots[id])
        if let f = m.workspaceFolders {
            clients[id]?.folders = JumpTarget.validFolders(f)
            clients[id]?.workspaceFile = JumpTarget.validWorkspaceFile(m.workspaceFile)
        }
        onChange?()
    }

    /// Drops terminals whose shell does not run under the extension's own editor process.
    private func owned(_ terminals: [ExtTerminal], root: Int32?) -> [ExtTerminal] {
        guard let root else { return [] }
        return terminals.filter { ProcInfo.descends($0.shellPid, from: root) }
    }

    func closed(_ conn: Connection) {
        let id = ObjectIdentifier(conn)
        roots[id] = nil
        for (req, waiter) in acks where waiter.conn == id {
            acks[req] = nil
            waiter.cont.resume(returning: AckMessage(reqId: req, ok: false, error: "disconnected"))
        }
        guard clients.removeValue(forKey: id) != nil else { return }
        onChange?()
    }

    var connectedEditors: [String] { clients.values.map(\.editor) }
    var clientVersions: [(editor: String, version: String)] { clients.values.map { ($0.editor, $0.version) } }

    private func client(forShell pid: Int32) -> Client? {
        clients.values.first { $0.terminals.contains { $0.shellPid == pid } }
    }

    /// Window folder to raise: see `JumpTarget.pick`.
    func jumpTarget(shellPid: Int32?, cwd: String) -> JumpTarget.Pick {
        func window(_ c: Client) -> JumpTarget.Window { .init(folders: c.folders, workspaceFile: c.workspaceFile) }
        return JumpTarget.pick(owner: shellPid.flatMap(client(forShell:)).map(window), all: clients.values.map(window), cwd: cwd)
    }

    func hasTerminal(shellPid: Int32) -> Bool { client(forShell: shellPid) != nil }

    var shellPids: Set<Int32> { Set(clients.values.flatMap { $0.terminals.map(\.shellPid) }) }

    func ack(_ m: AckMessage) { acks.removeValue(forKey: m.reqId)?.cont.resume(returning: m) }

    /// Sends and waits up to 3 s for the ack.
    func send(shellPid: Int32, text: String) async -> AckMessage {
        let req = UUID().uuidString
        guard let c = client(forShell: shellPid), let line = try? WireMessage.encode(SendMessage(reqId: req, shellPid: shellPid, text: text, submit: true)) else {
            return AckMessage(reqId: req, ok: false, error: "no-terminal")
        }
        return await withCheckedContinuation { cont in
            acks[req] = (ObjectIdentifier(c.conn), cont)
            c.conn.send(line)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.acks.removeValue(forKey: req)?.cont.resume(returning: AckMessage(reqId: req, ok: false, error: "timeout"))
            }
        }
    }

    func focus(shellPid: Int32) {
        guard let c = client(forShell: shellPid),
              let line = try? WireMessage.encode(FocusMessage(reqId: UUID().uuidString, shellPid: shellPid)) else { return }
        c.conn.send(line)
    }
}
