import * as vscode from "vscode";
import * as os from "os";
import * as path from "path";
import { BuddyClient } from "./client";
import { handleLine, TerminalLike } from "./protocol";
import { checkSocketTrust } from "./trust";
import { claudeBlocked } from "./claude";

const SOCKET_DIR = path.join(os.homedir(), "Library", "Application Support", "Buddy");
const SOCKET = path.join(SOCKET_DIR, "buddy.sock");

async function listTerminals(): Promise<{ shellPid: number; name: string; term: vscode.Terminal }[]> {
  const all = await Promise.all(
    vscode.window.terminals.map(async (term) => ({ shellPid: await term.processId, name: term.name, term })),
  );
  return all.filter((t): t is { shellPid: number; name: string; term: vscode.Terminal } => t.shellPid !== undefined);
}

const publicList = (l: { shellPid: number; name: string }[]) => l.map(({ shellPid, name }) => ({ shellPid, name }));

/** Absolute fsPaths of the window's folders, capped to the protocol limits. */
const workspaceFolders = (): string[] =>
  (vscode.workspace.workspaceFolders ?? [])
    .map((f) => f.uri.fsPath)
    .filter((p) => p.length <= 1024)
    .slice(0, 20);

/** Saved workspace file of the window; untitled and remote workspaces give undefined. */
const workspaceFile = (): string | undefined => {
  const u = vscode.workspace.workspaceFile;
  return u?.scheme === "file" && u.fsPath.length <= 1024 ? u.fsPath : undefined;
};

export function activate(ctx: vscode.ExtensionContext): void {
  const out = vscode.window.createOutputChannel("Buddy");
  const log = (m: string) => out.appendLine(`${new Date().toISOString()} ${m}`);
  const bar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, -100);
  bar.command = "buddy.showLog";
  const setState = (on: boolean) => {
    bar.text = on ? "🐾 Buddy" : "🐾 Buddy $(circle-slash)";
    bar.tooltip = on ? "Buddy: connected" : "Buddy: disconnected";
  };
  setState(false);
  bar.show();

  // Terminals resolved per request so a pid lookup never uses a stale list.
  let snapshot: Map<number, TerminalLike> = new Map();
  const refresh = async () => {
    const l = await listTerminals();
    snapshot = new Map(l.map((t) => [t.shellPid, t.term]));
    return l;
  };

  const client = new BuddyClient({
    socketPath: SOCKET,
    precheck: () => checkSocketTrust(SOCKET_DIR, SOCKET, process.getuid!()),
    log,
    onState: setState,
    hello: async () => ({
      kind: "ext-hello",
      editor: vscode.env.appName.includes("Cursor") ? "cursor" : "vscode",
      appPid: process.pid,
      version: ctx.extension.packageJSON.version,
      terminals: publicList(await refresh()),
      workspaceFolders: workspaceFolders(),
      workspaceFile: workspaceFile(),
    }),
    onLine: async (line) => {
      await refresh();
      const r = await handleLine(line, (pid) => snapshot.get(pid), claudeBlocked);
      if (r.log) log(r.log);
      return r.ack;
    },
  });

  const push = () =>
    void refresh()
      .then((l) => client.send({ kind: "ext-terminals", terminals: publicList(l), workspaceFolders: workspaceFolders(), workspaceFile: workspaceFile() }))
      .catch((e) => log(`push failed: ${String(e)}`));
  ctx.subscriptions.push(
    out,
    bar,
    vscode.window.onDidOpenTerminal(push),
    vscode.window.onDidCloseTerminal(push),
    vscode.workspace.onDidChangeWorkspaceFolders(push),
    vscode.commands.registerCommand("buddy.showLog", () => out.show(true)),
    { dispose: () => client.stop() },
  );
  client.start();
}

export function deactivate(): void {}
