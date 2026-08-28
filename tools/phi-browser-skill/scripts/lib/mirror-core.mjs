// Copyright 2026 Phinomenon Inc.
//
// Agent-neutral core of the session mirror: the per-session control file
// that binds a driving agent session to its browser task and its tailer
// daemon, the per-session transcript cursor, and the batched forward into
// the task's console — plus the agent-neutral console-command bridge that
// drains the user's typed commands back into the driving session. The
// per-agent siblings (lib/mirror-claude, -codex, -pi, -hermes, -openclaw)
// supply only the agent-specific parts — session discovery, record parsing,
// and (where the agent has one) the bridge's delivery transport — and reuse
// everything here.
//
// Session binding is explicit, not inferred: the heredoc that starts a task
// KNOWS its own session (an exported session id, or the evidence heuristics
// in the per-agent discover*) and transcript, writes them into the control
// file, and spawns the daemon against it — so a concurrent unrelated
// session can never leak its conversation into someone else's console, and
// two agents driving two tasks each mirror into their own.

import {
  readFileSync, writeFileSync, unlinkSync, mkdirSync, readdirSync, statSync,
} from 'node:fs'
import { execFileSync, spawn } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join, basename } from 'node:path'
import {
  discoverEndpoints,
  isDeadSocketError,
  isEndpointTimeout,
  isPhiDenied,
  verifyEndpoint,
  FALLBACK_ENDPOINT_WAIT_MS,
  DirectPhiChannel,
} from './cdp.mjs'

// Re-exported so the daemon can tell a refusal from a restart without
// reaching past this module into the transport.
export { isPhiDenied }

// Same directory as helpers.mjs's task files — path derived identically on
// both sides so writer (heredoc) and reader (daemon) always agree.
const TASK_DIR = join(tmpdir(), 'phi-browser-tasks')

// First sight of a session key (fresh cursor): a RESUMED session replays the
// prior conversation's history under a NEW session id, and an unguarded
// backfill would re-mirror all of it as duplicates. The daemon only
// backfills lines authored since shortly before it started — which still
// covers the prompt that started the task.
export const BACKFILL_GRACE_MS = 10 * 60 * 1000

/**
 * The driving agent process's pid: the nearest ancestor that isn't a shell
 * or wrapper (for a heredoc, the agent above the tool shell). Recorded in
 * the control file so the daemon — reparented to launchd once the heredoc
 * exits — can still find the session's terminal and notice the agent dying.
 * Null when ps is unavailable.
 */
export function agentRootPid() {
  try {
    const out = execFileSync('/bin/ps', ['-axo', 'pid=,ppid=,comm='],
                             { encoding: 'utf8' })
    const table = new Map()
    for (const line of out.split('\n')) {
      const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line)
      if (m) table.set(Number(m[1]), { ppid: Number(m[2]), comm: m[3] })
    }
    let pid = process.ppid
    for (let hops = 0; hops < 64 && pid > 1; hops++) {
      const proc = table.get(pid)
      if (!proc) break
      // Login shells report as "-zsh"; strip the marker before matching.
      const name = basename(proc.comm).replace(/^-/, '').toLowerCase()
      if (!PASSTHROUGH.has(name)) return pid
      if (proc.ppid === pid) break
      pid = proc.ppid
    }
  } catch {}
  return null
}

/**
 * Every live ancestor pid of this process, nearest first (from the parent up
 * to just below launchd). Empty when ps is unavailable. Used to judge
 * whether a pid the app resolved for a connection is genuinely above us —
 * the app's ancestry walk may stop on a different ancestor than
 * agentRootPid() does (wrapper binaries, helper bundles), and any ancestor
 * is proof the round is parented to what the app bound, not orphaned.
 */
export function ancestorPids() {
  try {
    const out = execFileSync('/bin/ps', ['-axo', 'pid=,ppid='],
                             { encoding: 'utf8' })
    const ppidOf = new Map()
    for (const line of out.split('\n')) {
      const m = /^\s*(\d+)\s+(\d+)/.exec(line)
      if (m) ppidOf.set(Number(m[1]), Number(m[2]))
    }
    const ancestors = []
    let pid = process.ppid
    for (let hops = 0; hops < 64 && pid > 1; hops++) {
      ancestors.push(pid)
      const next = ppidOf.get(pid)
      if (!next || next === pid) break
      pid = next
    }
    return ancestors
  } catch { return [] }
}

