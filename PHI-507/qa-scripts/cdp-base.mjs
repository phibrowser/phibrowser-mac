#!/usr/bin/env node
// Capture a JPEG (or, with --png, a PNG) of the first page target of the
// lane's browser over the Chrome DevTools Protocol and print it base64-encoded
// on stdout. Runs as the lane user with the lane's Node 22 (no dependencies):
//   ~/.local/bin/node ~/.e2e-lane/bin/cdp-shot.mjs socket [--png]
//   ~/.local/bin/node ~/.e2e-lane/bin/cdp-shot.mjs <port> [--png]
// `socket` talks to Phi Canary's own CDP endpoint: the Unix socket named in
// ~/Library/Application Support/com.phibrowser.canary.Mac/CDPAgentSocket
// (docs/phi_cdp.md in phi-ai). Canary 154 does not open --remote-debugging-port
// for its default profile, so this is the mode that works with Phi Canary; the
// first connection from a client waits for Canary's agent-permission dialog,
// which a lane's golden copy has already answered with Always Allow
// (lane-grant-cdp.sh). <port> talks to 127.0.0.1:<port> for browsers that do
// open a TCP debugging port. The pool's thumbnails use the JPEG default;
// agents use --png for evidence.
// Exit codes: 0 image printed; 2 no browser endpoint (Canary not running,
// nothing on the port) or no page target; 1 any other error (bad argument,
// CDP error, timeout including an unanswered permission dialog).
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import net from "node:net";
import os from "node:os";

const TIMEOUT_MS = 20000;
const POINTER = `${os.homedir()}/Library/Application Support/com.phibrowser.canary.Mac/CDPAgentSocket`;

class NoTarget extends Error {}

// Set the exit code instead of calling process.exit so that pending writes
// to piped stdout/stderr (asynchronous on macOS) are flushed.
function fail(code, msg) {
  process.stderr.write(`cdp-shot: ${msg}\n`);
  process.exitCode = code;
}

// --- TCP mode -------------------------------------------------------------------

function refused(err) {
  for (let e = err; e; e = e.cause) {
    if (e.code === "ECONNREFUSED") return true;
    if (Array.isArray(e.errors) && e.errors.some((x) => x?.code === "ECONNREFUSED")) return true;
  }
  return false;
}

async function firstPage(port) {
  let res;
  try {
    res = await fetch(`http://127.0.0.1:${port}/json`, { signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (err) {
    if (refused(err)) throw new NoTarget(`nothing listens on 127.0.0.1:${port}`);
    throw err;
  }
  if (!res.ok) throw new Error(`GET /json: HTTP ${res.status}`);
  const targets = await res.json();
  const page = Array.isArray(targets) ? targets.find((t) => t?.type === "page" && t.webSocketDebuggerUrl) : undefined;
  if (!page) throw new NoTarget(`no page target on 127.0.0.1:${port}`);
  return page.webSocketDebuggerUrl;
}

function captureTCP(wsUrl, params) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error("timeout waiting for Page.captureScreenshot"));
    }, TIMEOUT_MS);
    const done = (fn, v) => {
      clearTimeout(timer);
      ws.close();
      fn(v);
    };
    ws.addEventListener("open", () => {
      ws.send(JSON.stringify({ id: 1, method: "Page.captureScreenshot", params }));
    });
    ws.addEventListener("message", (ev) => {
      let msg;
      try {
        msg = JSON.parse(String(ev.data));
      } catch {
        return;
      }
      if (msg.id !== 1) return;
      if (msg.error) done(reject, new Error(`Page.captureScreenshot: ${msg.error.message ?? JSON.stringify(msg.error)}`));
      else if (typeof msg.result?.data === "string") done(resolve, msg.result.data);
      else done(reject, new Error("Page.captureScreenshot: no data"));
    });
    ws.addEventListener("error", () => done(reject, new Error(`websocket error on ${wsUrl}`)));
  });
}

// --- Phi CDP agent socket mode --------------------------------------------------

