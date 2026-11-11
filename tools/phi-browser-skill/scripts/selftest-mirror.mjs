#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// Self-test for the session mirror's agent adapters. Run after changing any
// scripts/lib/mirror-*.mjs:
//   node scripts/selftest-mirror.mjs
//
// Everything runs against fixtures — no Phi and no agents needed.
// Covers: each agent's toEntry parsing
// (echo suppression, machinery skipping), the SQLite tail source against a
// throwaway database shaped like Hermes', the env-gated session discovery
// (Hermes' SQLite state, OpenClaw's JSONL session dir, Cursor's
// agent-transcripts tree), and the console bridges' CLI delivery seams
// (OpenClaw's gateway CLI, Hermes's resume-oneshot). Exits non-zero when
// any check fails.

import {
  mkdtempSync, rmSync, writeFileSync, readFileSync, chmodSync, utimesSync,
} from 'node:fs'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { toEntry as claudeToEntry } from './lib/mirror-claude.mjs'
import { toEntry as codexToEntry } from './lib/mirror-codex.mjs'
import {
  toEntry as hermesToEntry, hermesQuery, hermesRowToItem, discoverHermesTranscript,
  deliverHermes, HermesConsoleBridge,
} from './lib/mirror-hermes.mjs'
import {
  toEntry as openclawToEntry, discoverOpenclawTranscript, deliverOpenclaw,
  OpenclawConsoleBridge,
} from './lib/mirror-openclaw.mjs'
import {
  toEntry as cursorToEntry, discoverCursorTranscript, CursorConsoleNotice,
} from './lib/mirror-cursor.mjs'
import { SqliteTail } from './lib/mirror-sqlite.mjs'
import {
  readDaemonControl, writeDaemonControl, clearDaemonControl,
  requestDeferredComplete,
} from './lib/mirror-core.mjs'

