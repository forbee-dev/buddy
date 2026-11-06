import { test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import * as http from "node:http";
import plugin, { createBuddy, formAnswer, permissionPayload, permissionReply, questionInput, replyForm, runHook, splitPicks } from "../buddy.js";

const here = { directory: "/work/proj" };
const out = (decision) => JSON.stringify({ hookSpecificOutput: { hookEventName: "PermissionRequest", decision } });
// After every pending microtask: an event handler that awaits only promises has reached its wait.
const tick = () => new Promise((r) => setImmediate(r));

/**
 * A fake buddy-hook: fire-and-forget calls resolve with `fire(payload)` (at once by default); waiting calls resolve with
 * `answer(payload)` or "" on abort.
 */
function harness({ sessions = {}, canReplyForm = true, answer = () => new Promise(() => {}), fire = () => "" } = {}) {
  const sent = [], replies = [], forms = [];
  const run = (_, payload, opts = {}) => {
    sent.push(payload);
    if (!opts.wait) return Promise.resolve(fire(payload));
    return new Promise((resolve) => {
      opts.signal?.addEventListener("abort", () => resolve(""), { once: true });
      Promise.resolve(answer(payload)).then(resolve);
    });
  };
  const buddy = createBuddy({
    hook: "/x/buddy-hook", run, location: here,
    getSession: async (id) => sessions[id],
    replyPermission: async (input) => replies.push(input),
    replyForm: async (...args) => forms.push(args),
    canReplyForm: async () => canReplyForm,
  });
  const events = () => sent.map((p) => p.hook_event_name);
  return { buddy, sent, replies, forms, events };
}

const question = {
  id: "frm_1", sessionID: "ses_a", title: "Questions", metadata: { kind: "question" },
  fields: [
    { key: "q0", type: "string", title: "Color", description: "Which color?", options: [{ value: "red", label: "Red" }, { value: "blue", label: "Blue" }], custom: true },
    { key: "q1", type: "multiselect", title: "Checks", description: "Which checks?", options: [{ value: "a", label: "Lint, fast" }, { value: "b", label: "Lint" }], custom: true },
  ],
};

test("permission reply: allow once, always only with a rule the request offered, deny with a message", () => {
  const req = { action: "shell", save: ["git *"] };
  const always = (rules) => out({ behavior: "allow", updatedPermissions: [{ type: "addRules", rules }] });
  assert.deepEqual(permissionReply(out({ behavior: "allow" }), req), { decision: "once" });
  assert.deepEqual(permissionReply(always([{ toolName: "shell", ruleContent: "git *" }]), req), { decision: "always" });
  for (const rules of [[{ toolName: "shell", ruleContent: "*" }], [{ toolName: "edit", ruleContent: "git *" }], [], undefined]) {
    assert.deepEqual(permissionReply(always(rules), req), { decision: "once" }, JSON.stringify(rules));
  }
  assert.deepEqual(permissionReply(always([{ toolName: "shell", ruleContent: "git *" }])), { decision: "once" });
  assert.deepEqual(permissionReply(out({ behavior: "deny", message: "no" })), { decision: "reject", message: "no" });
});

test("permission reply: empty, garbage, or another shape does nothing", () => {
  for (const bad of ["", "null", "not json", "[]", JSON.stringify({ hookSpecificOutput: { hookEventName: "Stop", decision: { behavior: "allow" } } }),
    out({ behavior: "ask" }), out("allow"), JSON.stringify({ decision: { behavior: "allow" } })]) {
    assert.equal(permissionReply(bad), undefined, bad);
  }
});

test("permission payload maps OpenCode fields to a Claude Code PermissionRequest", () => {
  const p = permissionPayload({ id: "per_1", sessionID: "ses_a", action: "shell", resources: ["git push"], save: ["git *"],
                                metadata: { command: "git push origin" }, message: "Push it" });
  assert.equal(p.tool_name, "shell");
  assert.equal(p.tool_use_id, "per_1");
  assert.deepEqual(p.tool_input, { command: "git push origin", resources: ["git push"], description: "Push it" });
  assert.deepEqual(p.permission_suggestions[0].rules, [{ toolName: "shell", ruleContent: "git *" }]);
  const read = permissionPayload({ id: "per_2", action: "read", resources: ["/etc/hosts"] });
  assert.equal(read.tool_name, "Read");
  assert.equal(read.permission_suggestions, undefined);
  assert.equal(permissionPayload({ id: "per_3", action: "constructor" }).tool_name, "constructor");
});

test("question forms become AskUserQuestion input; other forms do not", () => {
  assert.deepEqual(questionInput(question).questions[1], {
    question: "Which checks?", header: "Checks", multiSelect: true, options: [{ label: "Lint, fast" }, { label: "Lint" }],
  });
  assert.equal(questionInput({ ...question, metadata: { kind: "mcp" } }), undefined);
  assert.equal(questionInput({ ...question, fields: [{ key: "x", type: "external", url: "https://e" }] }), undefined);
});

test("form answer: labels become values, picks split on labels that hold commas, other text stays", () => {
  const answers = { "Which color?": "Blue", "Which checks?": "Lint, fast, Lint, my own" };
  assert.deepEqual(formAnswer(question, out({ behavior: "allow", updatedInput: { answers } })), { q0: "blue", q1: ["a", "b", "my own"] });
  assert.deepEqual(splitPicks("Lint", question.fields[1].options), ["b"]);
  assert.deepEqual(formAnswer(question, out({ behavior: "allow", updatedInput: { answers: { "Which color?": "Green", "Which checks?": "Lint" } } })),
                   { q0: "Green", q1: ["b"] });
});

test("form answer: a missing answer, a deny, or no output answers nothing", () => {
  assert.equal(formAnswer(question, out({ behavior: "allow", updatedInput: { answers: { "Which color?": "Red" } } })), undefined);
  assert.equal(formAnswer(question, out({ behavior: "deny" })), undefined);
  assert.equal(formAnswer(question, out({ behavior: "deny", updatedInput: { answers: { "Which color?": "Red", "Which checks?": "Lint" } } })), undefined);
  assert.equal(formAnswer(question, ""), undefined);
});

test("a main session: start, prompt, done with the last text, end", async () => {
  const h = harness();
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_a", location: here } });
  await h.buddy.handle({ type: "session.execution.started", location: here, data: { sessionID: "ses_a" } });
  await h.buddy.handle({ type: "session.text.ended", location: here, data: { sessionID: "ses_a", text: "All done." } });
  await h.buddy.handle({ type: "session.execution.succeeded", location: here, data: { sessionID: "ses_a" } });
  await h.buddy.handle({ type: "session.deleted", location: here, data: { sessionID: "ses_a" } });
  assert.deepEqual(h.events(), ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"]);
  assert.ok(h.sent.every((p) => p.session_id === "ses_a" && p.cwd === "/work/proj"));
  assert.equal(h.sent[2].last_assistant_message, "All done.");
});

test("events of another location are ignored; location-less events use the session's location", async () => {
  const h = harness({ sessions: { ses_b: { location: { directory: "/other" } }, ses_c: { location: here } } });
  await h.buddy.handle({ type: "session.execution.started", location: { directory: "/other" }, data: { sessionID: "ses_x" } });
  await h.buddy.handle({ type: "session.execution.started", data: { sessionID: "ses_b" } });
  await h.buddy.handle({ type: "session.execution.failed", data: { sessionID: "ses_c", error: { message: "rate limit" } } });
  assert.deepEqual(h.events(), ["SessionStart", "StopFailure"]);
  assert.equal(h.sent[1].error, "rate limit");
});

test("a child session is a subagent of its parent", async () => {
  const h = harness({ sessions: { ses_a: { location: here } } });
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_k", parentID: "ses_a", agent: "explore", location: here } });
  await h.buddy.handle({ type: "session.execution.succeeded", location: here, data: { sessionID: "ses_k" } });
  assert.deepEqual(h.events(), ["SessionStart", "SubagentStart", "SubagentStop"]);
  assert.deepEqual([h.sent[1].session_id, h.sent[1].agent_id, h.sent[1].agent_type], ["ses_a", "ses_k", "explore"]);
  assert.equal(h.sent[2].agent_id, "ses_k");
});

test("tool hook: success and failure become PostToolUse and PostToolUseFailure", async () => {
  const h = harness({ sessions: { ses_a: { location: here } } });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "shell", id: "call_1", input: { command: "ls", secret: "x" }, status: "completed" });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "edit", id: "call_2", input: { filePath: "/a" }, status: "error", error: { message: "boom" } });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "read", id: "call_3", input: {}, status: "completed" });
  await h.buddy.flush();
  assert.deepEqual(h.events(), ["SessionStart", "PostToolUse", "PostToolUseFailure", "PostToolUse"]);
  assert.deepEqual(h.sent[1].tool_input, { command: "ls" });
  assert.deepEqual([h.sent[2].tool_input, h.sent[2].error], [{ file_path: "/a" }, "boom"]);
  assert.equal(h.sent[3].tool_name, "Read");
});

