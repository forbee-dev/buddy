import { execFile } from "child_process";

export type Exec = (file: string, args: string[]) => Promise<string>;

const run: Exec = (file, args) =>
  new Promise((resolve, reject) => execFile(file, args, { timeout: 3000 }, (err, out) => (err ? reject(err) : resolve(out))));

/** The ack error when the shell has no foreground child named exactly `claude`; undefined when typing is safe. */
export const claudeBlocked = async (shellPid: number, exec: Exec = run): Promise<string | undefined> => {
  // pgrep exits 1 when nothing matches; any error means "not found" (fail closed).
  const pid = await exec("pgrep", ["-P", String(shellPid), "-x", "claude"]).then((o) => o.trim().split("\n")[0], () => "");
  if (!pid) return "claude-not-running";
  // "+" = foreground process group, "T" = stopped (Ctrl-Z): typing would reach the shell instead.
  const stat = await exec("ps", ["-o", "stat=", "-p", pid]).then((o) => o.trim(), () => "");
  return stat.includes("+") && !stat.includes("T") ? undefined : "claude-not-foreground";
};