// Shell and wrapper processes skipped when walking ancestry for the agent
// root — the JS mirror of AgentPeerIdentity.passthroughNames plus the shells
// that sit between an agent and the tools it spawns.
const PASSTHROUGH = new Set([
  'sh', 'bash', 'zsh', 'dash', 'fish', 'csh', 'tcsh', 'ksh',
  'env', 'login', 'sudo', 'xargs', 'timeout', 'nohup', 'caffeinate', 'script',
  // Codex wraps sandboxed shell commands in seatbelt.
  'sandbox-exec',
])

// --- daemon control ----------------------------------------------------------

// One control file per session coordinates the mirror: the skill writes
// {taskId, transcriptPath, agentPid, ts} on every
// ensureAgentSpace (refreshing the TTL and re-targeting a live daemon
// without a respawn), the daemon adds its pid claim, and complete() deletes
// the file — which is also how a running daemon is told to exit.

function daemonControlFile(sessionKey) {
  return join(TASK_DIR, `mirror-daemon-${sanitizeKey(sessionKey)}.json`)
}

export function readDaemonControl(sessionKey) {
  try {
    return JSON.parse(readFileSync(daemonControlFile(sessionKey), 'utf8'))
  } catch { return null }
}

export function writeDaemonControl(sessionKey, record) {
  try {
    mkdirSync(TASK_DIR, { recursive: true })
    writeFileSync(daemonControlFile(sessionKey), JSON.stringify(record))
    pruneStaleFiles()
  } catch {}
}

export function clearDaemonControl(sessionKey) {
  try { unlinkSync(daemonControlFile(sessionKey)) } catch {}
}

export function pidAlive(pid) {
  // EPERM means the process EXISTS but we may not signal it — true for a
  // sandboxed round probing the agent (Codex's seatbelt allows signaling
  // only itself). Only ESRCH (and friends) mean gone.
  try { process.kill(pid, 0); return true } catch (err) {
    return !!err && err.code === 'EPERM'
  }
}

/**
 * Marks the session's control file with a deferred-completion intent (see
 * helpers.complete): the tailer keeps mirroring until the driving session's
 * final reply has landed in the console, then sends agentSpace.complete
 * itself and exits — so the transcript carries the answer BEFORE the "Task
 * completed" line. Returns true when a live daemon holds this task (the
 * intent will be honored), false when there is nothing to defer to — the
 * caller must complete directly.
 */
export function requestDeferredComplete(sessionKey, taskId, completion) {
  const ctl = readDaemonControl(sessionKey)
  if (!ctl || ctl.taskId !== taskId || !ctl.pid || !pidAlive(ctl.pid)) return false
  writeDaemonControl(sessionKey, {
    ...ctl,
    // Refresh the control TTL: the grace window must not race the
    // stale-control exit.
    ts: Date.now(),
    completing: {
      status: completion.status === 'failure' ? 'failure' : 'success',
      ...(completion.message ? { message: String(completion.message) } : {}),
      ts: Date.now(),
    },
  })
  return true
}

// --- per-session transcript cursor ------------------------------------------

// The cursor is a count of non-empty lines into the session's append-only
// transcript, so every forward is idempotent and ordered: forward only what
// was added since the last one, advance only after a successful forward.

function cursorFile(sessionKey) {
  return join(TASK_DIR, `mirror-cursor-${sanitizeKey(sessionKey)}.json`)
}

/**
 * `known: false` means this session key has never been seen — the caller
 * should apply the BACKFILL_GRACE_MS guard (a resumed session replays prior
 * history under a fresh key; without the guard those lines mirror twice).
 */
export function readCursor(sessionKey) {
  try {
    const cursor = JSON.parse(readFileSync(cursorFile(sessionKey), 'utf8')).cursor
    return { cursor: cursor || 0, known: true }
  } catch { return { cursor: 0, known: false } }
}

export function writeCursor(sessionKey, cursor) {
  try {
    mkdirSync(TASK_DIR, { recursive: true })
    writeFileSync(cursorFile(sessionKey), JSON.stringify({ cursor }))
  } catch {}
}

function sanitizeKey(id) {
  return String(id || 'default').replace(/[^\w.-]/g, '_').slice(0, 80)
}

// --- app channel / forward ----------------------------------------------------

