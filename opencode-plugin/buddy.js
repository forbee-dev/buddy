// buddy:opencode-plugin. Buddy.app writes this file and removes it on uninstall. Local edits are lost.
// Contract: OpenCode 2 plugin API, default export { id, setup }.
// It turns OpenCode events into Claude Code style hook payloads for buddy-hook. It never blocks OpenCode:
// any error, a missing Buddy, or an empty answer means "do nothing", and OpenCode's own prompt stays.
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const HOOK = "__BUDDY_HOOK_PATH__";
const FIRE_MS = 5_000;
// The same backstop as Claude Code's PermissionRequest hook.
const WAIT_MS = 3_600_000;
const MAX_OUT = 256 * 1024;
const MAX_TEXT = 16_000;
// A stuck buddy-hook must not grow the queue without end; tool results are the only events Buddy can miss.
const MAX_PENDING = 50;
// dispose waits this long for the last SessionEnd events.
const FLUSH_MS = 2_000;
// Buddy's card uses Claude Code tool names for its read-only accent.
const TOOL_NAMES = new Map([["read", "Read"], ["glob", "Glob"], ["grep", "Grep"], ["list", "LS"], ["webfetch", "WebFetch"],
                            ["websearch", "WebSearch"], ["todowrite", "TodoWrite"]]);
const toolName = (t) => TOOL_NAMES.get(t) ?? t;

const isId = (v) => typeof v === "string" && v.length > 0 && v.length <= 200;
const str = (v) => (typeof v === "string" && v ? v : undefined);
const obj = (v) => (v && typeof v === "object" && !Array.isArray(v) ? v : undefined);

/** Runs buddy-hook with `payload` on stdin. Resolves to its stdout ("" on any error). Never rejects. */
export function runHook(hook, payload, { wait = false, signal, timeoutMs = wait ? WAIT_MS : FIRE_MS, spawnFn = spawn } = {}) {
  return new Promise((resolve) => {
    let out = "", done = false, child, timer;
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", stop);
      resolve(out);
    };
    function stop() {
      try { child?.kill("SIGTERM"); } catch {}
      finish();
    }
    if (signal?.aborted) return finish();
    try {
      child = spawnFn(hook, [], {
        stdio: ["pipe", wait ? "pipe" : "ignore", "ignore"],
        env: { ...process.env, CLAUDE_PID: String(process.pid), BUDDY_AGENT: "opencode" },
        windowsHide: true,
      });
    } catch { return finish(); }
    timer = setTimeout(stop, timeoutMs);
    timer.unref?.();
    signal?.addEventListener("abort", stop, { once: true });
    child.on("error", finish);
    child.on("close", finish);
    child.stdout?.on("data", (d) => {
      out += d;
      if (out.length > MAX_OUT) { out = ""; stop(); }
    });
    child.stdin?.on("error", () => {});
    child.stdin?.end(JSON.stringify(payload));
  });
}

/** Buddy's PermissionRequest decision, or undefined when the output is empty or has another shape. */
export function decisionOf(out) {
  if (typeof out !== "string" || !out.trim() || out.length > MAX_OUT) return;
  let v;
  try { v = JSON.parse(out); } catch { return; }
  const hso = obj(obj(v)?.hookSpecificOutput);
  const d = obj(hso?.decision);
  if (hso?.hookEventName !== "PermissionRequest" || !d) return;
  return d.behavior === "allow" || d.behavior === "deny" ? d : undefined;
}

/** The body for `ctx.permission.reply`, without the ids. "always" only when Buddy returns a rule that `request` offered. */
export function permissionReply(out, request = {}) {
  const d = decisionOf(out);
  if (!d) return;
  if (d.behavior === "deny") return { decision: "reject", ...(str(d.message) ? { message: d.message.slice(0, 2000) } : {}) };
  const offered = Array.isArray(request.save) ? request.save : [];
  const rules = (Array.isArray(d.updatedPermissions) ? d.updatedPermissions : []).flatMap((u) => (Array.isArray(u?.rules) ? u.rules : []));
  const saves = rules.some((r) => r?.toolName === request.action && typeof r.ruleContent === "string" && offered.includes(r.ruleContent));
  return { decision: saves ? "always" : "once" };
}

/** `permission.asked` data as a Claude Code PermissionRequest. "Always allow" is offered only when OpenCode can save a rule. */
export function permissionPayload(p) {
  const meta = obj(p.metadata) ?? {};
  const resources = Array.isArray(p.resources) ? p.resources.filter((r) => typeof r === "string") : [];
  const save = Array.isArray(p.save) ? p.save.filter((r) => typeof r === "string") : [];
  return {
    hook_event_name: "PermissionRequest",
    tool_name: toolName(p.action),
    tool_use_id: p.id,
    tool_input: { ...meta, ...(resources.length ? { resources } : {}), ...(str(p.message) ? { description: p.message } : {}) },
    ...(save.length ? {
      permission_suggestions: [{ type: "addRules", behavior: "allow", destination: "session",
                                 rules: save.map((s) => ({ toolName: p.action, ruleContent: s })) }],
    } : {}),
  };
}

