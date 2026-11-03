import { test } from "node:test";
import assert from "node:assert/strict";
import * as cp from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { hasClaudeChild } from "../src/claude";

test("false for a process with no claude child, and for pid -1", async () => {
  assert.equal(await hasClaudeChild(process.pid), false);
  assert.equal(await hasClaudeChild(-1), false);
});

test("true for a direct child named claude", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bc-"));
  const bin = path.join(dir, "claude");
  fs.copyFileSync("/bin/sleep", bin);
  fs.chmodSync(bin, 0o755);
  const child = cp.spawn(bin, ["30"], { stdio: "ignore" });
  try {
    await new Promise<void>((res, rej) => (child.once("spawn", res), child.once("error", rej)));
    assert.equal(await hasClaudeChild(process.pid), true);
  } finally {
    child.kill();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
