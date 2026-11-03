import AppKit
import SwiftUI
import BuddyCore

/// Form state of Settings → SSH (kept outside the view).
@MainActor
@Observable
final class SSHForm {
    static let shared = SSHForm()
    var host = ""
    var newClient = ""
    var message: String? { didSet { if let message { Announcer.say(message) } } }

    static var installScript: String? {
        AppServices.bundledResource("install", ext: "sh", subdirectory: "remote", devPath: "scripts/remote/install.sh")?.path
    }

    func copy(_ text: String, _ note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        message = note
    }

    /// The command holds two paths, never the token: the token goes to a 0600 file that the command pipes to the host.
    func copyInstall(model: AppModel) {
        guard let script = Self.installScript else { message = "install.sh is missing from this build."; return }
        guard RemoteInstall.validHost(host) else { message = "Not a valid host."; return }
        guard let token = model.currentRemoteToken() else { message = "The Keychain has no token and could not save one."; return }
        let envFile: String
        do { envFile = try model.writeInstallFile(token) } catch {
            message = "Buddy could not write the install file: \(error)"
            return
        }
        guard let cmd = RemoteInstall.command(host: host, envFile: envFile, script: script) else { message = "Not a valid host."; return }
        copy(cmd, "Copied. Paste it in Terminal within 10 minutes. Install file expires in 10 min.")
    }

    /// Only a binary named `ssh`, so the list cannot allow any other program.
    func addClient(model: AppModel) {
        let path = PeerCheck.resolved((newClient as NSString).expandingTildeInPath)
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == "ssh", FileManager.default.isExecutableFile(atPath: path) else {
            message = "Pick an executable named ssh, for example /opt/homebrew/bin/ssh."
            return
        }
        if !model.sshClients.contains(path) && !RemoteAuth.defaultClients.contains(path) { model.sshClients.append(path) }
        newClient = ""
        message = nil
    }
}

struct SSHTab: View {
    @Bindable var model: AppModel
    @Bindable var form = SSHForm.shared

    var body: some View {
        Form {
            Section {
                Toggle("Allow SSH sessions", isOn: $model.sshEnabled)
                Text("Claude Code on another host sends its hook events to Buddy over an `ssh -R` socket forward. Next prompt stays off for these sessions. See docs/SSH.md.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if model.sshEnabled {
                    Text(model.remoteListening ? "Listening on \(model.displayRemoteSocket)" : "Not listening. See Diagnostics.")
                        .font(.caption)
                }
            }
            Section("Remote install") {
                TextField("Host", text: $form.host, prompt: Text("devbox or user@devbox"))
                    .help("An ssh host alias or user@host")
                    .accessibilityValue(hostError.map { "\(form.host). \($0)" } ?? form.host)
                if let hostError { WarningText(text: hostError).accessibilityHidden(true) }
                HStack {
                    Button("Copy remote install command") { form.copyInstall(model: model) }
                        .disabled(!RemoteInstall.validHost(form.host))
                        .help("cat remote-install.env install.sh | ssh <host> 'bash -s'. Installs the hook and the token on the host.")
                    Button("Rotate token") { form.message = model.rotateRemoteToken() }
                        .help("Hosts with the old token stop working until you install again.")
                }
                Text("Add to ~/.ssh/config on this Mac (install.sh prints the exact remote path):").font(.caption)
                Text(snippet).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .accessibilityLabel("ssh config lines")
                Button("Copy ssh_config lines") { form.copy(snippet, "ssh_config lines copied.") }
                if let m = form.message { Text(m).font(.caption).fixedSize(horizontal: false, vertical: true) }
                if let until = model.installFileExpires {
                    Text("Install file expires in 10 min (at \(until.formatted(date: .omitted, time: .shortened))). It holds the token.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Allowed ssh clients") {
                Text("/usr/bin/ssh (always)").font(.callout)
                ForEach(model.sshClients, id: \.self) { path in
                    HStack {
                        Text(path).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { model.sshClients.removeAll { $0 == path } }
                            .accessibilityLabel("Remove \(path)")
                    }
                }
                HStack {
                    TextField("Other ssh", text: $form.newClient, prompt: Text("/opt/homebrew/bin/ssh"))
                    Button("Add") { form.addClient(model: model) }.disabled(form.newClient.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var hostError: String? {
        form.host.isEmpty || RemoteInstall.validHost(form.host) ? nil : "Use an ssh host alias or user@host: letters, digits, dot, dash, underscore."
    }

    private var snippet: String {
        let host = RemoteInstall.validHost(form.host) ? form.host : "devbox"
        return RemoteInstall.sshConfig(host: host, remoteHome: "/home/REMOTE_USER",
                                       localSocket: model.remoteSocketPath ?? UninstallPlan.supportFolder(home: NSHomeDirectory()) + "/remote.sock")
    }
}