/** A question form (OpenCode's question tool) as AskUserQuestion input; undefined for other forms. */
export function questionInput(form) {
  if (obj(form?.metadata)?.kind !== "question" || !Array.isArray(form.fields) || form.fields.length === 0) return;
  const questions = [];
  for (const f of form.fields) {
    if (!isId(f?.key) || (f.type !== "string" && f.type !== "multiselect")) return;
    const options = (Array.isArray(f.options) ? f.options : []).filter((o) => typeof o?.label === "string")
      .map((o) => ({ label: o.label, ...(str(o.description) ? { description: o.description } : {}) }));
    questions.push({ question: str(f.description) ?? str(f.title) ?? f.key, ...(str(f.title) ? { header: f.title } : {}),
                     options, multiSelect: f.type === "multiselect" });
  }
  return { questions };
}

const valueOf = (label, options) => options.find((o) => o?.label === label)?.value ?? label;

/** Buddy joins multiple picks with ", ". Option labels may hold ", " too, so the longest label matches first; the rest is custom text. */
export function splitPicks(text, options) {
  const labels = options.map((o) => o?.label).filter((l) => typeof l === "string" && l).sort((a, b) => b.length - a.length);
  const out = [];
  let rest = text;
  while (rest) {
    const hit = labels.find((l) => rest === l || rest.startsWith(l + ", "));
    if (!hit) { out.push(rest); break; }
    out.push(valueOf(hit, options));
    rest = rest.slice(hit.length + 2);
  }
  return out;
}

/** The form answer (`{ [field.key]: value }`) from Buddy's output; undefined unless every question has a string answer. */
export function formAnswer(form, out) {
  const input = questionInput(form);
  const d = decisionOf(out);
  const answers = d?.behavior === "allow" ? obj(obj(d.updatedInput)?.answers) : undefined;
  if (!input || !answers) return;
  const answer = {};
  for (const [i, f] of form.fields.entries()) {
    const text = answers[input.questions[i].question];
    if (typeof text !== "string" || !text || text.length > MAX_TEXT) return;
    const options = Array.isArray(f.options) ? f.options : [];
    answer[f.key] = f.type === "multiselect" ? splitPicks(text, options) : valueOf(text, options);
  }
  return answer;
}

function sameLocation(a, b) {
  return !!a && !!b && a.directory === b.directory && (a.workspaceID ?? undefined) === (b.workspaceID ?? undefined);
}

/**
 * The event logic, apart from the OpenCode context so tests can drive it.
 * `getSession(id)` resolves to session info ({ parentID, location }); `replyPermission`, `replyForm(sessionID, formID, answer)`
 * and `canReplyForm()` talk to OpenCode.
 */