const results = []
function check(name, ok, detail = '') {
  results.push({ name, ok: !!ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}

const dir = mkdtempSync(join(tmpdir(), 'phi-mirror-selftest-'))
const sql = (db, stmt) => execFileSync('/usr/bin/sqlite3', [db, stmt], { encoding: 'utf8' })

// --- toEntry: Claude Code ------------------------------------------------------

{
  // Pin the effort the activity records report to a fixture, independent of
  // this machine's real ~/.claude/settings.json.
  const claudeConfig = join(dir, 'claude-config')
  execFileSync('/bin/mkdir', ['-p', claudeConfig])
  writeFileSync(join(claudeConfig, 'settings.json'),
                JSON.stringify({ effortLevel: 'xhigh' }))
  const savedConfigDir = process.env.CLAUDE_CONFIG_DIR
  process.env.CLAUDE_CONFIG_DIR = claudeConfig

  const first = claudeToEntry({ type: 'user', timestamp: '2026-07-17T03:00:00Z',
                                message: { content: 'hello there' } })
  const opened = Array.isArray(first) && first.length === 2
    ? { activity: JSON.parse(first[0].text), user: first[1] } : null
  check('claude: first conversation record opens the turn (working activity + prompt)',
        opened && first[0].kind === 'activity'
        && opened.activity.phase === 'working'
        && opened.activity.startTs === first[0].ts
        && opened.activity.effort === 'xhigh'
        && opened.user.kind === 'user' && opened.user.text === 'hello there'
        && opened.user.ts > 0)
  check('claude: tool_result-only user is machinery', claudeToEntry({
    type: 'user', message: { content: [{ type: 'tool_result', content: 'x' }] },
  }) === null)
  const a = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'thinking', thinking: 'hmm' },
    { type: 'text', text: 'reply' },
    { type: 'tool_use', name: 'Bash', input: { command: 'git status' } }] } })
  check('claude: assistant record interleaves blocks', Array.isArray(a) && a.length === 3
        && a[0].kind === 'thinking' && a[0].text === 'hmm'
        && a[1].kind === 'assistant' && a[1].text === 'reply'
        && a[2].kind === 'tool' && a[2].text === 'Bash(git status)')
  check('claude: phi heredoc suppressed', claudeToEntry({ type: 'assistant',
    message: { content: [{ type: 'tool_use', name: 'Bash',
      input: { command: "node scripts/runner.mjs <<'EOF'\ngoto('x')\nEOF" } }] },
  }) === null)
  const edit = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'tool_use', name: 'Edit', input: { file_path: 'src/app.ts' } }] } })
  check('claude: edit titled like Claude Code', Array.isArray(edit)
        && edit[0].kind === 'tool' && edit[0].text === 'Update(src/app.ts)')
  const abs = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'tool_use', name: 'Read',
      input: { file_path: join(process.cwd(), 'src/x.ts') } }] } })
  check('claude: paths shown cwd-relative', Array.isArray(abs)
        && abs[0].text === 'Read(src/x.ts)')
  check('claude: meta skipped', claudeToEntry({ type: 'user', isMeta: true,
    message: { content: 'x' } }) === null)
  check('claude: [phi-console] echo suppressed', claudeToEntry({ type: 'user',
    message: { content: '[phi-console] do it' } }) === null)

  // Slash commands arrive as XML-ish markup; the console shows what the
  // terminal shows — the typed command line and its printed output.
  const slash = claudeToEntry({ type: 'user', message: { content:
    '<command-message>phi-browser</command-message>\n'
    + '<command-name>/phi-browser</command-name>\n'
    + '<command-args>open wikipedia and hand it to me</command-args>' } })
  check('claude: slash command rendered as the typed line',
        slash?.kind === 'user'
        && slash.text === '/phi-browser open wikipedia and hand it to me')
  const bare = claudeToEntry({ type: 'user', message: { content:
    '<command-name>/model</command-name>\n'
    + '<command-message>model</command-message>\n<command-args></command-args>' } })
  check('claude: argless command keeps just its name',
        bare?.kind === 'user' && bare.text === '/model')
  const stdout = claudeToEntry({ type: 'user', message: { content:
    '<local-command-stdout>Set model to \u001b[1mFable 5\u001b[22m'
    + '</local-command-stdout>' } })
  check('claude: command stdout is a plain line, ANSI stripped',
        stdout?.kind === 'action' && stdout.text === 'Set model to Fable 5')
  check('claude: empty command stdout is machinery', claudeToEntry({
    type: 'user',
    message: { content: '<local-command-stdout></local-command-stdout>' },
  }) === null)

  // Turn edges + background shells: a run_in_background Bash opens a shell,
  // turn_duration closes the turn with the count, the harness's
  // task-notification (a user record naming the tool-use id) closes the
  // shell — and is machinery, never a mirrored prompt.
  const bg = claudeToEntry({ type: 'assistant', message: { content: [
    { type: 'tool_use', id: 'toolu_bg_1', name: 'Bash',
      input: { command: 'sleep 5 && echo done', run_in_background: true } }] } })
  check('claude: background shell still titled like Claude Code',
        Array.isArray(bg) && bg[0].kind === 'tool'
        && bg[0].text === 'Bash(sleep 5 && echo done)')
  const rested = claudeToEntry({ type: 'system', subtype: 'turn_duration',
    timestamp: '2026-07-17T03:00:28Z', durationMs: 28000 })
  const restedPayload = rested && !Array.isArray(rested)
    ? JSON.parse(rested.text) : null
  check('claude: turn_duration becomes the resting summary activity',
        rested?.kind === 'activity' && restedPayload?.phase === 'idle'
        && restedPayload.durationMs === 28000
        && restedPayload.startTs === Date.parse('2026-07-17T03:00:00Z')
        && restedPayload.shellsRunning === 1)
  const woke = claudeToEntry({ type: 'user', timestamp: '2026-07-17T03:01:00Z',
    message: { content: '<task-notification>\n<task-id>b7c</task-id>\n'
      + '<tool-use-id>toolu_bg_1</tool-use-id>\n<status>completed</status>\n'
      + '</task-notification>' } })
  check('claude: shell notification wakes a turn, never mirrors as a prompt',
        woke?.kind === 'activity' && JSON.parse(woke.text).phase === 'working')
  const restedAgain = claudeToEntry({ type: 'system', subtype: 'turn_duration',
    timestamp: '2026-07-17T03:01:02Z', durationMs: 2000 })
  check('claude: notification retired its shell',
        restedAgain?.kind === 'activity'
        && JSON.parse(restedAgain.text).shellsRunning === 0
        && JSON.parse(restedAgain.text).startTs === Date.parse('2026-07-17T03:01:00Z'))

  if (savedConfigDir === undefined) delete process.env.CLAUDE_CONFIG_DIR
  else process.env.CLAUDE_CONFIG_DIR = savedConfigDir
}

// --- toEntry: Codex ------------------------------------------------------------

