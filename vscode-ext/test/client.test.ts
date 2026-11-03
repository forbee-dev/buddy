import { test } from "node:test";
import assert from "node:assert/strict";
import * as net from "net";
import * as os from "os";
import * as fs from "fs";
import * as path from "path";
import { BuddyClient } from "../src/client";

const socks = new Set<net.Socket>();
const listen = (sockPath: string, onData: (s: net.Socket, line: string) => void) =>
  new Promise<net.Server>((res) => {
    const srv = net.createServer((s) => {
      socks.add(s);
      let b = "";
      s.on("data", (d) => {
        b += d;
        let i;
        while ((i = b.indexOf("\n")) >= 0) {
          onData(s, b.slice(0, i));
          b = b.slice(i + 1);
        }
      });
    });
    srv.listen(sockPath, () => res(srv));
  });
const close = (s: net.Server) =>
  new Promise((r) => {
    s.close(r);
    socks.forEach((x) => x.destroy());
    socks.clear();
  });

test("sends hello, replies to requests, reconnects after server restart", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buddy-"));
  const sock = path.join(dir, "b.sock");
  const hellos: any[] = [];
  const acks: any[] = [];
  const onData = (s: net.Socket, line: string) => {
    const m = JSON.parse(line);
    if (m.kind === "ext-hello") {
      hellos.push(m);
      s.write('{"kind":"focus","reqId":"q","shellPid":1}\n');
    } else acks.push(m);
  };
  const client = new BuddyClient({
    socketPath: sock,
    minDelayMs: 20,
    maxDelayMs: 50,
    log: () => {},
    hello: async () => ({ kind: "ext-hello", terminals: [], workspaceFolders: ["/p/app"] }),
    onLine: (l) => ({ kind: "ack", reqId: JSON.parse(l).reqId, ok: true }),
  });
  const waitFor = async (f: () => boolean) => {
    for (let i = 0; i < 200 && !f(); i++) await new Promise((r) => setTimeout(r, 25));
    assert.ok(f());
  };
  try {
    // Client starts before the server exists: must retry quietly.
    client.start();
    await new Promise((r) => setTimeout(r, 100));
    let srv = await listen(sock, onData);
    await waitFor(() => hellos.length === 1);
    assert.deepEqual(hellos[0].workspaceFolders, ["/p/app"]);
    await waitFor(() => acks.length === 1);
    assert.deepEqual(acks[0], { kind: "ack", reqId: "q", ok: true });
    await close(srv);
    fs.rmSync(sock, { force: true });
    srv = await listen(sock, onData);
    await waitFor(() => hellos.length === 2);
    await close(srv);
  } finally {
    client.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("send before hello resolves is queued behind hello", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bq-"));
  const sock = path.join(dir, "b.sock");
  const kinds: string[] = [];
  const srv = await listen(sock, (_s, line) => kinds.push(JSON.parse(line).kind));
  let release!: () => void;
  const gate = new Promise<void>((r) => (release = r));
  const client = new BuddyClient({
    socketPath: sock,
    log: () => {},
    hello: async () => {
      await gate;
      return { kind: "ext-hello" };
    },
    onLine: () => undefined,
    onState: (on) => on && client.send({ kind: "ext-terminals", terminals: [] }),
  });
  try {
    client.start();
    await new Promise((r) => setTimeout(r, 150));
    assert.deepEqual(kinds, []);
    release();
    for (let i = 0; i < 100 && kinds.length < 2; i++) await new Promise((r) => setTimeout(r, 20));
    assert.deepEqual(kinds, ["ext-hello", "ext-terminals"]);
  } finally {
    client.stop();
    await close(srv);
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
