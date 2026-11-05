export const MAX_LINE_BYTES = 1024 * 1024;
export const MAX_TEXT_BYTES = 32 * 1024;

export interface TerminalLike {
  sendText(text: string, addNewLine?: boolean): void;
  show(preserveFocus?: boolean): void;
}

export type Finder = (shellPid: number) => TerminalLike | undefined;
/** Resolves to the ack error when typing is unsafe, undefined when claude waits in the foreground. */
export type ClaudeCheck = (shellPid: number) => Promise<string | undefined>;

/** Keeps tab and newline (CR and CRLF become LF). Drops other C0, DEL, and C1 controls, so no ESC can end the paste early. */
export const sanitize = (t: string): string => t.replace(/\r\n?/g, "\n").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "");

/** Bracketed paste: Claude Code's TUI takes the text as one multi-line input, not one submit per line. */
export const PASTE_START = "\x1b[200~";
export const PASTE_END = "\x1b[201~";
export const framed = (t: string): string => PASTE_START + t + PASTE_END;

export interface Handled {
  ack?: Record<string, unknown>;
  log?: string;
}

/** Splits a byte stream into lines. Oversize lines are dropped and reported once. */
export class LineFramer {
  private buf: Buffer = Buffer.alloc(0);
  private discarding = false;

  push(chunk: Buffer, onOversize: () => void): Buffer[] {
    const out: Buffer[] = [];
    let data = chunk;
    for (;;) {
      const nl = data.indexOf(0x0a);
      if (nl < 0) {
        if (!this.discarding) {
          this.buf = Buffer.concat([this.buf, data]);
          if (this.buf.length > MAX_LINE_BYTES) {
            this.buf = Buffer.alloc(0);
            this.discarding = true;
            onOversize();
          }
        }
        return out;
      }
      const head = data.subarray(0, nl);
      data = data.subarray(nl + 1);
      if (this.discarding) {
        this.discarding = false;
        continue;
      }
      const line = Buffer.concat([this.buf, head]);
      this.buf = Buffer.alloc(0);
      if (line.length > MAX_LINE_BYTES) {
        onOversize();
        continue;
      }
      if (line.length > 0) out.push(line);
    }
  }
}

const ackErr = (reqId: string, error: string) => ({ kind: "ack", reqId, ok: false, error });

export async function handleLine(line: string, find: Finder, claudeBlocked: ClaudeCheck): Promise<Handled> {
  let msg: unknown;
  try {
    msg = JSON.parse(line);
  } catch {
    return { log: "bad json ignored" };
  }
  if (typeof msg !== "object" || msg === null || Array.isArray(msg)) {
    return { log: "non-object message ignored" };
  }
  const m = msg as Record<string, unknown>;
  if (m.kind !== "send" && m.kind !== "focus") return {}; // unknown kinds are ignored
  if (typeof m.reqId !== "string" || m.reqId.length === 0) {
    return { log: `bad ${m.kind} request: reqId` };
  }
  const reqId = m.reqId;
  const pid = m.shellPid;
  if (typeof pid !== "number" || !Number.isInteger(pid)) {
    return { ack: ackErr(reqId, "bad-request"), log: `bad request reqId=${reqId}: shellPid` };
  }
  if (m.kind === "send") {
    const { text, submit } = m;
    if (typeof text !== "string") {
      return { ack: ackErr(reqId, "bad-request"), log: `bad send reqId=${reqId}: text` };
    }
    if (Buffer.byteLength(text) > MAX_TEXT_BYTES) {
      return { ack: ackErr(reqId, "too-long"), log: `bad send reqId=${reqId}: too-long` };
    }
    if (submit !== undefined && typeof submit !== "boolean") {
      return { ack: ackErr(reqId, "bad-request"), log: `bad send reqId=${reqId}: submit` };
    }
    const term = find(pid);
    if (!term) return { ack: ackErr(reqId, "no-terminal"), log: `send reqId=${reqId} shellPid=${pid}: no-terminal` };
    const why = await claudeBlocked(pid);
    if (why) return { ack: ackErr(reqId, why), log: `send reqId=${reqId} shellPid=${pid}: ${why}` };
    const clean = sanitize(text);
    term.sendText(framed(clean), false);
    // Enter goes separately, after the paste has ended.
    if (submit ?? true) term.sendText("", true);
    return { ack: { kind: "ack", reqId, ok: true }, log: `send reqId=${reqId} shellPid=${pid} len=${clean.length}` };
  }
  const term = find(pid);
  if (!term) return { ack: ackErr(reqId, "no-terminal"), log: `focus reqId=${reqId} shellPid=${pid}: no-terminal` };
  term.show(false);
  return { ack: { kind: "ack", reqId, ok: true }, log: `focus reqId=${reqId} shellPid=${pid}` };
}