{
  const u = codexToEntry({ type: 'event_msg', timestamp: '2026-07-17T03:00:00Z',
                           payload: { type: 'user_message', message: 'hello' } })
  check('codex: event_msg user', u?.kind === 'user' && u.text === 'hello')
  const a = codexToEntry({ type: 'event_msg',
                           payload: { type: 'agent_message', message: 'reply' } })
  check('codex: event_msg agent', a?.kind === 'assistant' && a.text === 'reply')
  const started = codexToEntry({ type: 'event_msg',
    payload: { type: 'task_started', turn_id: 'turn-1' } })
  check('codex: task start becomes transient working state',
        started?.kind === 'activity' && started.text === 'working')
  const completed = codexToEntry({ type: 'event_msg',
    payload: { type: 'task_complete', turn_id: 'turn-1' } })
  check('codex: task completion becomes transient waiting state',
        completed?.kind === 'activity' && completed.text === 'waiting')
  const aborted = codexToEntry({ type: 'event_msg',
    payload: { type: 'turn_aborted', turn_id: 'turn-1' } })
  check('codex: aborted turn returns to waiting state',
        aborted?.kind === 'activity' && aborted.text === 'waiting')
  check('codex: response_item message skipped (no duplicates)', codexToEntry({
    type: 'response_item', payload: { role: 'user', content: 'x' } }) === null)
  check('codex: [phi-console] echo suppressed', codexToEntry({ type: 'event_msg',
    payload: { type: 'user_message', message: ' [phi-console] go' } }) === null)
  const th = codexToEntry({ type: 'event_msg',
    payload: { type: 'agent_reasoning', text: '**Scanning repo**' } })
  check('codex: reasoning becomes thinking', th?.kind === 'thinking'
        && th.text === '**Scanning repo**')
  const ran = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'shell',
    arguments: '{"command":["bash","-lc","git status"]}' } })
  check('codex: shell call titled like the TUI', ran?.kind === 'tool'
        && ran.text === 'Ran git status')
  check('codex: wait call is machinery', codexToEntry({ type: 'response_item',
    payload: { type: 'function_call', name: 'wait',
      arguments: '{"cell_id":"2"}' } }) === null)
  check('codex: wait_agent call defers to structured events', codexToEntry({
    type: 'response_item', payload: { type: 'function_call', name: 'wait_agent',
      arguments: '{"timeout_ms":30000}' } }) === null)
  const waitingOne = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_begin', receiver_thread_ids: ['thread-a'],
    receiver_agents: [{ thread_id: 'thread-a', agent_nickname: 'Newton',
      agent_role: 'worker' }] } })
  check('codex: single-agent wait matches the TUI title',
        waitingOne?.kind === 'tool' && waitingOne.text === 'Waiting for Newton [worker]'
        && waitingOne.detail === undefined)
  const waitingMany = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_begin', receiver_thread_ids: ['thread-a', 'thread-b'],
    receiver_agents: [
      { thread_id: 'thread-a', agent_nickname: 'Newton', agent_role: 'worker' },
      { thread_id: 'thread-b', agent_nickname: 'Kepler', agent_role: 'explorer' },
    ] } })
  check('codex: multi-agent wait includes indented agent details',
        waitingMany?.text === 'Waiting for 2 agents'
        && waitingMany.detail === 'Newton [worker]\nKepler [explorer]')
  const finishedWaiting = codexToEntry({ type: 'event_msg', payload: {
    type: 'collab_waiting_end', agent_statuses: [
      { thread_id: 'thread-a', agent_nickname: 'Newton', agent_role: 'worker',
        status: { completed: 'done' } },
      { thread_id: 'thread-b', agent_nickname: 'Kepler', agent_role: 'explorer',
        status: { errored: 'tool timeout' } },
    ], statuses: {} } })
  check('codex: wait completion includes final agent statuses',
        finishedWaiting?.kind === 'tool' && finishedWaiting.text === 'Finished waiting'
        && finishedWaiting.detail === 'Newton [worker]: Completed - done\n'
          + 'Kepler [explorer]: Error - tool timeout')
  check('codex: phi heredoc suppressed', codexToEntry({ type: 'response_item',
    payload: { type: 'custom_tool_call', name: 'exec',
      input: 'const r = await tools.exec_command({ cmd: "node /x/runner.mjs" })' },
  }) === null)
  const repl = codexToEntry({ type: 'response_item', payload: {
    type: 'custom_tool_call', name: 'exec',
    input: 'const r = await tools.exec_command({\n  cmd: "git log --oneline"\n})' } })
  check('codex: repl exec unwraps the real command', repl?.kind === 'tool'
        && repl.text === 'Ran git log --oneline')
  check('codex: repl cell plumbing is machinery', codexToEntry({
    type: 'response_item', payload: { type: 'custom_tool_call', name: 'exec',
      input: 'const r = await tools.write_stdin({ session_id: 1, chars: "" })' },
  }) === null)
  const plan = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'update_plan',
    arguments: '{"plan":[{"step":"scan","status":"completed"},'
      + '{"step":"fix","status":"pending"}]}' } })
  check('codex: update_plan cell', plan?.kind === 'tool' && plan.text === 'Updated Plan'
        && plan.detail === '✔ scan · ○ fix')
  const patch = codexToEntry({ type: 'response_item', payload: {
    type: 'function_call', name: 'apply_patch',
    arguments: JSON.stringify({
      input: '*** Begin Patch\n*** Update File: src/a.ts\n'
        + '*** Add File: src/b.ts\n*** End Patch' }) } })
  check('codex: apply_patch names its files', patch?.kind === 'tool'
        && patch.text === 'Edited src/a.ts (+1 more)')
}