test("tool hook: a session whose info has no location uses the event's location", async () => {
  const h = harness();
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_a" } });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "shell", id: "call_1", status: "completed" });
  await h.buddy.flush();
  assert.deepEqual(h.events(), ["SessionStart", "PostToolUse"]);
});

test("a stuck hook drops tool results past the cap, never other events, and a permission does not wait for them", async () => {
  let release;
  const gate = new Promise((r) => { release = r; });
  const h = harness({ fire: (p) => (p.hook_event_name === "PostToolUse" ? gate : ""), answer: () => out({ behavior: "allow" }) });
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_a", location: here } });
  await h.buddy.handle({ type: "session.execution.started", location: here, data: { sessionID: "ses_a" } });
  for (let i = 0; i < 80; i++) await h.buddy.toolDone({ sessionID: "ses_a", tool: "shell", id: `call_${i}`, status: "completed" });
  await h.buddy.handle({ type: "permission.asked", location: here, data: { id: "per_1", sessionID: "ses_a", action: "shell" } });
  assert.deepEqual(h.replies, [{ sessionID: "ses_a", requestID: "per_1", decision: "once" }]);
  // handle resolves when the event is sent: after the backlog.
  const stop = h.buddy.handle({ type: "session.execution.succeeded", location: here, data: { sessionID: "ses_a" } });
  release("");
  await stop;
  await h.buddy.flush();
  assert.equal(h.events().filter((e) => e === "PostToolUse").length, 50);
  assert.equal(h.events().at(-1), "Stop");
});

