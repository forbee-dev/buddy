import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "fs";
import { join } from "path";
import { LineFramer, handleLine as hl, sanitize, framed, PASTE_END, MAX_LINE_BYTES, MAX_TEXT_BYTES, TerminalLike, ClaudeCheck } from "../src/protocol";

const yes: ClaudeCheck = async () => undefined;
const handleLine = (l: string, f: (p: number) => TerminalLike | undefined, c = yes) => hl(l, f, c);
const fake = () => {
  const calls: unknown[][] = [];
  const t: TerminalLike = { sendText: (...a) => void calls.push(["send", ...a]), show: (...a) => void calls.push(["show", ...a]) };
  return { t, calls };
};

test("framing across chunk boundaries", () => {
  const f = new LineFramer();
  const got: string[] = [];
  const add = (s: string) => f.push(Buffer.from(s), () => assert.fail()).forEach((b) => got.push(b.toString()));
  add('{"a":');
  add('1}\n{"b":2}');
  add("\n\n");
  assert.deepEqual(got, ['{"a":1}', '{"b":2}']);
});

test("oversize line rejected, next line survives", () => {
  const f = new LineFramer();
  let over = 0;
  const got: string[] = [];
  const add = (b: Buffer) => f.push(b, () => over++).forEach((x) => got.push(x.toString()));
  add(Buffer.alloc(MAX_LINE_BYTES + 10, 0x61));
  add(Buffer.from("tail\nok\n"));
  assert.equal(over, 1);
  assert.deepEqual(got, ["ok"]);
});

test("oversize line within one chunk rejected", () => {
  const f = new LineFramer();
  let over = 0;
  const r = f.push(Buffer.concat([Buffer.alloc(MAX_LINE_BYTES + 1, 0x61), Buffer.from("\nok\n")]), () => over++);
  assert.equal(over, 1);
  assert.deepEqual(r.map(String), ["ok"]);
});

test("bad json and non-object ignored", async () => {
  assert.equal((await handleLine("{nope", () => undefined)).ack, undefined);
  assert.equal((await handleLine("[1]", () => undefined)).ack, undefined);
});

test("unknown kind ignored", async () => {
  assert.deepEqual(await handleLine('{"kind":"zzz","reqId":"1"}', () => undefined), {});
});

test("invalid field types rejected", async () => {
  const bad = [
    '{"kind":"send","reqId":"1","shellPid":"5","text":"x"}',
    '{"kind":"send","reqId":"1","shellPid":5,"text":3}',
    '{"kind":"send","reqId":"1","shellPid":5,"text":"x","submit":"yes"}',
    '{"kind":"send","reqId":"1","shellPid":1.5,"text":"x"}',
    '{"kind":"focus","reqId":"1"}',
  ];
  for (const b of bad) {
    const r = await handleLine(b, () => assert.fail("must not look up"));
    assert.deepEqual(r.ack, { kind: "ack", reqId: "1", ok: false, error: "bad-request" });
  }
  assert.equal((await handleLine('{"kind":"send","shellPid":5,"text":"x"}', () => undefined)).ack, undefined);
});

test("too-long text acks too-long", async () => {
  const r = await handleLine(`{"kind":"send","reqId":"1","shellPid":5,"text":"${"a".repeat(MAX_TEXT_BYTES + 1)}"}`, () => fake().t);
  assert.deepEqual(r.ack, { kind: "ack", reqId: "1", ok: false, error: "too-long" });
});

test("sanitize matches the shared vectors", () => {
  const vectors: { in: string; out: string }[] = JSON.parse(
    readFileSync(join(__dirname, "../../../Tests/Fixtures/sanitize-vectors.json"), "utf8"),
  );
  assert.ok(vectors.length >= 15);
  vectors.forEach((v, i) => assert.equal(sanitize(v.in), v.out, `vector ${i}`));
});

test("sanitize keeps newline and tab, strips other controls", () => {
  assert.equal(sanitize("a\r\nb\nc\x1b[31m\x00d\te\x7f\rf\x9b201~"), "a\nb\nc[31md\te\nf201~");
});

test("send pastes the text bracketed, then presses Enter separately", async () => {
  const a = fake();
  await handleLine('{"kind":"send","reqId":"r","shellPid":1,"text":"line one\\nline two"}', () => a.t);
  assert.deepEqual(a.calls, [
    ["send", "\x1b[200~line one\nline two\x1b[201~", false],
    ["send", "", true],
  ]);
});

test("ESC inside the text cannot end the paste early", async () => {
  const a = fake();
  await handleLine('{"kind":"send","reqId":"r","shellPid":1,"text":"x\\u001b[201~\\nrm -rf ~\\u009b201~"}', () => a.t);
  const sent = a.calls[0][1] as string;
  assert.equal(sent, framed("x[201~\nrm -rf ~201~"));
  assert.equal(sent.indexOf(PASTE_END), sent.length - PASTE_END.length);
  assert.equal(sent.split("\x1b").length, 3); // only the two framing ESCs
});

test("a blocked claude acks the reason and sends nothing", async () => {
  const a = fake();
  const r = await handleLine('{"kind":"send","reqId":"r","shellPid":1,"text":"x"}', () => a.t, async () => "claude-not-foreground");
  assert.deepEqual(r.ack, { kind: "ack", reqId: "r", ok: false, error: "claude-not-foreground" });
  assert.equal(a.calls.length, 0);
});

test("focus skips the claude check", async () => {
  const a = fake();
  const r = await handleLine('{"kind":"focus","reqId":"r","shellPid":1}', () => a.t, async () => "claude-not-running");
  assert.equal((r.ack as any).ok, true);
});

test("send goes to terminal matching shellPid", async () => {
  const a = fake();
  const b = fake();
  const find = (p: number) => ({ 1: a.t, 2: b.t } as Record<number, TerminalLike>)[p];
  const r = await handleLine('{"kind":"send","reqId":"r","shellPid":2,"text":"hi","submit":false}', find);
  assert.deepEqual(r.ack, { kind: "ack", reqId: "r", ok: true });
  assert.deepEqual(b.calls, [["send", framed("hi"), false]]);
  assert.equal(a.calls.length, 0);
  assert.ok(!r.log!.includes("hi"));
});

test("focus takes focus", async () => {
  const a = fake();
  await handleLine('{"kind":"focus","reqId":"r","shellPid":1}', () => a.t);
  assert.deepEqual(a.calls, [["show", false]]);
});

test("unknown shellPid gives no-terminal", async () => {
  const r = await handleLine('{"kind":"send","reqId":"r","shellPid":9,"text":"x","submit":true}', () => undefined);
  assert.deepEqual(r.ack, { kind: "ack", reqId: "r", ok: false, error: "no-terminal" });
});
