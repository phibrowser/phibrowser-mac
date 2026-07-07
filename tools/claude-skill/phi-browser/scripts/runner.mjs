#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// phi-browser heredoc runner: reads a script from stdin and executes it with
// all helpers in scope. Usage:
//   node runner.mjs <<'EOF'
//   const task = await ensureAgentSpace('my task')
//   cliLog(await snapshotText())
//   EOF

// The CDP client rides Node's global WebSocket (stable since Node 22). Fail
// with the actual requirement instead of a ReferenceError from deep inside
// the first connect.
if (typeof WebSocket === 'undefined') {
  console.error(
    `phi-browser: Node >= 22 required (global WebSocket missing; ` +
    `running ${process.version})`)
  process.exit(2)
}

const { __dispose, ...surface } = await import('./lib/helpers.mjs')

// A killed round (Bash-tool timeout, Ctrl-C) should still flip the Space's
// busy badge back to idle — best effort, the default handler would just die.
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    __dispose().catch(() => {}).finally(() => process.exit(130))
  })
}

let source = ''
process.stdin.setEncoding('utf8')
for await (const chunk of process.stdin) source += chunk

if (!source.trim()) {
  console.error('phi-browser: empty script on stdin')
  process.exit(2)
}

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const names = Object.keys(surface)
const values = names.map((n) => surface[n])

let exitCode = 0
try {
  const fn = new AsyncFunction(...names, source)
  await fn(...values)
} catch (err) {
  console.error(`phi-browser error: ${err?.message || err}`)
  // A few stack frames locate the failing line inside the heredoc (the
  // script compiles as an anonymous async function, so frames read
  // "<anonymous>:LINE"). Skip the message line already printed above.
  const frames = String(err?.stack || '')
    .split('\n').slice(1, 6).join('\n')
  if (frames) console.error(frames)
  exitCode = 1
} finally {
  await __dispose().catch(() => {})
}
process.exit(exitCode)