test("permission: Buddy's answer goes to ctx.permission.reply", async () => {
  const h = harness({ answer: () => out({ behavior: "allow" }) });
  await h.buddy.handle({ type: "permission.asked", location: here, data: { id: "per_1", sessionID: "ses_a", action: "shell", resources: ["ls"] } });
  assert.deepEqual(h.replies, [{ sessionID: "ses_a", requestID: "per_1", decision: "once" }]);
  assert.equal(h.sent[1].hook_event_name, "PermissionRequest");
});

test("permission: answered in OpenCode first stops the hook and sends nothing", async () => {
  const h = harness();
  const asking = h.buddy.handle({ type: "permission.asked", location: here, data: { id: "per_1", sessionID: "ses_a", action: "edit" } });
  await tick();
  await h.buddy.handle({ type: "permission.replied", location: here, data: { sessionID: "ses_a", requestID: "per_1", reply: "once" } });
  await asking;
  assert.deepEqual(h.replies, []);
});

test("permission: settled before Buddy is asked never shows a card", async () => {
  const h = harness();
  await h.buddy.handle({ type: "permission.replied", location: here, data: { sessionID: "ses_a", requestID: "per_9", reply: "once" } });
  await h.buddy.handle({ type: "permission.asked", location: here, data: { id: "per_9", sessionID: "ses_a", action: "edit" } });
  assert.ok(!h.events().includes("PermissionRequest"));
});

test("question: Buddy's answer goes to the form; without a reply route only the state shows", async () => {
  const h = harness({ answer: () => out({ behavior: "allow", updatedInput: { answers: { "Which color?": "Red", "Which checks?": "Lint" } } }) });
  await h.buddy.handle({ type: "form.created", location: here, data: { form: question } });
  assert.deepEqual(h.forms, [["ses_a", "frm_1", { q0: "red", q1: ["b"] }]]);
  assert.equal(h.sent[1].tool_name, "AskUserQuestion");

  const n = harness({ canReplyForm: false });
  await n.buddy.handle({ type: "form.created", location: here, data: { form: question } });
  await n.buddy.handle({ type: "form.replied", location: here, data: { id: "frm_1", sessionID: "ses_a", answer: {} } });
  await n.buddy.flush();
  assert.deepEqual(n.events(), ["SessionStart", "PreToolUse", "PostToolUse"]);
});

test("dispose ends the main sessions only and waits for the SessionEnd it queued", async () => {
  const h = harness({ sessions: { ses_a: { location: here } } });
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_k", parentID: "ses_a", location: here } });
  await h.buddy.dispose();
  assert.deepEqual(h.events(), ["SessionStart", "SubagentStart", "SessionEnd"]);
});

test("dispose skips queued tool results and gives up on a stuck hook", async () => {
  const h = harness({ fire: (p) => (p.hook_event_name === "PostToolUse" ? new Promise(() => {}) : "") });
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_a", location: here } });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "shell", status: "completed" });
  await h.buddy.toolDone({ sessionID: "ses_a", tool: "shell", status: "completed" });
  const start = Date.now();
  await h.buddy.dispose();
  assert.ok(Date.now() - start < 5000);
  assert.deepEqual(h.events(), ["SessionStart", "PostToolUse"]);
});