export function createBuddy({ hook = HOOK, run = runHook, location, getSession, replyPermission, replyForm, canReplyForm }) {
  const cwd = location?.directory;
  const info = new Map();
  const started = new Set();
  // Subagent session id -> its main session id.
  const agents = new Map();
  const lastText = new Map();
  // Request id -> { ac, main }. `ac` is null after Buddy's answer, until OpenCode reports the request settled.
  const waiting = new Map();
  // Form id -> main session id.
  const cardless = new Map();
  // Requests that OpenCode settled before Buddy was asked: request id -> main session id.
  const early = new Map();
  let queue = Promise.resolve(), kept = queue, pending = 0, closing = false;

  // One at a time, in order: two buddy-hook processes could reach Buddy out of order. `optional` events (tool results)
  // are dropped on a backlog and skipped after dispose.
  const send = (payload, optional = false) => {
    if (optional && (closing || pending >= MAX_PENDING)) return queue;
    pending++;
    queue = queue.then(() => (optional && closing ? "" : run(hook, { cwd, ...payload }))).catch(() => {}).then(() => { pending--; });
    if (!optional) kept = queue;
    return queue;
  };

  /** `evLocation` stands in when the session info has no location. */
  function lookup(sid, created, evLocation) {
    if (!info.has(sid)) {
      const p = created ? Promise.resolve(created) : Promise.resolve().then(() => getSession?.(sid)).catch(() => undefined);
      info.set(sid, p.then((s) => {
        // A failed lookup is tried again on the next event.
        if (!s) info.delete(sid);
        return { parent: isId(s?.parentID) ? s.parentID : undefined, location: s?.location ?? evLocation };
      }));
    }
    return info.get(sid);
  }

  /** The main session and, for a subagent session, its id; undefined when the session belongs to another location. */
  async function route(sid, evLocation, created) {
    const first = await lookup(sid, created, evLocation);
    if (!sameLocation(evLocation ?? first.location, location)) return;
    let main = sid, agent, cur = first;
    for (let depth = 0; cur.parent && depth < 8; depth++) {
      agent = sid;
      main = cur.parent;
      cur = await lookup(main);
    }
    if (!started.has(main)) { started.add(main); send({ hook_event_name: "SessionStart", session_id: main, source: "startup" }); }
    if (agent && !agents.has(agent)) {
      agents.set(agent, main);
      send({ hook_event_name: "SubagentStart", session_id: main, agent_id: agent, agent_type: str(created?.agent) ?? "subagent" });
    }
    return { main, agent };
  }

  /**
   * PermissionRequest: waits for Buddy outside the queue, so other events keep flowing. It goes after the last event
   * that changes the session state, never behind a backlog of tool results.
   */
  async function ask(id, main, payload, apply) {
    if (waiting.has(id) || early.delete(id)) return;
    const ac = new AbortController();
    waiting.set(id, { ac, main });
    await kept;
    const out = await run(hook, { cwd, ...payload }, { wait: true, signal: ac.signal });
    // OpenCode answered first: the request is gone.
    if (waiting.get(id)?.ac !== ac) return;
    waiting.set(id, { ac: null, main });
    try { await apply(out); } catch {}
  }

  /** OpenCode answered (in its own UI, or Buddy's answer): stopping buddy-hook closes Buddy's card. */
  function settled(id, main) {
    const w = waiting.get(id);
    if (!w) {
      if (early.size > 100) early.clear();
      return void early.set(id, main);
    }
    w.ac?.abort();
    waiting.delete(id);
  }

  async function handle(event) {
    const type = event?.type, data = obj(event?.data);
    if (typeof type !== "string" || !data) return;
    const form = type === "form.created" ? obj(data.form) : undefined;
    const sid = form ? form.sessionID : data.sessionID;
    if (!isId(sid)) return;
    if (type === "session.deleted") return forget(sid);
    const r = await route(sid, obj(event.location), type === "session.created" ? data : undefined);
    if (!r) return;
    const base = { session_id: r.main, ...(r.agent ? { agent_id: r.agent } : {}) };
    switch (type) {
      case "session.execution.started":
        if (!r.agent) send({ ...base, hook_event_name: "UserPromptSubmit" });
        return;
      case "session.text.ended":
        if (typeof data.text === "string" && data.text.trim()) lastText.set(sid, data.text.slice(-MAX_TEXT));
        return;
      case "session.execution.succeeded":
      case "session.execution.interrupted":
      case "session.execution.failed": {
        const message = lastText.get(sid);
        lastText.delete(sid);
        if (type === "session.execution.interrupted" && data.reason === "shutdown") return;
        if (r.agent) return send({ ...base, hook_event_name: "SubagentStop", ...(message ? { last_assistant_message: message } : {}) });
        if (type === "session.execution.failed") {
          return send({ ...base, hook_event_name: "StopFailure", error: str(obj(data.error)?.message) ?? "OpenCode error" });
        }
        return send({ ...base, hook_event_name: "Stop", ...(message ? { last_assistant_message: message } : {}) });
      }
      case "session.compaction.started":
        if (!r.agent) send({ ...base, hook_event_name: "PreCompact", trigger: data.reason === "manual" ? "manual" : "auto" });
        return;
      case "session.compaction.ended":
        if (!r.agent) send({ ...base, hook_event_name: "PostCompact" });
        return;
      case "permission.asked":
        if (!isId(data.id) || typeof data.action !== "string") return;
        return ask(data.id, r.main, { ...base, ...permissionPayload(data) }, (out) => {
          const reply = permissionReply(out, data);
          return reply && replyPermission({ sessionID: sid, requestID: data.id, ...reply });
        });
      case "permission.replied":
        return settled(data.requestID, r.main);
      case "form.created": {
        const input = questionInput(form);
        if (!input || !isId(form.id)) return;
        const tool = { ...base, tool_name: "AskUserQuestion", tool_use_id: form.id, tool_input: input };
        // Without a way to answer, Buddy shows the question state with no card.
        if (!(await canReplyForm?.())) {
          cardless.set(form.id, r.main);
          return send({ ...tool, hook_event_name: "PreToolUse" });
        }
        return ask(form.id, r.main, { ...tool, hook_event_name: "PermissionRequest" }, (out) => {
          const answer = formAnswer(form, out);
          return answer && replyForm(sid, form.id, answer);
        });
      }
      case "form.replied":
      case "form.cancelled":
        if (cardless.delete(data.id)) return send({ ...base, hook_event_name: "PostToolUse", tool_name: "AskUserQuestion", tool_use_id: data.id });
        return settled(data.id, r.main);
    }
  }

  /** `tool` hook `execute.after`. */
  async function toolDone(e) {
    if (!isId(e?.sessionID) || typeof e.tool !== "string") return;
    const r = await route(e.sessionID);
    if (!r) return;
    const input = obj(e.input) ?? {};
    const keep = { command: str(input.command), file_path: str(input.filePath) ?? str(input.file_path), url: str(input.url) };
    const failed = e.status === "error";
    send({
      session_id: r.main, ...(r.agent ? { agent_id: r.agent } : {}),
      hook_event_name: failed ? "PostToolUseFailure" : "PostToolUse",
      tool_name: toolName(e.tool), ...(isId(e.id) ? { tool_use_id: e.id } : {}),
      tool_input: Object.fromEntries(Object.entries(keep).filter(([, v]) => v !== undefined)),
      ...(failed ? { error: str(e.error?.message) ?? "Tool failed" } : {}),
    }, true);
  }

  function forget(sid) {
    const main = agents.get(sid);
    info.delete(sid);
    lastText.delete(sid);
    if (main) {
      agents.delete(sid);
      send({ hook_event_name: "SubagentStop", session_id: main, agent_id: sid });
      return;
    }
    if (started.delete(sid)) send({ hook_event_name: "SessionEnd", session_id: sid, reason: "other" });
    for (const [agent, m] of agents) {
      if (m === sid) { agents.delete(agent); info.delete(agent); lastText.delete(agent); }
    }
    for (const [id, w] of waiting) {
      if (w.main === sid) { w.ac?.abort(); waiting.delete(id); }
    }
    for (const owners of [cardless, early]) {
      for (const [id, m] of owners) if (m === sid) owners.delete(id);
    }
  }

  /** Sends SessionEnd for the main sessions; resolves when they are sent, or after FLUSH_MS. */
  function dispose() {
    closing = true;
    for (const sid of [...started]) forget(sid);
    for (const w of waiting.values()) w.ac?.abort();
    for (const m of [waiting, cardless, early, agents, info, lastText]) m.clear();
    return Promise.race([queue, new Promise((r) => setTimeout(r, FLUSH_MS))]);
  }

  return { handle, toolDone, dispose, flush: () => queue };
}