// --- toEntry: Hermes -----------------------------------------------------------

{
  const u = hermesToEntry({ id: 5, role: 'user', content: 'hello', timestamp: 1752741600.5 })
  check('hermes: user row', u?.kind === 'user' && u.text === 'hello'
        && u.ts === Math.round(1752741600.5 * 1000))
  const a = hermesToEntry({ id: 6, role: 'assistant', content: 'reply' })
  check('hermes: assistant row', a?.kind === 'assistant' && a.text === 'reply')
  const m = hermesToEntry({ id: 7, role: 'user',
    content: '\x00json:[{"type":"text","text":"multi"},{"type":"image_url","image_url":{}}]' })
  check('hermes: multimodal keeps text blocks', m?.kind === 'user' && m.text === 'multi')
  check('hermes: broken multimodal skipped', hermesToEntry({ id: 8, role: 'user',
    content: '\x00json:not-json' }) === null)
  check('hermes: tool row skipped', hermesToEntry({ id: 9, role: 'tool',
    content: 'x' }) === null)
  check('hermes: [phi-console] echo suppressed', hermesToEntry({ id: 10,
    role: 'user', content: '[phi-console] go' }) === null)
}

// --- toEntry: OpenClaw ---------------------------------------------------------

{
  const u = openclawToEntry({ type: 'message', timestamp: '2026-07-17T03:00:00Z',
    message: { role: 'user', content: [{ type: 'text', text: 'hello' }] } })
  check('openclaw: user blocks', u?.kind === 'user' && u.text === 'hello' && u.ts > 0)
  const us = openclawToEntry({ type: 'message',
    message: { role: 'user', content: 'plain string', timestamp: 1752741600000 } })
  check('openclaw: user string content', us?.kind === 'user'
        && us.text === 'plain string' && us.ts === 1752741600000)
  const a = openclawToEntry({ type: 'message', message: { role: 'assistant',
    content: [{ type: 'thinking', thinking: 'hmm' }, { type: 'text', text: 'reply' },
              { type: 'toolCall', id: 't1', name: 'exec', arguments: {} }] } })
  check('openclaw: assistant text only', a?.kind === 'assistant' && a.text === 'reply')
  check('openclaw: toolResult skipped', openclawToEntry({ type: 'message',
    message: { role: 'toolResult', toolCallId: 't1', content: [] } }) === null)
  check('openclaw: session header skipped', openclawToEntry({ type: 'session',
    version: 3, id: 's1' }) === null)
  check('openclaw: compaction skipped', openclawToEntry({ type: 'compaction',
    summary: 's' }) === null)
  check('openclaw: [phi-console] echo suppressed', openclawToEntry({ type: 'message',
    message: { role: 'user', content: '[phi-console] go' } }) === null)
}

// --- SqliteTail: Hermes-shaped database ----------------------------------------

{
  const db = join(dir, 'state.db')
  sql(db, `CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT, role TEXT, content TEXT, timestamp REAL,
    active INTEGER DEFAULT 1);`)
  sql(db, `INSERT INTO messages (session_id, role, content, timestamp) VALUES
    ('s1','user','hello',1752741600.0),
    ('s1','assistant','reply',1752741601.0),
    ('s2','user','other session',1752741602.0),
    ('s1','tool','machinery',1752741603.0),
    ('s1','user','inactive',1752741604.0);`)
  sql(db, `UPDATE messages SET active = 0 WHERE content = 'inactive';`)
  const tail = new SqliteTail(db, (since) => hermesQuery('s1', since), hermesRowToItem)
  const first = tail.readNew()
  check('hermes tail: session+role filtered, ordered',
        first.length === 2 && first[0].index < first[1].index
        && JSON.parse(first[0].raw).content === 'hello'
        && JSON.parse(first[1].raw).content === 'reply',
        JSON.stringify(first.map((i) => i.index)))
  check('hermes tail: quiet when nothing new', tail.readNew().length === 0)
  sql(db, `INSERT INTO messages (session_id, role, content, timestamp) VALUES
    ('s1','user','again',1752741605.0);`)
  const second = tail.readNew()
  check('hermes tail: only appended rows', second.length === 1
        && JSON.parse(second[0].raw).content === 'again')
  let threw = false
  try { new SqliteTail(join(dir, 'missing.db'), () => '', () => null).readNew() }
  catch { threw = true }
  check('sqlite tail: missing db throws (transcript gone)', threw)
}

// --- Transcript + discovery + delivery: OpenClaw-shaped state dir ---------------

