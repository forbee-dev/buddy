import * as net from "net";
import { LineFramer } from "./protocol";

export interface ClientOptions {
  socketPath: string;
  hello: () => Promise<object>;
  onLine: (line: string) => object | undefined | Promise<object | undefined>;
  log: (msg: string) => void;
  /** Returns a failure reason to block the connection attempt. */
  precheck?: () => string | undefined;
  onState?: (connected: boolean) => void;
  minDelayMs?: number;
  maxDelayMs?: number;
  logThrottleMs?: number;
}

export class BuddyClient {
  private sock?: net.Socket;
  private timer?: NodeJS.Timeout;
  private delay: number;
  private stopped = false;
  private helloSent = false;
  private queue: object[] = [];
  private readonly lastQuietLog = new Map<string, number>();
  private readonly min: number;
  private readonly max: number;

  constructor(private readonly o: ClientOptions) {
    this.min = o.minDelayMs ?? 1000;
    this.max = o.maxDelayMs ?? 30000;
    this.delay = this.min;
  }

  start(): void {
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    this.sock?.destroy();
  }

  send(obj: object): void {
    if (!this.sock || this.sock.destroyed || !this.sock.writable) return;
    if (!this.helloSent) {
      this.queue.push(obj);
      return;
    }
    this.write(obj);
  }

  private write(obj: object): void {
    this.sock?.write(JSON.stringify(obj) + "\n");
  }

  private quietLog(key: string, msg: string): void {
    const now = Date.now();
    if (now - (this.lastQuietLog.get(key) ?? -Infinity) >= (this.o.logThrottleMs ?? 60000)) {
      this.lastQuietLog.set(key, now);
      this.o.log(msg);
    }
  }

  private connect(): void {
    if (this.stopped) return;
    const bad = this.o.precheck?.();
    if (bad) {
      this.quietLog("untrusted", `socket untrusted, not connecting: ${bad}`);
      this.schedule();
      return;
    }
    const sock = net.createConnection(this.o.socketPath);
    this.sock = sock;
    this.helloSent = false;
    this.queue = []; // hello carries the full terminal list
    const framer = new LineFramer();
    let chain: Promise<void> = Promise.resolve(); // replies must keep request order
    let opened = false;
    let closed = false;

    sock.on("connect", () => {
      opened = true;
      this.delay = this.min;
      this.o.onState?.(true);
      this.o.log("connected");
      this.o.hello().then(
        (h) => {
          if (this.sock !== sock || sock.destroyed) return;
          this.write(h);
          this.helloSent = true;
          // Queued items predate hello's snapshot; flush anyway to keep order simple.
          const q = this.queue;
          this.queue = [];
          q.forEach((x) => this.write(x));
        },
        (e) => {
          this.o.log(`hello failed: ${String(e)}`);
          sock.destroy();
        },
      );
    });
    sock.on("data", (chunk) => {
      const lines = framer.push(chunk, () => this.o.log("oversize line dropped"));
      for (const l of lines) {
        chain = chain
          .then(() => this.o.onLine(l.toString("utf8")))
          .then((reply) => reply && this.send(reply))
          .catch((e) => this.o.log(`handler error: ${String(e)}`));
      }
    });
    sock.on("error", (e) => {
      if (!opened) this.quietLog("unreachable", `Buddy not reachable (${(e as NodeJS.ErrnoException).code ?? e})`);
      else this.o.log(`socket error: ${String(e)}`);
    });
    sock.on("close", () => {
      if (closed) return;
      closed = true;
      if (opened) {
        this.o.onState?.(false);
        this.o.log("disconnected");
      }
      if (this.stopped) return;
      this.schedule();
    });
  }

  private schedule(): void {
    this.timer = setTimeout(() => this.connect(), this.delay);
    this.delay = Math.min(this.delay * 2, this.max);
  }
}
