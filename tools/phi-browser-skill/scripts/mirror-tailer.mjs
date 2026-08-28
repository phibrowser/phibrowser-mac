// Copyright 2026 Phinomenon Inc.
//
// Session-mirror tailer daemon — the bridge between a driving code agent
// session and its agent Space console, in BOTH directions, with no setup:
//
//   session → console: tails the session transcript — the agent's JSONL
//     file (Claude Code, Codex, Pi, OpenClaw, Cursor) or its SQLite
//     transcript rows (Hermes; see lib/mirror-sqlite.mjs) — and forwards
//     new prompt,
//     prose, reasoning, and tool-call lines (batched, cursor-ordered),
//     each tagged with the origin agent so the console renders them in
//     that agent's own visual style.
//   console → session: listens for the app's agentSpace.userMessage
//     broadcast; while the task is IDLE (no round live to drain the queue
//     itself) the driving agent's console bridge drains the user's console
//     commands into the session — OpenClaw through its gateway CLI
//     (mirror-openclaw's OpenclawConsoleBridge), Hermes through its
//     resume-oneshot CLI (mirror-hermes's HermesConsoleBridge) — so a
//     console command wakes an idle session instead of waiting for its
//     next round. Pi is delivered separately by its installed in-process
//     extension (mirror-pi-bridge.mjs), the only layer that can call
//     pi.sendUserMessage(). The remaining terminal agents queue commands
//     until the driver's next round.
//
// ensureAgentSpace spawns it detached (arg: session key) after writing the
// session's daemon control file. Lifetime is bounded by construction —
// every exit path is deliberate:
//   - control file deleted (a mirrorless complete() ran) or claimed by
//     another pid
//   - a deferred completion finished: complete() marks the control file
//     `completing`, this daemon mirrors until the driver's final reply has
//     landed, then sends agentSpace.complete itself and exits — so the
//     console reads the answer BEFORE its "Task completed" line
//   - control ts stale: no heredoc refreshed it for CONTROL_TTL_MS
//   - the driving agent process died (control.agentPid gone)
//   - the task is unknown to the app (ended); a later round respawns us
//   - the transcript file disappeared
// Everything is best-effort and silent: the daemon must never outlive its
// usefulness, and a premature exit only costs a respawn on the next round.

import { openSync, readSync, closeSync, statSync, readFileSync } from 'node:fs'
import {
  readDaemonControl, writeDaemonControl, clearDaemonControl, readCursor,
  writeCursor, forwardEntries, openPhiChannel, pidAlive, isPhiDenied,
  BACKFILL_GRACE_MS,
} from './lib/mirror-core.mjs'
import { toEntry as claudeToEntry } from './lib/mirror-claude.mjs'
import { toEntry as codexToEntry } from './lib/mirror-codex.mjs'
import { toEntry as piToEntry } from './lib/mirror-pi.mjs'
import {
  toEntry as cursorToEntry, CursorConsoleNotice,
} from './lib/mirror-cursor.mjs'
import {
  toEntry as hermesToEntry, hermesQuery, hermesRowToItem, HermesConsoleBridge,
} from './lib/mirror-hermes.mjs'
import {
  toEntry as openclawToEntry, OpenclawConsoleBridge,
} from './lib/mirror-openclaw.mjs'
import { SqliteTail } from './lib/mirror-sqlite.mjs'

const POLL_MS = 1000
const CONTROL_TTL_MS = 30 * 60 * 1000
// The broadcast wakes the console-command bridge instantly; this sweep is
// the delivery guarantee for a missed broadcast (channel down, app restart).
const MESSAGE_SWEEP_MS = 10 * 1000
// Between-rounds keep-alive. The skill's own long-TTL ping runs at clean
// round end (__dispose) — but a driver whose harness SIGKILLs tool calls
// (Pi's 10s bash timeout) never disposes, the task falls back to the app's
// short default TTL, and it gets reaped mid-conversation: the re-created
// task then starts a fresh console, losing the mirrored history. The daemon
// is the one process that KNOWS the session is still alive (agentPid), so
// it heartbeats the task while it runs. Bounded on every side: the daemon
// exits with the session, with the control TTL (30 min after the last real
// round), and on complete() — so an abandoned Space still closes.
const HEARTBEAT_MS = 60 * 1000
const HEARTBEAT_TTL_SECONDS = 300
// Per-batch and in-memory bounds; overflow drops OLDEST (flood policy: a
// long backlog keeps its newest lines).
const MAX_LINES_PER_BATCH = 60
const MAX_PENDING = 500
// Deferred completion (helpers.complete wrote ctl.completing): the daemon
// keeps mirroring so the driver's final reply lands in the console, then
// finishes the task itself. "The reply has landed" = a turn-end record
// arrived after the intent (Claude's turn_duration / Codex's waiting edge),
// or the transcript stayed quiet this long — capped so a session that never
// goes quiet can't hold the Space open forever.
const COMPLETE_QUIET_MS = 8 * 1000
const COMPLETE_MAX_WAIT_MS = 90 * 1000