{
  const state = join(dir, 'openclaw-state')
  const sessions = join(state, 'agents', 'main', 'sessions')
  execFileSync('/bin/mkdir', ['-p', sessions])
  const line = (o) => JSON.stringify(o) + '\n'
  const transcript = join(sessions, 'sess-fresh.jsonl')
  writeFileSync(transcript,
    line({ type: 'session', version: 3, id: 'sess-fresh' })
    + line({ type: 'message', message: { role: 'user', content: 'open example.com' } })
    + line({ type: 'message', message: { role: 'assistant', content: [
        { type: 'text', text: 'on it' },
        { type: 'toolCall', id: 't1', name: 'exec',
          arguments: { command: 'node runner.mjs task-abc123' } }] } }))
  const entries = readFileSync(transcript, 'utf8').split('\n').filter(Boolean)
    .map((l) => openclawToEntry(JSON.parse(l))).filter(Boolean)
  check('openclaw transcript: events → console lines', entries.length === 2
        && entries[0].kind === 'user' && entries[0].text === 'open example.com'
        && entries[1].text === 'on it', JSON.stringify(entries))

  // Decoys: an ended session whose transcript also mentions the task id
  // (stale mtime), and the fresh session's trajectory artifact (fresh AND
  // evidenced — only the filename filter keeps it out).
  const stale = join(sessions, 'sess-stale.jsonl')
  writeFileSync(stale, line({ type: 'message',
    message: { role: 'user', content: 'node runner.mjs task-abc123' } }))
  const old = (Date.now() - 2 * 60 * 60 * 1000) / 1000
  utimesSync(stale, old, old)
  writeFileSync(join(sessions, 'sess-fresh.trajectory.jsonl'),
                line({ note: 'node runner.mjs task-abc123' }))
  writeFileSync(join(sessions, 'sessions.json'), '{}')

  const env = { PHI_OPENCLAW_STATE_DIR: state, OPENCLAW_SHELL: 'exec' }
  const saved = { OPENCLAW_CLI: process.env.OPENCLAW_CLI }
  delete process.env.OPENCLAW_CLI
  for (const [k, v] of Object.entries(env)) { saved[k] = process.env[k]; process.env[k] = v }
  try {
    const hit = discoverOpenclawTranscript('task-abc123')
    check('openclaw discovery: evidence match (stale + trajectory decoys skipped)',
          hit?.sessionKey === 'sess-fresh'
          && hit.path === transcript && hit.format === 'openclaw', JSON.stringify(hit))
    check('openclaw discovery: no evidence → no mirror',
          discoverOpenclawTranscript('task-elsewhere') === null)
    delete process.env.OPENCLAW_SHELL
    check('openclaw discovery: env gate', discoverOpenclawTranscript('task-abc123') === null)
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v
    }
  }

  // Delivery seam: a stub CLI proves argv shape and both exit paths.
  const okBin = join(dir, 'openclaw-ok')
  const argsFile = join(dir, 'openclaw-args')
  writeFileSync(okBin, `#!/bin/sh\nprintf '%s\\n' "$@" > ${argsFile}\nexit 0\n`)
  chmodSync(okBin, 0o755)
  const badBin = join(dir, 'openclaw-bad')
  writeFileSync(badBin, '#!/bin/sh\nexit 3\n')
  chmodSync(badBin, 0o755)
  process.env.PHI_OPENCLAW_BIN = okBin
  let delivered = false
  try { await deliverOpenclaw('sess-fresh', '[phi-console] hi'); delivered = true } catch {}
  const argv = delivered ? readFileSync(argsFile, 'utf8').trim().split('\n') : []
  check('openclaw delivery: CLI argv', delivered
        && argv.join(' ') === 'agent --session-id sess-fresh --message [phi-console] hi',
        argv.join(' '))
  process.env.PHI_OPENCLAW_BIN = badBin
  let rejected = false
  try { await deliverOpenclaw('sess-fresh', 'x') } catch { rejected = true }
  check('openclaw delivery: nonzero exit rejects (bridge retries)', rejected)
  delete process.env.PHI_OPENCLAW_BIN
}

// --- OpenClaw console bridge ----------------------------------------------------

