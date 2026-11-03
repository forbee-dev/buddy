import { execFile } from "child_process";

/** True when the shell has a direct child process named exactly `claude`. */
export const hasClaudeChild = (shellPid: number): Promise<boolean> =>
  new Promise((resolve) => {
    // pgrep exits 1 when nothing matches; any error means "not found" (fail closed).
    execFile("pgrep", ["-P", String(shellPid), "-x", "claude"], { timeout: 3000 }, (err, out) =>
      resolve(!err && out.trim().length > 0),
    );
  });
