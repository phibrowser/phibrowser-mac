// Copyright 2026 Phinomenon Inc.
//
// Minimal dependency-free CDP client for Phi Browser (Node >= 22, global
// WebSocket). Connects to the browser-target websocket advertised in the
// DevToolsActivePort file of Phi's user data directory.

import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const CANDIDATE_DIRS = [
  process.env.PHI_USER_DATA_DIR,
  join(homedir(), 'Library/Application Support/com.phibrowser.canary.Mac'),
  join(homedir(), 'Library/Application Support/com.phibrowser.Mac'),
].filter(Boolean)

export function readActivePort() {
  for (const dir of CANDIDATE_DIRS) {
    const file = join(dir, 'DevToolsActivePort')
    if (!existsSync(file)) continue
    const lines = readFileSync(file, 'utf8')
      .split('\n').map((l) => l.trim()).filter(Boolean)
    const port = Number(lines[0])
    const browserPath = lines[1] || ''
    if (Number.isInteger(port) && port > 0 && browserPath) {
      return { port, browserPath, file }
    }
  }
  throw new Error(
    'DevToolsActivePort not found. Enable the CDP endpoint first (see ' +
    'references/install.md):\n' +
    '  defaults write com.phibrowser.canary.Mac PhiRemoteDebuggingPort -int 0\n' +
    'then relaunch Phi Browser.')
}

export async function verifyEndpoint(port) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/version`,
                            { signal: AbortSignal.timeout(2000) })
    if (!res.ok) throw new Error(`status ${res.status}`)
    return await res.json()
  } catch (err) {
    throw new Error(
      `Phi Browser CDP endpoint on port ${port} is not responding ` +
      `(stale DevToolsActivePort after a crash?). Relaunch Phi Browser. ` +
      `[${err.message}]`)
  }
}

export class CdpClient {
  constructor(url) {
    this.url = url
    this.nextId = 1
    this.pending = new Map()
    this.listeners = []
  }

  async connect() {
    this.ws = new WebSocket(this.url)
    await new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true })
      this.ws.addEventListener('error', () =>
        reject(new Error(`WebSocket failed to connect: ${this.url}`)),
        { once: true })
    })
    this.ws.addEventListener('message', (ev) => this.#onMessage(ev.data))
    this.ws.addEventListener('close', () => {
      for (const [, p] of this.pending) {
        p.reject(new Error('CDP connection closed'))
      }
      this.pending.clear()
    })
    return this
  }

  #onMessage(data) {
    let msg
    try { msg = JSON.parse(data) } catch { return }
    if (msg.id) {
      const p = this.pending.get(msg.id)
      if (!p) return
      this.pending.delete(msg.id)
      if (msg.error) {
        p.reject(new Error(`${p.method}: ${msg.error.message}`))
      } else {
        p.resolve(msg.result ?? {})
      }
      return
    }
    if (msg.method) {
      for (const l of this.listeners) {
        if (l.method !== msg.method) continue
        if (l.sessionId !== undefined && l.sessionId !== msg.sessionId) continue
        try { l.fn(msg.params ?? {}, msg.sessionId) } catch {}
      }
    }
  }

  /** Sends a command. `sessionId` targets a flat-mode attached session. */
  send(method, params = {}, sessionId = undefined, timeoutMs = 40000) {
    const id = this.nextId++
    const payload = { id, method, params }
    if (sessionId) payload.sessionId = sessionId
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`${method}: timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, {
        method,
        resolve: (v) => { clearTimeout(timer); resolve(v) },
        reject: (e) => { clearTimeout(timer); reject(e) },
      })
      this.ws.send(JSON.stringify(payload))
    })
  }

  /** Subscribes to an event. Pass sessionId to scope to one session.
   *  Returns an unsubscribe function (older callers may ignore it). */
  on(method, fn, sessionId = undefined) {
    const entry = { method, fn, sessionId }
    this.listeners.push(entry)
    return () => {
      const idx = this.listeners.indexOf(entry)
      if (idx >= 0) this.listeners.splice(idx, 1)
    }
  }

  /** Resolves on the first matching event, or rejects on timeout. */
  waitFor(method, predicate = () => true, timeoutMs = 20000, sessionId = undefined) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = this.listeners.indexOf(entry)
        if (idx >= 0) this.listeners.splice(idx, 1)
        reject(new Error(`timed out waiting for ${method}`))
      }, timeoutMs)
      const entry = {
        method,
        sessionId,
        fn: (params, sid) => {
          if (!predicate(params, sid)) return
          clearTimeout(timer)
          const idx = this.listeners.indexOf(entry)
          if (idx >= 0) this.listeners.splice(idx, 1)
          resolve(params)
        },
      }
      this.listeners.push(entry)
    })
  }

  close() {
    try { this.ws.close() } catch {}
  }
}

export async function connectBrowser() {
  const { port, browserPath } = readActivePort()
  await verifyEndpoint(port)
  const client = new CdpClient(`ws://127.0.0.1:${port}${browserPath}`)
  await client.connect()
  return client
}