{
  let task = { taskId: 'oc-task', status: 'running', pendingUserMessages: 1 }
  let tasks = () => [task]
  let reads = 0
  const delivered = []
  const channel = {
    async send(type) {
      if (type === 'agentSpace.list') return { tasks: tasks() }
      if (type === 'agentSpace.readUserMessages') {
        reads += 1
        task = { ...task, pendingUserMessages: 0 }
        return { messages: [{ text: 'open example.com' }] }
      }
      throw new Error(`unexpected send: ${type}`)
    },
  }
  const ctl = { taskId: 'oc-task', agentPid: process.pid }
  let fail = false
  const bridge = new OpenclawConsoleBridge('sess-fresh', {
    deliver: async (sessionId, text) => {
      if (fail) throw new Error('gateway down')
      delivered.push({ sessionId, text })
    },
  })
  check('openclaw bridge: live browser round keeps authority over its queue',
        await bridge.deliverPending(ctl, channel) === false
        && reads === 0 && delivered.length === 0)
  task = { ...task, status: 'idle' }
  fail = true
  check('openclaw bridge: failed delivery holds the command for retry',
        await bridge.deliverPending(ctl, channel) === false
        && reads === 1 && delivered.length === 0
        && bridge.undelivered.length === 1)
  fail = false
  check('openclaw bridge: idle drain delivers through the CLI seam, marked',
        await bridge.deliverPending(ctl, channel) === false
        && reads === 1 && delivered.length === 1
        && delivered[0].sessionId === 'sess-fresh'
        && delivered[0].text === '[phi-console] open example.com'
        && bridge.undelivered.length === 0)
  tasks = () => []
  check('openclaw bridge: vanished task tells the daemon to exit',
        await bridge.deliverPending(ctl, channel) === true)
}

// --- Hermes console delivery ----------------------------------------------------

{
  // Delivery seam: a stub CLI proves argv shape, the HERMES_SESSION_ID env
  // strip (the daemon inherits the driving session's export; the one-shot
  // must bind to --resume), the stale-session guard (an unknown --resume
  // silently starts a NEW session, so delivery must refuse it up front),
  // and both exit paths.
  const home = join(dir, 'hermes-deliver-home')
  execFileSync('/bin/mkdir', ['-p', home])
  sql(join(home, 'state.db'),
      `CREATE TABLE sessions (id TEXT PRIMARY KEY);
       INSERT INTO sessions VALUES ('sess-h');`)
  const okBin = join(dir, 'hermes-ok')
  const argsFile = join(dir, 'hermes-args')
  const envFile = join(dir, 'hermes-env')
  writeFileSync(okBin, `#!/bin/sh\nprintf '%s\\n' "$@" > ${argsFile}\n`
    + `printf '%s' "\${HERMES_SESSION_ID-unset}" > ${envFile}\nexit 0\n`)
  chmodSync(okBin, 0o755)
  const badBin = join(dir, 'hermes-bad')
  writeFileSync(badBin, '#!/bin/sh\nexit 3\n')
  chmodSync(badBin, 0o755)
  const saved = { HERMES_SESSION_ID: process.env.HERMES_SESSION_ID,
                  PHI_HERMES_HOME: process.env.PHI_HERMES_HOME }
  process.env.HERMES_SESSION_ID = 'leaked-from-driver'
  process.env.PHI_HERMES_HOME = home
  process.env.PHI_HERMES_BIN = okBin
  let delivered = false
  try { await deliverHermes('sess-h', '[phi-console] hi'); delivered = true } catch {}
  const argv = delivered ? readFileSync(argsFile, 'utf8').trim().split('\n') : []
  check('hermes delivery: CLI argv', delivered
        && argv.join(' ') === '--resume sess-h -z [phi-console] hi', argv.join(' '))
  check('hermes delivery: session env stripped from the one-shot',
        delivered && readFileSync(envFile, 'utf8') === 'unset')
  let staleRejected = false
  try { await deliverHermes('sess-gone', 'x') } catch { staleRejected = true }
  check('hermes delivery: stale session refused (no silent new-session fork)',
        staleRejected)
  process.env.PHI_HERMES_BIN = badBin
  let rejected = false
  try { await deliverHermes('sess-h', 'x') } catch { rejected = true }
  check('hermes delivery: nonzero exit rejects (bridge retries)', rejected)
  delete process.env.PHI_HERMES_BIN
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k]; else process.env[k] = v
  }

  // The bridge subclass drains through the injected seam like OpenClaw's.
  const delivered2 = []
  const hb = new HermesConsoleBridge('sess-h', {
    deliver: async (sessionId, text) => delivered2.push({ sessionId, text }),
  })
  const channel = {
    async send(type) {
      if (type === 'agentSpace.list') {
        return { tasks: [{ taskId: 'h-task', status: 'idle', pendingUserMessages: 1 }] }
      }
      if (type === 'agentSpace.readUserMessages') {
        return { messages: [{ text: 'scroll down' }] }
      }
      throw new Error(`unexpected send: ${type}`)
    },
  }
  check('hermes bridge: idle drain delivers through the CLI seam, marked',
        await hb.deliverPending({ taskId: 'h-task', agentPid: process.pid }, channel)
          === false
        && delivered2.length === 1 && delivered2[0].sessionId === 'sess-h'
        && delivered2[0].text === '[phi-console] scroll down')
}

// --- discovery: Hermes ---------------------------------------------------------

