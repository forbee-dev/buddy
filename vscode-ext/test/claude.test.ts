import { test } from "node:test";
import assert from "node:assert/strict";
import * as cp from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { claudeBlocked, Exec } from "../src/claude";

const stub = (pgrep: string | Error, stat: string | Error): Exec => async (file) => {
  const out = file === "pgrep" ? pgrep : stat;
  if (out instanceof Error) throw out;
  return out;
};

test("not running for a process with no claude child, and for pid -1", async () => {
  assert.equal(await claudeBlocked(process.pid), "claude-not-running");
  assert.equal(await claudeBlocked(-1), "claude-not-running");
});

test("a direct child named claude is found", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bc-"));
  const bin = path.join(dir, "claude");
  fs.copyFileSync("/bin/sleep", bin);
  fs.chmodSync(bin, 0o755);
  const child = cp.spawn(bin, ["30"], { stdio: "ignore" });
  try {
    await new Promise<void>((res, rej) => (child.once("spawn", res), child.once("error", rej)));
    assert.notEqual(await claudeBlocked(process.pid), "claude-not-running");
  } finally {
    child.kill();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("process state decides: foreground ok, background or stopped refused", async () => {
  assert.equal(await claudeBlocked(1, stub("42\n", "S+\n")), undefined);
  assert.equal(await claudeBlocked(1, stub("42\n", "Ss+\n")), undefined);
  assert.equal(await claudeBlocked(1, stub("42\n", "S\n")), "claude-not-foreground");
  assert.equal(await claudeBlocked(1, stub("42\n", "T+\n")), "claude-not-foreground");
  assert.equal(await claudeBlocked(1, stub("42\n", new Error("ps failed"))), "claude-not-foreground");
  assert.equal(await claudeBlocked(1, stub(new Error("exit 1"), "S+\n")), "claude-not-running");
});