/**
 * A direct app-socket channel (throws if Phi or the socket is down). The
 * daemon holds one persistently — it also carries the agentSpace.userMessage
 * broadcasts that wake the console-command bridge — and reconnects by simply
 * calling this again after a send failure. `agentCapability` is what joins
 * the driving agent's session (identity, grant, and task principal) from a
 * process that no longer shares the agent's ancestry; `agentPid` merely
 * names the agent in the app's logs.
 */
export async function openPhiChannel({ agentPid = null, agentCapability = null } = {}) {
  const endpoints = discoverEndpoints()
  if (endpoints.length === 0) throw new Error('no app socket endpoint')
  const probeOpts = { agentPid, agentCapability }
  let lastErr = null
  const timedOut = []
  let live = null
  for (let index = 0; index < endpoints.length; index++) {
    const endpoint = endpoints[index]
    const hasFallback = index + 1 < endpoints.length
    try {
      // Avoid opening a WebSocket that can wait forever on a published but
      // wedged higher-precedence channel. The driving round already obtained
      // consent; this is a liveness probe carrying the same identity proof.
      await verifyEndpoint(endpoint, {
        ...probeOpts,
        ...(hasFallback ? { timeoutMs: FALLBACK_ENDPOINT_WAIT_MS } : {}),
      })
      live = endpoint
      break
    } catch (err) {
      // Crash-orphaned socket file — walk on to the next candidate. (Never
      // probe with a naked connect: see isDeadSocketError in cdp.mjs.)
      if (isDeadSocketError(err)) {
        lastErr = err
        continue
      }
      if (hasFallback && isEndpointTimeout(err)) {
        lastErr = err
        timedOut.push(endpoint)
        continue
      }
      throw err
    }
  }
  // A higher-precedence endpoint that outlived the short probe may be busy
  // (or holding a first-run consent prompt open) rather than wedged. Give it
  // the full window before binding a LOWER-precedence install: the daemon
  // must mirror into the same browser the driving round connects to, and
  // that walk prefers precedence the same way (see connectOverCandidates).
  for (const endpoint of timedOut) {
    try {
      await verifyEndpoint(endpoint, probeOpts)
      live = endpoint
      break
    } catch (err) {
      if (isDeadSocketError(err) || (live && isEndpointTimeout(err))) {
        lastErr = err
        continue
      }
      throw err
    }
  }
  if (!live) throw lastErr
  return await new DirectPhiChannel({
    socketPath: live.socketPath,
    agentPid,
    agentCapability,
  }).connect()
}

/**
 * Sends `entries` ([{kind, text, detail?, ts?, agent?, sourceId?,
 * toolState?}], oldest first — the
 * optional `agent` names the origin CLI whose visual style the console
 * renders the line in; `kind: activity` updates the origin CLI's transient
 * tail row — Codex's Working/Waiting, Claude Code's spinner/summary status
 * line — instead of appending history) to the task's
 * console as ONE batched agentSpace.log call, so delivery is all-or-nothing:
 * a failure re-tries the whole batch on the next tick instead of duplicating
 * an already-delivered prefix. `touch: false` marks this as mirror traffic —
 * proof the SESSION is alive, not that it is still driving — so it never
 * extends an idle Space's keep-alive. Throws on any failure; the caller
 * advances its cursor only on success. Uses `channel` when given (the
 * daemon's persistent one), else a one-shot connection.
 */
export async function forwardEntries(taskId, entries, channel = null) {
  const own = channel == null
  const ch = own ? await openPhiChannel() : channel
  try {
    const res = await ch.send('agentSpace.log', {
      taskId,
      touch: false,
      entries: entries.map((e) => ({
        kind: e.kind,
        text: String(e.text).slice(0, 4000),
        // Pi's collapsed tool cards deliberately retain short multiline
        // output/diff previews; every other adapter keeps the original tight
        // secondary-line cap.
        ...(e.detail ? { detail: String(e.detail).slice(
          0, e.agent === 'pi' && e.kind === 'tool' ? 4000 : 500) } : {}),
        ...(e.ts ? { ts: e.ts } : {}),
        ...(e.agent ? { agent: String(e.agent).slice(0, 16) } : {}),
        ...(e.agent === 'pi' && e.kind === 'tool' && e.sourceId
          ? { sourceId: String(e.sourceId).slice(0, 128) } : {}),
        ...(e.agent === 'pi' && e.kind === 'tool'
          && ['pending', 'success', 'error'].includes(e.toolState)
          ? { toolState: e.toolState } : {}),
      })),
    })
    if (res && res.ok === false) {
      throw new Error(res.error || 'agentSpace.log rejected')
    }
  } finally {
    if (own) ch.close()
  }
}