{
  const home = join(dir, 'hermes-home')
  execFileSync('/bin/mkdir', ['-p', home])
  sql(join(home, 'state.db'), 'CREATE TABLE messages (id INTEGER PRIMARY KEY);')
  const saved = { PHI_HERMES_HOME: process.env.PHI_HERMES_HOME,
                  HERMES_SESSION_ID: process.env.HERMES_SESSION_ID }
  process.env.PHI_HERMES_HOME = home
  process.env.HERMES_SESSION_ID = '20260717_120000_abc123'
  try {
    const hit = discoverHermesTranscript()
    check('hermes discovery: env session id', hit?.sessionKey === '20260717_120000_abc123'
          && hit.path === join(home, 'state.db') && hit.format === 'hermes')
    delete process.env.HERMES_SESSION_ID
    check('hermes discovery: env gate', discoverHermesTranscript() === null)
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v
    }
  }
}

// --- toEntry + discovery: Cursor -----------------------------------------------

{
  const line = (o) => JSON.stringify(o) + '\n'
  const msg = (role, content) => ({ role, message: { role, content } })

  // toEntry: the prompt envelope, machinery skipping, echo suppression.
  const envelope = '<manually_attached_skills>\n# phi-browser\n…runner.mjs…\n'
    + '</manually_attached_skills>\n<timestamp>Tuesday, Jul 21, 2026</timestamp>\n'
    + '<user_query>\nopen wikipedia for me\n</user_query>'
  const u = cursorToEntry(msg('user', [{ type: 'text', text: envelope }]))
  check('cursor: user query unwrapped from the prompt envelope',
        u?.kind === 'user' && u.text === 'open wikipedia for me', JSON.stringify(u))
  const plain = cursorToEntry(msg('user', [{ type: 'text', text: 'plain follow-up' }]))
  check('cursor: plain user text passes through',
        plain?.kind === 'user' && plain.text === 'plain follow-up')
  check('cursor: all-envelope line skipped', cursorToEntry(msg('user', [{
    type: 'text', text: '<additional_data>rules</additional_data>' }])) === null)
  check('cursor: [phi-console] echo suppressed', cursorToEntry(msg('user', [{
    type: 'text',
    text: '<user_query>[phi-console] scroll down</user_query>' }])) === null)
  const a = cursorToEntry(msg('assistant', [
    { type: 'text', text: 'opening' },
    { type: 'tool_use', name: 'Shell', input: { command: 'node x.mjs' } },
    { type: 'text', text: 'now' }]))
  check('cursor: assistant text blocks joined, tool_use skipped',
        a?.kind === 'assistant' && a.text === 'opening\n\nnow')
  check('cursor: turn_ended skipped',
        cursorToEntry({ type: 'turn_ended', status: 'success' }) === null)

  // Discovery: a state dir with two fresh phi-driving transcripts (the real
  // session and a marker decoy) plus a stale one. Only the recorded heredoc
  // source singles out the real session; without it two candidates is a
  // guess and discovery must decline.
  const state = join(dir, 'cursor-state')
  const tdir = (proj, id) => join(state, 'projects', proj, 'agent-transcripts', id)
  const source = "const task = await ensureAgentSpace('cursor probe')\ncliLog(task)\n"
  const command = "node /Users/u/.cursor/skills/phi-browser/scripts/runner.mjs "
    + `<<'EOF'\n${source}EOF`
  execFileSync('/bin/mkdir', ['-p', tdir('proj-a', 'sess-cur-fresh'),
                              tdir('proj-b', 'sess-cur-decoy'),
                              tdir('proj-a', 'sess-cur-stale')])
  const transcript = join(tdir('proj-a', 'sess-cur-fresh'), 'sess-cur-fresh.jsonl')
  writeFileSync(transcript,
    line(msg('user', [{ type: 'text', text: envelope }]))
    + line({ role: 'assistant', message: { role: 'assistant', content: [
        { type: 'text', text: 'running it' },
        { type: 'tool_use', name: 'Shell', input: { command } }] } })
    + line({ type: 'turn_ended', status: 'success' }))
  const decoy = join(tdir('proj-b', 'sess-cur-decoy'), 'sess-cur-decoy.jsonl')
  writeFileSync(decoy, line(msg('user', [{ type: 'text',
    text: 'ran phi-browser via scripts/runner.mjs earlier' }])))
  const stale = join(tdir('proj-a', 'sess-cur-stale'), 'sess-cur-stale.jsonl')
  writeFileSync(stale, line(msg('user', [{ type: 'text',
    text: 'phi-browser runner.mjs long ago' }])))
  const old = (Date.now() - 2 * 60 * 60 * 1000) / 1000
  utimesSync(stale, old, old)

  const saved = {}
  for (const k of ['PHI_CURSOR_STATE_DIR', 'CURSOR_AGENT', 'CURSOR_TRACE_ID',
                   '__CFBundleIdentifier']) {
    saved[k] = process.env[k]
    delete process.env[k]
  }
  process.env.PHI_CURSOR_STATE_DIR = state
  process.env.CURSOR_TRACE_ID = 'trace-1'
  try {
    const hit = discoverCursorTranscript(source)
    check('cursor discovery: recorded heredoc source singles out the session',
          hit?.sessionKey === 'sess-cur-fresh'
          && hit.path === transcript && hit.format === 'cursor', JSON.stringify(hit))
    check('cursor discovery: two marked candidates without source → no mirror',
          discoverCursorTranscript('') === null)
    utimesSync(decoy, old, old)
    check('cursor discovery: sole fresh marked transcript is the fallback',
          discoverCursorTranscript('')?.sessionKey === 'sess-cur-fresh')
    delete process.env.CURSOR_TRACE_ID
    check('cursor discovery: env gate', discoverCursorTranscript(source) === null)
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]; else process.env[k] = v
    }
    if (saved.PHI_CURSOR_STATE_DIR === undefined) delete process.env.PHI_CURSOR_STATE_DIR
  }
}

