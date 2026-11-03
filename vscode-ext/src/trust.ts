import * as fs from "fs";

/** lstat checks: no symlinks, owned by us, private modes. Returns a reason or undefined when trusted. */
export function checkSocketTrust(dir: string, sock: string, uid: number): string | undefined {
  try {
    const d = fs.lstatSync(dir);
    if (!d.isDirectory()) return "dir is not a real directory";
    if (d.uid !== uid) return "dir owner mismatch";
    if ((d.mode & 0o777) !== 0o700) return "dir mode is not 0700";
    const s = fs.lstatSync(sock);
    if (!s.isSocket()) return "not a real socket";
    if (s.uid !== uid) return "socket owner mismatch";
    if ((s.mode & 0o777) !== 0o600) return "socket mode is not 0600";
  } catch (e) {
    return `missing (${(e as NodeJS.ErrnoException).code ?? e})`;
  }
  return undefined;
}
