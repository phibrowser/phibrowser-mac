// Copyright 2026 Phinomenon Inc.
//
// Claude Code adapter for the session mirror (the tailer daemon,
// scripts/mirror-tailer.mjs): session discovery and transcript parsing.
// Kept separate from the agent-neutral core so each agent's sibling
// (mirror-codex, -hermes, -openclaw) supplies only these two pieces
// and reuses everything else.

import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/**
 * The driving Claude Code session's transcript, or null. Exact: Claude Code
 * exports its session id to every shell command, and the transcript path is
 * located by session id across project dirs rather than by deriving the
 * munged cwd folder name — immune to the munging rules changing.
 */
export function discoverClaudeTranscript() {
  const sessionId = process.env.CLAUDE_CODE_SESSION_ID
  if (!sessionId) return null
  try {
    const projects = join(homedir(), '.claude', 'projects')
    for (const dir of readdirSync(projects)) {
      const path = join(projects, dir, `${sessionId}.jsonl`)
      if (existsSync(path)) return { sessionKey: sessionId, path, format: 'claude' }
    }
  } catch {}
  return null
}

// --- turn activity -----------------------------------------------------------
// Claude Code's transcript has no explicit turn lifecycle events (Codex's
// task_started / task_complete). The edges are reconstructed here: the first
// conversation record while no turn is open means "working" began, and the
// system turn_duration record closes it with the turn's real duration.
// Module-level state is safe here (the daemon is one process per
// session); a daemon restart mid-turn only costs that turn's
// elapsed baseline and the background-shell set.
let workingSince = null
const runningShells = new Set()

/**
 * One transcript JSONL object → console line(s): a single entry, an array
 * (an assistant record interleaves thinking, prose, and tool calls in block
 * order), or null to skip. Turn edges additionally emit `kind: activity`
 * records — the console's transient Claude-style status line ("✽ Mulling…"
 * while working, "Cogitated for 28s" at rest) — carrying a JSON payload:
 * working: {phase, startTs, effort?}; idle: {phase, startTs?, durationMs,
 * shellsRunning}.
 */
export function toEntry(obj) {
  if (!obj || obj.isMeta) return null
  const activity = turnActivity(obj)
  const entries = conversationEntries(obj)
  if (!activity) return entries
  if (!entries) return activity
  return [activity, ...(Array.isArray(entries) ? entries : [entries])]
}

/**
 * The record's turn-edge side channel, advancing the working/idle state
 * machine and the background-shell set. Returns an activity entry on a
 * transition, else null.
 */
function turnActivity(obj) {
  const ts = Date.parse(obj.timestamp || '') || Date.now()
  if (obj.type === 'system' && obj.subtype === 'turn_duration') {
    const startTs = workingSince
    workingSince = null
    return activityEntry({
      phase: 'idle',
      ...(startTs ? { startTs } : {}),
      durationMs: Math.max(0, Math.round(Number(obj.durationMs) || 0)),
      shellsRunning: runningShells.size,
    }, ts)
  }
  if ((obj.type !== 'user' && obj.type !== 'assistant') || !obj.message) return null
  trackBackgroundShells(obj)
  if (workingSince != null) return null
  workingSince = ts
  const effort = effortLevel()
  return activityEntry({ phase: 'working', startTs: ts, ...(effort ? { effort } : {}) }, ts)
}

function activityEntry(payload, ts) {
  return { kind: 'activity', text: JSON.stringify(payload), ts }
}

/**
 * Keeps the "N shells still running" count: a Bash tool_use with
 * run_in_background opens a shell under its tool-use id, and the harness's
 * task-notification (delivered as a user record naming that id) closes it —
 * any terminal status does, completed and killed alike. Notifications for
 * other background work (subagents) name ids never added here, so their
 * deletes are no-ops.
 */
function trackBackgroundShells(obj) {
  const content = obj.message?.content
  if (obj.type === 'assistant' && Array.isArray(content)) {
    for (const b of content) {
      if (b && b.type === 'tool_use' && b.name === 'Bash' && b.id
          && b.input && b.input.run_in_background === true) {
        runningShells.add(b.id)
      }
    }
    return
  }
  if (obj.type !== 'user') return
  const texts = typeof content === 'string' ? [content]
    : Array.isArray(content)
      ? content.filter((b) => b && b.type === 'text' && b.text).map((b) => b.text)
      : []
  for (const text of texts) {
    if (!text.includes('<task-notification>')) continue
    for (const m of text.matchAll(/<tool-use-id>\s*([^<\s]+)\s*<\/tool-use-id>/g)) {
      runningShells.delete(m[1])
    }
  }
}

/**
 * Claude Code's configured reasoning effort ("xhigh"), shown on the status
 * line as "thinking with xhigh effort". Best-effort from the settings file
 * (a session-scoped /model override is not recorded in the transcript),
 * re-read at each turn start so a settings change lands on the next turn.
 */
function effortLevel() {
  try {
    const dir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude')
    const settings = JSON.parse(readFileSync(join(dir, 'settings.json'), 'utf8'))
    const effort = settings.effortLevel
    return typeof effort === 'string' && effort ? effort.slice(0, 16) : null
  } catch { return null }
}