// --- Cursor console notice ------------------------------------------------------

{
  // No transport can wake Cursor, so its bridge slot must NEVER drain the
  // queue (the agent's next round owns it) and must answer each newly
  // queued command with exactly one console notice.
  let task = { taskId: 'cur-task', status: 'running', pendingUserMessages: 1 }
  let tasks = () => [task]
  const logged = []
  let drained = 0
  const channel = {
    async send(type, params) {
      if (type === 'agentSpace.list') return { tasks: tasks() }
      if (type === 'agentSpace.log') { logged.push(...params.entries); return { ok: true } }
      if (type === 'agentSpace.readUserMessages') { drained += 1; return { messages: [] } }
      throw new Error(`unexpected send: ${type}`)
    },
  }
  const ctl = { taskId: 'cur-task', agentPid: process.pid }
  const notice = new CursorConsoleNotice()
  check('cursor notice: live round keeps the console quiet',
        await notice.deliverPending(ctl, channel) === false && logged.length === 0)
  task = { ...task, status: 'idle' }
  check('cursor notice: idle queued command gets one notice, queue untouched',
        await notice.deliverPending(ctl, channel) === false
        && logged.length === 1 && logged[0].kind === 'error'
        && logged[0].text.includes('queued') && drained === 0)
  check('cursor notice: no repeat for the same queue',
        await notice.deliverPending(ctl, channel) === false && logged.length === 1)
  task = { ...task, pendingUserMessages: 2 }
  check('cursor notice: a further command notices again',
        await notice.deliverPending(ctl, channel) === false && logged.length === 2)
  task = { ...task, pendingUserMessages: 0 }
  await notice.deliverPending(ctl, channel)
  task = { ...task, pendingUserMessages: 1 }
  check('cursor notice: drained queue re-arms the notice',
        await notice.deliverPending(ctl, channel) === false
        && logged.length === 3 && drained === 0)
  tasks = () => []
  check('cursor notice: vanished task tells the daemon to exit',
        await notice.deliverPending(ctl, channel) === true)
}

// --- deferred completion (mirror-core) -----------------------------------------

{
  const key = `selftest-defer-${process.pid}`
  writeDaemonControl(key, { taskId: 'task-1', transcriptPath: '/tmp/x',
                            pid: process.pid, ts: Date.now() })
  const accepted = requestDeferredComplete(key, 'task-1',
                                           { status: 'failure', message: 'why' })
  const ctl = readDaemonControl(key)
  check('defer: live daemon claim accepts the intent', accepted === true
        && ctl?.completing?.status === 'failure' && ctl.completing.message === 'why'
        && ctl.completing.ts > 0 && ctl.taskId === 'task-1')
  check('defer: wrong task is refused',
        requestDeferredComplete(key, 'task-OTHER', { status: 'success' }) === false)
  clearDaemonControl(key)
  check('defer: no control file → complete directly',
        requestDeferredComplete(key, 'task-1', { status: 'success' }) === false)
  const deadKey = `selftest-defer-dead-${process.pid}`
  writeDaemonControl(deadKey, { taskId: 'task-1', transcriptPath: '/tmp/x',
                                pid: 99999999, ts: Date.now() })
  check('defer: dead daemon pid → complete directly',
        requestDeferredComplete(deadKey, 'task-1', { status: 'success' }) === false)
  clearDaemonControl(deadKey)
}

// --- summary -------------------------------------------------------------------

rmSync(dir, { recursive: true, force: true })
const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed`)
process.exit(failed.length ? 1 : 0)