const sessionKey = process.argv[2]
process.title = 'phi-mirror-tailer'
if (!sessionKey) process.exit(0)

// The spawning round delegates its app-issued logical-driver capability over
// stdin, an inherited one-shot pipe. Keep it only in memory: argv, env, and
// the shared mirror control file remain free of authorization material.
// Skipped on a TTY — a manual `node mirror-tailer.mjs <key>` run would
// otherwise block on readFileSync(0) until Ctrl-D.
let delegatedAgentCapability = null
try {
  if (!process.stdin.isTTY) {
    const value = readFileSync(0, 'utf8').trim()
    if (/^[A-Za-z0-9_-]{32,128}$/.test(value)) delegatedAgentCapability = value
  }
} catch {}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

main().catch(() => {}).finally(() => process.exit(0))

async function main() {
  // Claim the session: exactly one daemon per session key. The write-then-
  // reread settles a spawn race — the loser sees the other pid and exits.
  let ctl = readDaemonControl(sessionKey)
  if (!ctl || !ctl.transcriptPath) return
  if (ctl.pid && ctl.pid !== process.pid && pidAlive(ctl.pid)) return
  writeDaemonControl(sessionKey, { ...ctl, pid: process.pid })
  await sleep(300)
  ctl = readDaemonControl(sessionKey)
  if (!ctl || ctl.pid !== process.pid) return

  const startTs = Date.now()
  let { cursor, known } = readCursor(sessionKey)
  // The transcript's shape and dialect, chosen by whoever spawned us (see
  // the per-agent discover* in lib/mirror-*.mjs). Hermes keeps transcripts
  // as SQLite rows — for it the session key IS the row filter's session id;
  // the JSONL agents get the byte-offset tail below.
  const tail = ctl.format === 'hermes'
    ? new SqliteTail(ctl.transcriptPath,
                     (since) => hermesQuery(sessionKey, since), hermesRowToItem)
    : new TranscriptTail(ctl.transcriptPath)
  const toEntry = ctl.format === 'codex' ? codexToEntry
    : ctl.format === 'pi' ? piToEntry
    : ctl.format === 'hermes' ? hermesToEntry
    : ctl.format === 'openclaw' ? openclawToEntry
    : ctl.format === 'cursor' ? cursorToEntry
    : claudeToEntry
  const pending = []
  // The console → session transport, when the driving agent has one here.
  // Cursor's slot is a notice, not a transport: no ingress can wake an
  // idle Cursor turn, so the user is told their command awaits the next
  // round instead of watching it vanish (see mirror-cursor.mjs).
  const bridge = ctl.format === 'openclaw' ? new OpenclawConsoleBridge(sessionKey)
    : ctl.format === 'hermes' ? new HermesConsoleBridge(sessionKey)
    : ctl.format === 'cursor' ? new CursorConsoleNotice()
    : null

  // Persistent app channel: carries the log forwards, the message drains,
  // and the userMessage broadcast. Marked dead on any send failure and
  // reopened lazily — while Phi is down, everything simply accumulates.
  let channel = null
  let bridgeWake = false
  let lastSweep = 0
  // First heartbeat after one interval — the round that spawned us is live
  // and already refreshing the clock itself.
  let lastHeartbeat = Date.now()
  // Set when the app answers 403 — the user denied this agent, the delegated
  // capability is one the app no longer knows (it restarted), or nothing
  // about this connection identifies an agent at all. None of those pass with
  // time, and every send below treats a channel failure as transient, so
  // without this the daemon reconnects once per POLL_MS for as long as the
  // driving agent lives. Exiting costs nothing: the next round respawns it,
  // by which time the user may have answered differently.
  let refused = false
  // Deferred-completion state: when the last transcript line arrived (the
  // quiet-window clock) and whether a turn-end record has been seen since
  // the completion intent was written.
  let lastMirrorActivity = Date.now()
  let sawTurnEndAfterComplete = false

  const ensureChannel = async () => {
    if (channel) return channel
    // This daemon is detached (reparented to launchd once its spawning round
    // exits), so the app's ancestry walk can't reach the agent: the
    // stdin-delegated capability is what joins the agent's session — and its
    // consent identity — on this connection. The claimed pid merely names
    // the agent in the app's logs.
    try {
      channel = await openPhiChannel({
        agentPid: Number(ctl.agentPid) || null,
        agentCapability: delegatedAgentCapability,
      })
    } catch (err) {
      // A refusal ends this daemon (see `refused`); everything else is a
      // state that passes, and the caller retries on the next tick.
      if (isPhiDenied(err)) refused = true
      throw err
    }
    channel.onEvent('agentSpace.userMessage', ({ taskId }) => {
      const cur = readDaemonControl(sessionKey)
      if (cur && cur.taskId === taskId) bridgeWake = true
    })
    return channel
  }
  const dropChannel = () => { try { channel?.close() } catch {}; channel = null }

  // Best-effort completion for exit paths while a deferred-complete intent
  // is pending: the agent asked for it before the session closed, and
  // without this the task would linger to TTL expiry with no "Task
  // completed" line at all.
  const finalizeDeferredComplete = async (control) => {
    try {
      await (await ensureChannel()).send('agentSpace.complete', {
        taskId: control.taskId,
        status: control.completing.status === 'failure' ? 'failure' : 'success',
        ...(control.completing.message
          ? { message: String(control.completing.message) } : {}),
      })
    } catch {}
    clearDaemonControl(sessionKey)
  }

  for (;;) {
    if (refused) return                               // the app said no
    ctl = readDaemonControl(sessionKey)
    if (!ctl || ctl.pid !== process.pid) return       // dismissed or superseded
    if (Date.now() - (ctl.ts || 0) > CONTROL_TTL_MS) return
    if (ctl.agentPid && !pidAlive(ctl.agentPid)) {    // session closed
      if (ctl.completing && ctl.taskId) await finalizeDeferredComplete(ctl)
      return
    }

    // session → console
    let fresh
    try { fresh = tail.readNew() } catch {            // transcript gone
      if (ctl.completing && ctl.taskId) await finalizeDeferredComplete(ctl)
      return
    }
    if (fresh.length) lastMirrorActivity = Date.now()
    pending.push(...fresh)
    while (pending.length && pending[0].index < cursor) pending.shift()
    if (pending.length > MAX_PENDING) pending.splice(0, pending.length - MAX_PENDING)
    if (pending.length && ctl.taskId) {
      let entries = []
      for (const { raw } of pending) {
        let obj
        try { obj = JSON.parse(raw) } catch { continue }
        const e = toEntry(obj)
        if (!e) continue
        // Tagged with the origin so the console renders each line in the
        // driving agent's own visual language (Claude Code's >/⏺/⎿ beats,
        // Codex's ▌/•/└ cells).
        for (const one of Array.isArray(e) ? e : [e]) {
          entries.push({ ...one, agent: ctl.format || 'claude' })
          // A turn-end record authored AFTER the deferred-complete intent
          // means the driver's final reply is fully written — the signal to
          // finish the task without waiting out the quiet window. Claude's
          // idle activity carries a JSON payload; Codex's is the literal
          // "waiting".
          if (ctl.completing && one.kind === 'activity'
              && (one.ts || 0) >= (Number(ctl.completing.ts) || 0)
              && (one.text === 'waiting'
                  || String(one.text).includes('"phase":"idle"'))) {
            sawTurnEndAfterComplete = true
          }
        }
      }
      if (!known) {
        entries = entries.filter((e) => !e.ts || e.ts >= startTs - BACKFILL_GRACE_MS)
      }
      const nextCursor = pending[pending.length - 1].index + 1
      try {
        if (entries.length) {
          await forwardEntries(ctl.taskId, entries.slice(-MAX_LINES_PER_BATCH),
                               await ensureChannel())
        }
        cursor = nextCursor
        known = true
        writeCursor(sessionKey, cursor)
        pending.length = 0
      } catch (err) {
        if (String(err && err.message).includes('unknown_task')) return
        dropChannel()  // transient (Phi restarting): retry next tick
      }
    }

    // Deferred completion: once the final reply has landed (turn end seen,
    // quiet window elapsed, or the hard cap) and every mirrored line is
    // flushed, finish the task and exit. A failed send retries next tick.
    if (ctl.completing && ctl.taskId && pending.length === 0) {
      const intentTs = Number(ctl.completing.ts) || lastMirrorActivity
      const quiet = Date.now() - Math.max(lastMirrorActivity, intentTs)
        >= COMPLETE_QUIET_MS
      const capped = Date.now() - intentTs >= COMPLETE_MAX_WAIT_MS
      if (sawTurnEndAfterComplete || quiet || capped) {
        try {
          // Any response settles it: ok means completed, not-ok means the
          // task is already gone — either way this completion is done.
          await (await ensureChannel()).send('agentSpace.complete', {
            taskId: ctl.taskId,
            status: ctl.completing.status === 'failure' ? 'failure' : 'success',
            ...(ctl.completing.message
              ? { message: String(ctl.completing.message) } : {}),
          })
          // A round may have re-targeted the control file to ANOTHER task
          // while this completion drained; the file — and this daemon — now
          // serve that task, and deleting the file here would kill its
          // mirror. Exit (clearing) only while the file still records the
          // completed task as ours; on a re-target, reset the completion
          // state and keep tailing for the new task.
          const cur = readDaemonControl(sessionKey)
          if (cur && cur.pid === process.pid && cur.taskId !== ctl.taskId) {
            sawTurnEndAfterComplete = false
          } else {
            // Superseded by another daemon (pid mismatch): just exit —
            // clearing would clobber the successor's claim.
            if (!cur || cur.pid === process.pid) clearDaemonControl(sessionKey)
            return
          }
        } catch {
          dropChannel()  // transient (Phi restarting): retry next tick
        }
      }
    }

    // console → session
    if (bridge && (bridgeWake || Date.now() - lastSweep >= MESSAGE_SWEEP_MS)) {
      bridgeWake = false
      lastSweep = Date.now()
      try {
        const gone = await bridge.deliverPending(ctl, await ensureChannel())
        if (gone) return  // unknown task: ended
      } catch {
        dropChannel()
      }
    }

    // between-rounds keep-alive (see HEARTBEAT_MS)
    if (ctl.taskId && Date.now() - lastHeartbeat >= HEARTBEAT_MS) {
      lastHeartbeat = Date.now()
      try {
        const res = await (await ensureChannel()).send('agentSpace.ping', {
          taskId: ctl.taskId, ttlSeconds: HEARTBEAT_TTL_SECONDS,
        })
        if (res && res.ok === false) return  // task ended: exit, respawn re-creates
      } catch {
        dropChannel()
      }
    }

    await sleep(POLL_MS)
  }
}