function agentSocketPath() {
  try {
    const p = fs.readFileSync(POINTER, "utf8").trim();
    if (p !== "") return p;
  } catch {
    // fall through
  }
  throw new NoTarget(`no ${POINTER}: Phi Canary is not running in this lane`);
}

function socketGone(err) {
  return err?.code === "ENOENT" || err?.code === "ECONNREFUSED";
}

// Phi peeks at the request head for X-Phi-Agent-Pid, so it sits right after Host.
function getJSON(socketPath, path) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { socketPath, path, headers: { Host: "localhost", "X-Phi-Agent-Pid": String(process.pid) }, timeout: TIMEOUT_MS },
      (res) => {
        let body = "";
        res.setEncoding("utf8");
        res.on("data", (c) => (body += c));
        res.on("end", () => {
          if (res.statusCode !== 200) return reject(new Error(`GET ${path}: HTTP ${res.statusCode}`));
          try {
            resolve(JSON.parse(body));
          } catch (err) {
            reject(err);
          }
        });
      },
    );
    req.on("timeout", () => req.destroy(new Error(`GET ${path}: timeout (agent-permission dialog not answered?)`)));
    req.on("error", (err) => reject(socketGone(err) ? new NoTarget(`CDP socket not reachable (${err.code})`) : err));
    req.end();
  });
}

// A minimal RFC 6455 client over the already-connected Unix socket: masked
// text frames out; text, close and ping frames in (with continuation).
class SocketWS {
  constructor(sock, rest) {
    this.sock = sock;
    this.buf = rest;
    this.parts = [];
    this.onmessage = () => {};
    this.onclose = () => {};
    sock.on("data", (d) => {
      this.buf = Buffer.concat([this.buf, d]);
      this.drain();
    });
    sock.on("close", () => this.onclose());
    this.drain();
  }

