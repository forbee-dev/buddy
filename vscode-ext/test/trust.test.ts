import { test } from "node:test";
import assert from "node:assert/strict";
import * as net from "net";
import * as os from "os";
import * as fs from "fs";
import * as path from "path";
import { checkSocketTrust } from "../src/trust";

const uid = process.getuid!();

async function setup(dirMode: number, sockMode: number) {
  // Short path: unix socket paths are limited to ~104 bytes on macOS.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bt-"));
  const dir = path.join(root, "d");
  fs.mkdirSync(dir);
  const sock = path.join(dir, "s");
  const srv = net.createServer();
  await new Promise<void>((r) => srv.listen(sock, r));
  fs.chmodSync(sock, sockMode);
  fs.chmodSync(dir, dirMode);
  return { root, dir, sock, done: () => { srv.close(); fs.rmSync(root, { recursive: true, force: true }); } };
}

test("correct setup is trusted", async () => {
  const s = await setup(0o700, 0o600);
  try { assert.equal(checkSocketTrust(s.dir, s.sock, uid), undefined); } finally { s.done(); }
});

test("wrong dir mode rejected", async () => {
  const s = await setup(0o755, 0o600);
  try { assert.match(checkSocketTrust(s.dir, s.sock, uid)!, /dir mode/); } finally { fs.chmodSync(s.dir, 0o700); s.done(); }
});

test("wrong socket mode rejected", async () => {
  const s = await setup(0o700, 0o666);
  try { assert.match(checkSocketTrust(s.dir, s.sock, uid)!, /socket mode/); } finally { s.done(); }
});

test("wrong owner rejected", async () => {
  const s = await setup(0o700, 0o600);
  try { assert.match(checkSocketTrust(s.dir, s.sock, uid + 1)!, /owner/); } finally { s.done(); }
});

test("symlinked dir and symlinked socket rejected", async () => {
  const s = await setup(0o700, 0o600);
  try {
    const linkDir = path.join(s.root, "ld");
    fs.symlinkSync(s.dir, linkDir);
    assert.match(checkSocketTrust(linkDir, path.join(linkDir, "s"), uid)!, /real directory/);
    const linkSock = path.join(s.dir, "ls");
    fs.symlinkSync(s.sock, linkSock);
    assert.match(checkSocketTrust(s.dir, linkSock, uid)!, /real socket/);
  } finally { s.done(); }
});

test("missing socket in a trusted dir reports ENOENT", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "bt-"));
  try {
    fs.chmodSync(root, 0o700);
    assert.equal(checkSocketTrust(root, path.join(root, "none"), uid), "missing (ENOENT)");
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

// A socket owned by another uid inside a dir we own cannot be made without root, and the
// function takes one uid for both checks. The "wrong owner rejected" test covers the uid compare.