/**
 * Incremental transcript reader. Tracks a byte offset and a partial-line
 * remainder so each poll reads only appended bytes, and numbers complete
 * non-empty lines with the same absolute index the cursor counts (see
 * mirror-claude transcriptLines). A shrunken file (rotation) restarts from
 * zero — the cursor shift above then skips what was already forwarded.
 */
class TranscriptTail {
  constructor(path) {
    this.path = path
    this.offset = 0
    this.rest = ''
    this.seen = 0
  }

  /** New complete non-empty lines since the last call: [{index, raw}]. */
  readNew() {
    const size = statSync(this.path).size
    if (size < this.offset) { this.offset = 0; this.rest = ''; this.seen = 0 }
    if (size === this.offset) return []
    const fd = openSync(this.path, 'r')
    let chunk
    try {
      const buf = Buffer.alloc(size - this.offset)
      readSync(fd, buf, 0, buf.length, this.offset)
      this.offset = size
      chunk = this.rest + buf.toString('utf8')
    } finally {
      closeSync(fd)
    }
    const parts = chunk.split('\n')
    this.rest = parts.pop()  // incomplete tail (or '') waits for its newline
    const out = []
    for (const part of parts) {
      if (!part.trim()) continue
      out.push({ index: this.seen, raw: part })
      this.seen += 1
    }
    return out
  }
}