  static connect(socketPath, path) {
    return new Promise((resolve, reject) => {
      const sock = net.createConnection(socketPath);
      const key = crypto.randomBytes(16).toString("base64");
      let head = Buffer.alloc(0);
      const timer = setTimeout(() => {
        sock.destroy();
        reject(new Error("websocket upgrade timeout"));
      }, TIMEOUT_MS);
      sock.once("error", (err) => {
        clearTimeout(timer);
        reject(socketGone(err) ? new NoTarget(`CDP socket not reachable (${err.code})`) : err);
      });
      sock.on("connect", () => {
        sock.write(
          `GET ${path} HTTP/1.1\r\nHost: localhost\r\nX-Phi-Agent-Pid: ${process.pid}\r\n` +
            `Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
        );
      });
      const onData = (d) => {
        head = Buffer.concat([head, d]);
        const end = head.indexOf("\r\n\r\n");
        if (end < 0) return;
        clearTimeout(timer);
        sock.off("data", onData);
        const status = head.subarray(0, end).toString("latin1").split("\r\n")[0];
        if (!/^HTTP\/1\.1 101/.test(status)) {
          sock.destroy();
          reject(new Error(`websocket upgrade refused: ${status}`));
          return;
        }
        resolve(new SocketWS(sock, head.subarray(end + 4)));
      };
      sock.on("data", onData);
    });
  }

  drain() {
    for (;;) {
      if (this.buf.length < 2) return;
      const fin = (this.buf[0] & 0x80) !== 0;
      const op = this.buf[0] & 0x0f;
      const masked = (this.buf[1] & 0x80) !== 0;
      let len = this.buf[1] & 0x7f;
      let off = 2;
      if (len === 126) {
        if (this.buf.length < 4) return;
        len = this.buf.readUInt16BE(2);
        off = 4;
      } else if (len === 127) {
        if (this.buf.length < 10) return;
        len = Number(this.buf.readBigUInt64BE(2));
        off = 10;
      }
      const maskOff = off;
      if (masked) off += 4;
      if (this.buf.length < off + len) return;
      let payload = this.buf.subarray(off, off + len);
      if (masked) {
        const m = this.buf.subarray(maskOff, maskOff + 4);
        payload = Buffer.from(payload.map((b, i) => b ^ m[i % 4]));
      }
      this.buf = this.buf.subarray(off + len);
      if (op === 0x8) {
        this.sock.end();
        return;
      }
      if (op === 0x9) {
        this.frame(0xa, payload);
        continue;
      }
      if (op === 0x1 || op === 0x0) {
        this.parts.push(payload);
        if (fin) {
          const text = Buffer.concat(this.parts).toString("utf8");
          this.parts = [];
          this.onmessage(text);
        }
      }
    }
  }

  frame(op, payload) {
    const mask = crypto.randomBytes(4);
    const n = payload.length;
    const head = n < 126 ? Buffer.from([0x80 | op, 0x80 | n]) : n < 65536 ? Buffer.alloc(4) : Buffer.alloc(10);
    if (n >= 126 && n < 65536) {
      head[0] = 0x80 | op;
      head[1] = 0x80 | 126;
      head.writeUInt16BE(n, 2);
    } else if (n >= 65536) {
      head[0] = 0x80 | op;
      head[1] = 0x80 | 127;
      head.writeBigUInt64BE(BigInt(n), 2);
    }
    const body = Buffer.from(payload.map((b, i) => b ^ mask[i % 4]));
    this.sock.write(Buffer.concat([head, mask, body]));
  }

  send(text) {
    this.frame(0x1, Buffer.from(text, "utf8"));
  }

  close() {
    try {
      this.frame(0x8, Buffer.alloc(0));
    } catch {
      // socket already gone
    }
    this.sock.destroy();
  }
}

async function captureSocket(params) {
  const socketPath = agentSocketPath();
  const version = await getJSON(socketPath, "/json/version");
  const wsPath = new URL(String(version.webSocketDebuggerUrl ?? "")).pathname;
  if (!wsPath.startsWith("/devtools/browser/")) throw new Error("/json/version: no browser webSocketDebuggerUrl");
  const ws = await SocketWS.connect(socketPath, wsPath);
  let next = 0;
  const pending = new Map();
  ws.onmessage = (text) => {
    let msg;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    const p = pending.get(msg.id);
    if (!p) return;
    pending.delete(msg.id);
    if (msg.error) p.reject(new Error(`${p.method}: ${msg.error.message ?? JSON.stringify(msg.error)}`));
    else p.resolve(msg.result ?? {});
  };
  ws.onclose = () => {
    for (const p of pending.values()) p.reject(new Error(`${p.method}: connection closed`));
    pending.clear();
  };
  const call = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      const id = ++next;
      pending.set(id, { resolve, reject, method });
      ws.send(JSON.stringify(sessionId ? { id, method, params, sessionId } : { id, method, params }));
    });
  const timer = setTimeout(() => ws.close(), TIMEOUT_MS);
  try {
    const { targetInfos = [] } = await call("Target.getTargets");
    const page = targetInfos.find((t) => t?.type === "page" && !String(t.url ?? "").startsWith("devtools://"));
    if (!page) throw new NoTarget("no page target in Phi Canary");
    const { sessionId } = await call("Target.attachToTarget", { targetId: page.targetId, flatten: true });
    const { data } = await call("Page.captureScreenshot", params, sessionId);
    if (typeof data !== "string") throw new Error("Page.captureScreenshot: no data");
    await call("Target.detachFromTarget", { sessionId }).catch(() => {});
    return data;
  } finally {
    clearTimeout(timer);
    ws.close();
  }
}

// --- main -----------------------------------------------------------------------

const target = process.argv[2];
const extra = process.argv.slice(3);
const png = extra.length === 1 && extra[0] === "--png";
const port = Number(target);
const viaSocket = target === "socket";
if ((!viaSocket && (!Number.isInteger(port) || port < 1 || port > 65535)) || (extra.length > 0 && !png)) {
  fail(1, "usage: cdp-shot.mjs <socket|port> [--png]");
} else {
  try {
    const params = png ? { format: "png" } : { format: "jpeg", quality: 60 };
    const data = viaSocket ? await captureSocket(params) : await captureTCP(await firstPage(port), params);
    process.stdout.write(data + "\n");
  } catch (err) {
    if (err instanceof NoTarget) fail(2, err.message);
    else fail(1, err?.message ?? String(err));
  }
}