test("a deleted main session leaves no request, form, or subagent behind", async () => {
  const h = harness({ sessions: { ses_a: { location: here }, ses_k: { parentID: "ses_a", location: here } },
                       canReplyForm: false, answer: () => "" });
  await h.buddy.handle({ type: "session.created", location: here, data: { sessionID: "ses_k", parentID: "ses_a", location: here } });
  await h.buddy.handle({ type: "permission.replied", location: here, data: { sessionID: "ses_a", requestID: "per_9", reply: "once" } });
  await h.buddy.handle({ type: "form.created", location: here, data: { form: question } });
  await h.buddy.handle({ type: "session.deleted", location: here, data: { sessionID: "ses_a" } });
  // The form and the early reply are gone: a late form reply sends no PostToolUse, a request with that id asks.
  await h.buddy.handle({ type: "form.replied", location: here, data: { id: "frm_1", sessionID: "ses_a" } });
  await h.buddy.handle({ type: "permission.asked", location: here, data: { id: "per_9", sessionID: "ses_a", action: "edit" } });
  await h.buddy.flush();
  assert.deepEqual(h.events(), ["SessionStart", "SubagentStart", "PreToolUse", "SessionEnd", "SessionStart", "PermissionRequest"]);
  // The subagent is gone with its main session: its next event starts it again.
  await h.buddy.handle({ type: "session.execution.succeeded", location: here, data: { sessionID: "ses_k" } });
  await h.buddy.flush();
  assert.deepEqual(h.events().slice(6), ["SubagentStart", "SubagentStop"]);
});

test("replyForm: posts to OpenCode's own service only, and a refused answer is false", async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buddy-oc-"));
  const seen = [];
  let status = 200;
  const server = http.createServer((req, res) => { seen.push([req.url, req.headers.authorization]); res.writeHead(status).end(); });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const saved = process.env.XDG_STATE_HOME;
  process.env.XDG_STATE_HOME = dir;
  t.mock.method(console, "warn", () => {});
  try {
    fs.mkdirSync(path.join(dir, "opencode"));
    const write = (pid) => fs.writeFileSync(path.join(dir, "opencode", "service.json"),
      JSON.stringify({ pid, url: `http://127.0.0.1:${server.address().port}`, password: "pw" }));
    write(process.pid);
    assert.equal(await replyForm("ses_a", "frm_1", { q0: "red" }), true);
    assert.deepEqual(seen[0], ["/api/session/ses_a/form/frm_1/reply", "Basic " + Buffer.from("opencode:pw").toString("base64")]);
    status = 500;
    assert.equal(await replyForm("ses_a", "frm_1", {}), false);
    write(process.pid + 1);
    assert.equal(await replyForm("ses_a", "frm_1", {}), false);
    assert.equal(seen.length, 2);
  } finally {
    if (saved === undefined) delete process.env.XDG_STATE_HOME; else process.env.XDG_STATE_HOME = saved;
    server.close();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("runHook: env marker and pid, stdout in wait mode, fail open on a missing binary", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buddy-oc-"));
  const bin = path.join(dir, "hook.sh");
  fs.writeFileSync(bin, '#!/bin/sh\nread line\nprintf \'%s|%s|%s\' "$BUDDY_AGENT" "$CLAUDE_PID" "$line"\n', { mode: 0o755 });
  try {
    assert.equal(await runHook(bin, { a: 1 }, { wait: true }), `opencode|${process.pid}|{"a":1}`);
    assert.equal(await runHook(bin, { a: 1 }), "");
    assert.equal(await runHook(path.join(dir, "missing"), {}, { wait: true }), "");
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("runHook: abort and timeout stop a hook that never answers", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "buddy-oc-"));
  const bin = path.join(dir, "slow.sh");
  fs.writeFileSync(bin, "#!/bin/sh\nexec sleep 30\n", { mode: 0o755 });
  try {
    const start = Date.now();
    const ac = new AbortController();
    const waiting = runHook(bin, {}, { wait: true, signal: ac.signal });
    setTimeout(() => ac.abort(), 50);
    assert.equal(await waiting, "");
    assert.equal(await runHook(bin, {}, { wait: true, timeoutMs: 50 }), "");
    assert.ok(Date.now() - start < 5000);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("setup subscribes to events and registers the tool hook", async () => {
  let hooked;
  const ctx = {
    location: here,
    session: { get: async () => ({ location: here }) },
    permission: { reply: async () => {} },
    tool: { hook: async (name) => { hooked = name; return { dispose: async () => {} }; } },
    event: { subscribe: ({ signal }) => ({ async *[Symbol.asyncIterator]() { await new Promise((r) => signal.addEventListener("abort", r)); } }) },
  };
  assert.equal(plugin.id, "buddy");
  const dispose = await plugin.setup(ctx);
  assert.equal(hooked, "execute.after");
  await dispose();
});