/**
 * OpenCode's background service (`opencode serve --service`) writes its URL and password to service.json. The plugin
 * API has no form reply, so the answer goes through that local HTTP API, only when this process is that service.
 * shortcut: only the default channel's file name; other channels and `--standalone` keep answering in the TUI.
 */
async function serviceAPI() {
  try {
    const dir = join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "opencode");
    const s = JSON.parse(await readFile(join(dir, "service.json"), "utf8"));
    if (s?.pid !== process.pid || typeof s.url !== "string" || typeof s.password !== "string") return;
    const url = new URL(s.url);
    if (url.protocol !== "http:" || !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)) return;
    return { url, auth: "Basic " + Buffer.from("opencode:" + s.password).toString("base64") };
  } catch { return; }
}

/** Resolves to false when OpenCode did not take the answer; its own form then stays. Never logs the URL or password. */
export async function replyForm(sessionID, formID, answer) {
  const api = await serviceAPI();
  if (!api) return false;
  const path = `/api/session/${encodeURIComponent(sessionID)}/form/${encodeURIComponent(formID)}/reply`;
  try {
    const res = await fetch(new URL(path, api.url), {
      method: "POST",
      headers: { authorization: api.auth, "content-type": "application/json" },
      body: JSON.stringify({ answer }),
      signal: AbortSignal.timeout(5_000),
    });
    if (res.ok) return true;
    console.warn(`buddy: OpenCode refused the form answer (HTTP ${res.status})`);
  } catch (e) {
    console.warn(`buddy: OpenCode form answer failed (${e?.name ?? "error"})`);
  }
  return false;
}

export default {
  id: "buddy",
  async setup(ctx) {
    const buddy = createBuddy({
      location: ctx.location,
      getSession: (sessionID) => ctx.session.get({ sessionID }),
      replyPermission: (input) => ctx.permission.reply(input),
      replyForm,
      canReplyForm: async () => (await serviceAPI()) !== undefined,
    });
    const controller = new AbortController();
    (async () => {
      for await (const event of ctx.event.subscribe({ signal: controller.signal })) buddy.handle(event).catch(() => {});
    })().catch(() => {});
    await ctx.tool.hook("execute.after", (event) => { buddy.toolDone(event).catch(() => {}); });
    return () => {
      controller.abort();
      return buddy.dispose();
    };
  },
};