// --- console-command bridge ---------------------------------------------------

// Delivery attempts per console command before giving up with a console
// error line (agent CLI unreachable and the like).
const MAX_DELIVER_ATTEMPTS = 5

/**
 * The console → session direction, driven by the tailer's sweep tick.
 * Agent-neutral: the per-agent adapters subclass this with their own
 * `deliver(sessionKey, text)` transport (OpenClaw's gateway CLI, Hermes's
 * resume-oneshot CLI); agents with no transport get no bridge and their
 * commands stay queued until the driver's next round. Drains the app's
 * queued console commands and delivers them into the driving session, ONLY
 * when the task is idle: a live round is expected to drain the queue itself,
 * and racing it would strand a waitForUserMessage on an empty queue.
 * Commands are delivered with a "[phi-console]" prefix: the agent sees the
 * provenance (answer via narrate/console, not just its own surface), and
 * the per-agent toEntry suppresses the echoed transcript line (the app
 * already echoed the command at enqueue).
 */
export class ConsoleCommandBridge {
  constructor(sessionKey, deliver) {
    this.sessionKey = sessionKey
    this.deliver = deliver
    this.undelivered = []     // [{text, attempts}] retrying across ticks
  }

  /** True means the task no longer exists — the daemon should exit. */
  async deliverPending(ctl, channel) {
    if (!ctl.taskId || !ctl.agentPid) return false
    const { tasks } = await channel.send('agentSpace.list', {})
    const task = (tasks || []).find((t) => t.taskId === ctl.taskId)
    if (!task) return true
    const queued = task.pendingUserMessages || 0
    if (!queued && !this.undelivered.length) return false
    // Deliver only between rounds: a live round drains the queue itself
    // (readUserMessages / waitForUserMessage), and a starting one gets the
    // count in its ensureAgentSpace return.
    if (task.status !== 'idle') return false

    if (queued) {
      const { messages } = await channel.send(
        'agentSpace.readUserMessages', { taskId: ctl.taskId })
      for (const m of messages || []) {
        this.undelivered.push({ text: m.text, attempts: 0 })
      }
    }
    const retry = []
    for (const item of this.undelivered) {
      try {
        await this.deliver(this.sessionKey, `[phi-console] ${item.text}`)
        await new Promise((r) => setTimeout(r, 300))  // pace successive deliveries
      } catch {
        item.attempts += 1
        if (item.attempts < MAX_DELIVER_ATTEMPTS) {
          retry.push(item)
        } else {
          await forwardEntries(ctl.taskId, [{
            kind: 'error',
            text: 'Could not deliver your command to the agent',
            detail: item.text.slice(0, 200),
          }], channel).catch(() => {})
        }
      }
    }
    this.undelivered = retry
    return false
  }
}

/**
 * Runs an agent CLI that wakes a session with a message. Resolves on
 * acceptance: a clean exit, or still running after `acceptWaitMs` — CLI
 * errors (no daemon, bad auth, unknown session) exit within a moment, while
 * a healthy call may keep streaming the woken run far longer than the
 * bridge can block. Rejects on a prompt nonzero exit or a missing binary,
 * which the bridge turns into its usual retry.
 */
export function deliverViaAgentCLI(bin, args, { acceptWaitMs = 15000, env } = {}) {
  return new Promise((resolve, reject) => {
    let child
    try {
      child = spawn(bin, args, { stdio: 'ignore', ...(env ? { env } : {}) })
    } catch (err) { reject(err); return }
    const timer = setTimeout(() => { child.unref() ; resolve() }, acceptWaitMs)
    child.once('error', (err) => { clearTimeout(timer); reject(err) })
    child.once('exit', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(`${basename(bin)} exited ${code}`))
    })
  })
}

// --- housekeeping -------------------------------------------------------------

// Opportunistic, on control writes only: cursor and control leftovers from
// crashed sessions go after a week (their sessions are long over).
function pruneStaleFiles() {
  const now = Date.now()
  for (const file of readdirSync(TASK_DIR)) {
    if (!file.startsWith('mirror-cursor-') && !file.startsWith('mirror-daemon-')
        && !/^active(-\d+)?\.json$/.test(file)) continue
    try {
      const path = join(TASK_DIR, file)
      if (now - statSync(path).mtimeMs > 7 * 24 * 60 * 60 * 1000) unlinkSync(path)
    } catch {}
  }
}