/** The record's conversation lines (the pre-activity toEntry body). */
function conversationEntries(obj) {
  const msg = obj.message
  const ts = Date.parse(obj.timestamp || '') || undefined

  if (obj.type === 'user' && msg) {
    const content = msg.content
    if (typeof content === 'string') {
      return content.trim() ? userEntry(content, ts) : null
    }
    if (Array.isArray(content)) {
      // A user turn that is purely tool_result is machinery, not a prompt.
      const texts = content.filter((b) => b && b.type === 'text' && b.text)
        .map((b) => b.text)
      return texts.length ? userEntry(texts.join('\n\n'), ts) : null
    }
    return null
  }

  if (obj.type === 'assistant' && msg && Array.isArray(msg.content)) {
    const out = []
    for (const b of msg.content) {
      if (!b) continue
      if (b.type === 'text' && b.text && b.text.trim()) {
        out.push({ kind: 'assistant', text: b.text, ts })
      } else if (b.type === 'thinking' && b.thinking && b.thinking.trim()) {
        out.push({ kind: 'thinking', text: b.thinking, ts })
      } else if (b.type === 'tool_use') {
        const e = toolEntry(b, ts)
        if (e) out.push(e)
      }
    }
    return out.length ? out : null
  }

  return null
}

// The phi heredocs that drive the browser are already narrated line-by-line
// by the skill's own action log; mirroring the Bash call too would double
// every step.
const PHI_PLUMBING = /runner\.mjs|phi-browser/

/**
 * A tool_use block → the console line Claude Code itself shows for it
 * ("Bash(git status)", "Update(src/app.ts)", "Search(pattern)"), or null
 * for skill plumbing.
 */
function toolEntry(block, ts) {
  const name = block.name || 'Tool'
  const input = block.input || {}
  switch (name) {
    case 'Bash': {
      const cmd = String(input.command || '')
      if (PHI_PLUMBING.test(cmd)) return null
      return tool(`Bash(${condense(cmd)})`, ts)
    }
    case 'Read': return tool(`Read(${condense(shortPath(input.file_path))})`, ts)
    case 'Write': return tool(`Write(${condense(shortPath(input.file_path))})`, ts)
    case 'Edit': return tool(`Update(${condense(shortPath(input.file_path))})`, ts)
    case 'Grep': return tool(`Search(${condense(input.pattern)})`, ts)
    case 'Glob': return tool(`Search(${condense(input.pattern)})`, ts)
    case 'Task': return tool(`Task(${condense(input.description || '')})`, ts)
    case 'WebFetch': return tool(`Fetch(${condense(input.url)})`, ts)
    case 'WebSearch': return tool(`Web Search(${condense(input.query)})`, ts)
    case 'TodoWrite': return tool('Update Todos', ts)
    case 'Skill': return tool(`Skill(${condense(input.skill)})`, ts)
    default: {
      let args = ''
      try { args = JSON.stringify(input) } catch {}
      return tool(`${name}(${condense(args === '{}' ? '' : args)})`, ts)
    }
  }
}

function tool(text, ts) {
  return { kind: 'tool', text, ts }
}

/**
 * Claude Code prints paths relative to the working directory (or ~-abbreviated);
 * the daemon runs in the driving session's cwd, so the same trim applies here.
 */
function shortPath(value) {
  const s = String(value ?? '')
  const cwd = process.cwd()
  if (s.startsWith(`${cwd}/`)) return s.slice(cwd.length + 1)
  const home = homedir()
  if (s.startsWith(`${home}/`)) return `~${s.slice(home.length)}`
  return s
}

/** First non-empty line, whitespace collapsed, capped for a title slot. */
function condense(value, max = 120) {
  const line = String(value ?? '').split('\n').map((l) => l.trim())
    .find((l) => l) || ''
  const s = line.replace(/\s+/g, ' ')
  return s.length > max ? `${s.slice(0, max)}…` : s
}

/**
 * A user prompt carrying the "[phi-console]" marker is a console command
 * delivered into the session — the app already echoed it in the console at
 * enqueue time, so mirroring it again would duplicate the line. A
 * task-notification is harness machinery delivered as a user record (a
 * background shell or subagent finishing), not something the user typed —
 * the activity tracker consumes it for the shell count; the feed skips it.
 */
function userEntry(text, ts) {
  if (text.trimStart().startsWith('[phi-console]')) return null
  if (text.includes('<task-notification>')) return null
  if (text.includes('<command-name>') || text.includes('<local-command-')) {
    return localCommandEntry(text, ts)
  }
  return { kind: 'user', text, ts }
}

/**
 * A slash command run in the terminal lands in the transcript as XML-ish
 * markup — <command-name>/phi-browser</command-name> with its
 * <command-args>, and the command's printed output as a separate
 * <local-command-stdout> record. Mirror what Claude Code itself displays:
 * the command line the user typed ("/phi-browser open wikipedia…") and its
 * output as a plain console line — never the raw markup. Records with
 * neither (a bare <local-command-caveat>, an empty stdout) are machinery.
 */
function localCommandEntry(text, ts) {
  const name = tagContent(text, 'command-name')
  if (name) {
    const args = tagContent(text, 'command-args')
    return { kind: 'user', text: args ? `${name} ${args}` : name, ts }
  }
  const stdout = stripAnsi(tagContent(text, 'local-command-stdout') || '').trim()
  return stdout ? { kind: 'action', text: stdout, ts } : null
}

function tagContent(text, tag) {
  const m = new RegExp(`<${tag}>([\\s\\S]*?)</${tag}>`).exec(text)
  const inner = m ? m[1].trim() : ''
  return inner || null
}

/** The terminal styles its stdout with ANSI SGR codes; the console doesn't. */
function stripAnsi(s) {
  return s.replace(/\u001b\[[0-9;]*m/g, '')
}

/**
 * The transcript's non-empty lines. The session cursor counts EXACTLY these
 * (see mirror-core readCursor) — a reader that counts lines differently
 * would corrupt the cursor, so readers go through here or replicate this
 * filter precisely (the tailer's incremental reader does).
 */
export function transcriptLines(path) {
  return readFileSync(path, 'utf8').split('\n').filter((l) => l.trim())
}
