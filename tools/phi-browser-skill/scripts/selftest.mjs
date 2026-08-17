#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// Self-test for the phi-browser skill. Run after changing the skill:
//   node scripts/selftest.mjs
//
// Needs a running Phi Browser with the CDP endpoint enabled (see
// references/install.md) and at least one browser window open. Drives a
// throwaway hidden agent Space named 'phi-skill-selftest' against a local
// HTTP server — no external sites, safe to run while the user browses.
// Takes ~60s; exits non-zero when any check fails.

import { spawnSync } from 'node:child_process'
import { createServer } from 'node:http'
import { fileURLToPath } from 'node:url'
import * as H from './lib/helpers.mjs'

const PORT = 8379
const BASE = `http://127.0.0.1:${PORT}`
const SPACE = 'phi-skill-selftest'

// The SPA page is deliberately hostile: controls mount late (resolution
// retries), the list keeps streaming while a click glides (moving-target
// re-measure), and readiness signals arrive on a delay (waitForFunction).
const SPA = `<!doctype html><title>spa</title>
<a href="${BASE}/fast">a link</a><ul id="list"></ul><script>
let n = 0
const t = setInterval(() => {
  const li = document.createElement('li'); li.className = 'item'; li.textContent = 'item ' + (++n)
  document.getElementById('list').appendChild(li)
  if (n >= 20) clearInterval(t)
}, 250)
setTimeout(() => {
  const b = document.createElement('button'); b.id = 'late'; b.textContent = 'Late'
  b.onclick = () => { window.clicked = true }
  document.body.appendChild(b)
}, 3000)
setTimeout(() => {
  const i = document.createElement('input'); i.id = 'latefield'
  document.body.appendChild(i)
}, 4000)
setTimeout(() => { window.flag = true }, 5000)
</` + `script>`

const INPUT = `<!doctype html><title>input</title>
<style>
body{height:2400px;margin:0}
#input-target{position:absolute;left:820px;top:500px;width:140px;height:80px}
#input-field{position:absolute;left:120px;top:180px;width:280px;height:40px}
#reject-field{position:absolute;left:120px;top:280px;width:280px;height:40px}
</style>
<input id="input-field" value="old">
<input id="reject-field" value="locked">
<button id="input-target">Input target</button><script>
window.inputTrace = []
window.inputClicked = false
window.inputEnter = 0
for (const type of ['pointermove', 'mousemove', 'pointerdown', 'mousedown',
                    'pointerup', 'mouseup', 'click', 'focus', 'select',
                    'keydown', 'keypress', 'beforeinput', 'input', 'keyup',
                    'change', 'wheel', 'scroll']) {
  addEventListener(type, (event) => inputTrace.push({
    type, x: event.clientX, y: event.clientY, trusted: event.isTrusted,
    at: performance.now(), target: event.target.id || event.target.tagName,
    key: event.key || null, data: event.data ?? null,
    inputType: event.inputType || null, meta: event.metaKey || false,
    shift: event.shiftKey || false,
    dx: event.deltaX ?? null, dy: event.deltaY ?? null
  }), true)
}
document.getElementById('input-target').onclick = () => { window.inputClicked = true }
document.getElementById('input-field').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') window.inputEnter++
})
document.getElementById('reject-field').addEventListener('input', (event) => {
  event.target.value = 'locked'
})
</` + `script>`

// Navigation's quick consent pass finishes before this banner mounts. The
// first real input must notice it, activate Accept with trusted pointer input,
// and only then reach the underlying control.
const LATE_CONSENT = `<!doctype html><title>late consent</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center}
#underlay{width:220px;height:90px}
#late-cookie-consent{position:fixed;inset:0;z-index:1000;background:rgba(0,0,0,.45);
  display:grid;place-items:center}
#consent-card{background:white;padding:40px;border-radius:12px}
</style>
<button id="underlay">Continue underneath</button><script>
window.gateTrace = []
document.getElementById('underlay').addEventListener('click', (event) => {
  window.gateTrace.push({kind: 'underlay', trusted: event.isTrusted, at: performance.now()})
})
setTimeout(() => {
  const overlay = document.createElement('div')
  overlay.id = 'late-cookie-consent'
  overlay.className = 'cookie-consent'
  overlay.innerHTML = '<div id="consent-card">Cookies help this test work. '
    + '<button id="onetrust-accept-btn-handler">Accept all cookies</button></div>'
  overlay.querySelector('button').addEventListener('click', (event) => {
    window.gateTrace.push({kind: 'consent', trusted: event.isTrusted, at: performance.now()})
    overlay.remove()
  })
  document.body.appendChild(overlay)
}, 2000)
</` + `script>`

const OCCLUDED = `<!doctype html><title>occluded</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center}
#covered{width:220px;height:90px}
#shield{position:fixed;left:calc(50% - 130px);top:calc(50% - 65px);
  width:260px;height:130px;z-index:10;background:#ddd;display:grid;place-items:center}
</style>
<button id="covered">Covered target</button>
<div id="shield">Ordinary blocking layer</div><script>
window.coveredClicks = 0
window.coveredTrusted = false
document.getElementById('covered').addEventListener('click', (event) => {
  window.coveredClicks++
  window.coveredTrusted = event.isTrusted
})
</` + `script>`

const CF_AUTO = `<!doctype html><title>Just a moment...</title>
<div id="challenge-stage">Checking your browser</div>
<button id="after-cf" hidden>Continue</button><script>
window.afterCfClicks = 0
document.getElementById('after-cf').addEventListener('click', () => window.afterCfClicks++)
setTimeout(() => {
  document.title = 'cleared'
  document.getElementById('challenge-stage').remove()
  document.getElementById('after-cf').hidden = false
}, 600)
</` + `script>`

const CF_STUCK = `<!doctype html><title>Just a moment...</title>
<div id="challenge-stage">Checking your browser</div>
<button id="behind-cf">Must not click</button><script>
window.behindCfClicks = 0
document.getElementById('behind-cf').addEventListener('click', () => window.behindCfClicks++)
</` + `script>`

const CF_FALSE_TITLE = `<!doctype html><title>Just a moment...</title>
<main><h1>Ordinary page</h1><p>The application is ready.</p></main>`

const CF_BLOCKED = `<!doctype html><title>Attention Required! | Cloudflare</title>
<div id="cf-error-details">Sorry, you have been blocked</div>`

function startServer() {
  return new Promise((resolve, reject) => {
    const srv = createServer((req, res) => {
      res.setHeader('content-type', 'text/html')
      const page = (name) => `<!doctype html><title>${name}</title><h1>${name}</h1>`
      if (req.url.startsWith('/slow')) {
        // Delay the HEADERS so Page.navigate itself blocks — the goto-budget
        // tests need a navigation that cannot commit quickly.
        setTimeout(() => res.end(page('slow')), 8000)
      } else if (req.url.startsWith('/spa')) {
        res.end(SPA)
      } else if (req.url.startsWith('/input')) {
        res.end(INPUT)
      } else if (req.url.startsWith('/late-consent')) {
        res.end(LATE_CONSENT)
      } else if (req.url.startsWith('/occluded')) {
        res.end(OCCLUDED)
      } else if (req.url.startsWith('/cf-auto')) {
        res.end(CF_AUTO)
      } else if (req.url.startsWith('/cf-stuck')) {
        res.end(CF_STUCK)
      } else if (req.url.startsWith('/cf-false-title')) {
        res.end(CF_FALSE_TITLE)
      } else if (req.url.startsWith('/cf-blocked')) {
        res.end(CF_BLOCKED)
      } else {
        res.end(page('fast'))
      }
    })
    srv.once('error', (err) => reject(
      new Error(`selftest server failed on port ${PORT}: ${err.message}`)))
    srv.listen(PORT, '127.0.0.1', () => resolve(srv))
  })
}

const results = []
function check(name, ok, detail = '') {
  results.push({ name, ok: !!ok, detail })
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? `  (${detail})` : ''}`)
}

function seededRandom(seed) {
  let value = seed >>> 0
  return () => {
    value = (Math.imul(value, 1664525) + 1013904223) >>> 0
    return value / 2 ** 32
  }
}

async function main() {
  // --- runner: heredoc scripts get require() ---------------------------------
  const runner = fileURLToPath(new URL('./runner.mjs', import.meta.url))
  const r = spawnSync(process.execPath, [runner], {
    input: "cliLog(typeof require('node:fs').readFileSync)",
    encoding: 'utf8', timeout: 30000,
  })
  check('runner provides require in heredoc', r.stdout.includes('function'),
        (r.stdout + r.stderr).trim().slice(0, 60))

  // --- concurrent openTab: no hang, no duplicate/lost tabs -------------------
  const first = await H.ensureAgentSpace(SPACE)
  let s = Date.now()
  const urls = Array.from({ length: 12 }, (_, i) => `${BASE}/fast?lane=${i + 1}`)
  const opened = await Promise.all(urls.map((u) =>
    H.openTab(u).catch((e) => ({ error: String(e.message || e) }))))
  const errors = opened.filter((o) => o.error)
  const distinct = new Set(opened.filter((o) => o.targetId).map((o) => o.targetId))
  check('concurrent openTab x12: no errors', errors.length === 0,
        errors.map((e) => e.error).join('; ').slice(0, 80))
  check('concurrent openTab x12: distinct tabs', distinct.size === 12,
        `${distinct.size}/12 in ${Date.now() - s}ms`)
  check('concurrent openTab x12: reused the blank seed once',
        opened.filter((o) => o.reused).length <= 1)

  // --- zombie heal: window death must not strand the task record -------------
  for (const t of await H.listTabs()) await H.closeTab(t.targetId)
  await H.wait(1)
  const healed = await H.ensureAgentSpace(SPACE)
  check('zombie Space heals on re-ensure', healed.spaceId !== first.spaceId,
        `spaceId ${first.spaceId} -> ${healed.spaceId}`)
  const afterHeal = await H.openTab(`${BASE}/fast?afterheal`)
  check('openTab works after heal', !!afterHeal.targetId)

  // --- goto: budget honored, degrade instead of hang -------------------------
  s = Date.now()
  const fast = await H.goto(`${BASE}/fast?goto`, { timeout: 10 })
  check('goto fast page', fast.title === 'fast', `${Date.now() - s}ms`)
  s = Date.now()
  let threw = null
  try { await H.goto(`${BASE}/slow`, { timeout: 4 }) } catch (e) { threw = e }
  const tightMs = Date.now() - s
  check('goto over-budget navigation throws promptly',
        threw && /timed out/i.test(threw.message) && tightMs < 7000,
        `${tightMs}ms: ${String(threw?.message).slice(0, 50)}`)
  s = Date.now()
  const slow = await H.goto(`${BASE}/slow?roomy`, { timeout: 15 })
  check('goto slow page within budget', slow.title === 'slow', `${Date.now() - s}ms`)
  s = Date.now()
  const wfl = await H.waitForLoad({ timeout: 5 })
  check('waitForLoad instant on loaded page', !!wfl.ready && Date.now() - s < 1500)

  // --- pointer model: curved path with acceleration and bounded samples -----
  const modelFrom = { x: 40, y: 40 }
  const modelTo = { x: 890, y: 540 }
  const pointerModel = H.__pointerTrajectoryForTest(modelFrom, modelTo, {
    random: seededRandom(7), bounds: { width: 1000, height: 700 },
  })
  const modelDx = modelTo.x - modelFrom.x
  const modelDy = modelTo.y - modelFrom.y
  const modelLength = Math.hypot(modelDx, modelDy)
  const crossTrack = pointerModel.points.map((point) => Math.abs(
    modelDx * (modelFrom.y - point.y) - (modelFrom.x - point.x) * modelDy
  ) / modelLength)
  const modelSpeeds = pointerModel.points.map((point, index) => {
    const previous = index ? pointerModel.points[index - 1] : { ...modelFrom, at: 0 }
    return Math.hypot(point.x - previous.x, point.y - previous.y)
      / Math.max(1, point.at - previous.at)
  })
  const modelIntervals = pointerModel.points.map((point, index) =>
    point.at - (index ? pointerModel.points[index - 1].at : 0))
  const peakSpeed = Math.max(...modelSpeeds)
  const microModel = H.__pointerTrajectoryForTest(
    { x: 40, y: 40 }, { x: 44, y: 43 }, { random: seededRandom(7) })
  check('pointer model follows a smooth curved trace',
        Math.max(...crossTrack) >= 10 && pointerModel.points.length >= 20,
        `${pointerModel.points.length} points, ${Math.max(...crossTrack).toFixed(1)}px bend`)
  check('pointer model accelerates and decelerates',
        peakSpeed > modelSpeeds[0] * 3 && peakSpeed > modelSpeeds.at(-1) * 3,
        `${Math.round(modelSpeeds[0] * 1000)} → ${Math.round(peakSpeed * 1000)}`
          + ` → ${Math.round(modelSpeeds.at(-1) * 1000)} px/s`)
  check('pointer model varies event cadence and stays in bounds',
        new Set(modelIntervals).size >= 4
          && pointerModel.points.every((point) => point.x >= 0 && point.x < 1000
            && point.y >= 0 && point.y < 700)
          && pointerModel.points.at(-1).x === modelTo.x
          && pointerModel.points.at(-1).y === modelTo.y,
        `${new Set(modelIntervals).size} intervals, ${pointerModel.duration}ms`)
  check('pointer timing scales down for a micro-correction',
        microModel.duration < 150 && pointerModel.duration > microModel.duration * 3,
        `${microModel.duration}ms micro, ${pointerModel.duration}ms viewport move`)

  // --- input fidelity: page receives the cursor glide, not one teleport ----
  await H.goto(`${BASE}/input`)
  await H.js('window.inputTrace = []')
  await H.hover(40, 40)
  const firstEntry = await H.js(`({
    moves: window.inputTrace
      .filter((e) => e.type === 'mousemove')
      .map(({x, y, trusted, at}) => ({x, y, trusted, at})),
    width: innerWidth,
    height: innerHeight
  })`)
  const firstMoves = firstEntry.moves
  const firstDistinct = new Set(firstMoves.map((e) => `${e.x},${e.y}`))
  const firstMove = firstMoves[0]
  const enteredAtEdge = firstMove && (firstMove.x <= 1 || firstMove.y <= 1
    || firstMove.x >= firstEntry.width - 1 || firstMove.y >= firstEntry.height - 1)
  check('first cursor appearance enters from a viewport edge',
        firstMoves.length >= 5 && firstDistinct.size >= 5 && enteredAtEdge
          && firstMoves.every((e) => e.trusted),
        `${firstMoves.length} moves, first ${firstMove
          ? `${firstMove.x},${firstMove.y}` : 'missing'}`)
  check('first cursor entry is paced over time',
        firstMoves.length >= 2 && firstMoves.at(-1).at - firstMoves[0].at >= 150,
        `${firstMoves.length >= 2
          ? Math.round(firstMoves.at(-1).at - firstMoves[0].at) : 0}ms`)
  await H.js('window.inputTrace = []')
  await H.click('#input-target')
  const input = await H.js('({trace: window.inputTrace, clicked: window.inputClicked})')
  const moves = input.trace.filter((e) => e.type === 'mousemove')
  const distinctMoves = new Set(moves.map((e) => `${e.x},${e.y}`))
  const liveDx = 890 - 40
  const liveDy = 540 - 40
  const liveLength = Math.hypot(liveDx, liveDy)
  const liveBend = moves.reduce((maximum, point) => Math.max(maximum, Math.abs(
    liveDx * (40 - point.y) - (40 - point.x) * liveDy
  ) / liveLength), 0)
  const liveSpeeds = moves.slice(1).map((point, index) => {
    const previous = moves[index]
    return Math.hypot(point.x - previous.x, point.y - previous.y)
      / Math.max(1, point.at - previous.at)
  })
  const down = input.trace.find((e) => e.type === 'mousedown')
  const up = input.trace.find((e) => e.type === 'mouseup')
  check('click dispatches a dense trusted cursor trajectory',
        moves.length >= 10 && distinctMoves.size >= 10 && moves.every((e) => e.trusted),
        `${moves.length} moves, ${distinctMoves.size} distinct`)
  check('click cursor follows a non-linear speed-varying path',
        liveBend >= 5 && liveSpeeds.length >= 6
          && Math.max(...liveSpeeds) > Math.min(...liveSpeeds) * 2,
        `${liveBend.toFixed(1)}px bend, `
          + `${Math.round(Math.min(...liveSpeeds) * 1000)}–`
          + `${Math.round(Math.max(...liveSpeeds) * 1000)} px/s`)
  check('click cursor trajectory is paced over time',
        moves.length >= 2 && moves.at(-1).at - moves[0].at >= 250,
        `${moves.length >= 2 ? Math.round(moves.at(-1).at - moves[0].at) : 0}ms`)
  check('click has a physical press dwell',
        down && up && up.at - down.at >= 45 && up.at - down.at < 200,
        `${down && up ? Math.round(up.at - down.at) : 0}ms`)
  check('paced cursor still clicks the intended target', input.clicked)

  // --- typing fidelity: point/click/focus, select-all, then real keys -------
  await H.js('window.inputTrace = []')
  await H.fillInput('#input-field', 'Ab 12!')
  const typing = await H.js(`({
    value: document.getElementById('input-field').value,
    trace: window.inputTrace
  })`)
  const mouseDownAt = typing.trace.findIndex((e) => e.type === 'mousedown'
    && e.target === 'input-field')
  const focusAt = typing.trace.findIndex((e) => e.type === 'focus'
    && e.target === 'input-field')
  const typedDowns = typing.trace.filter((e) => e.type === 'keydown'
    && e.target === 'input-field' && e.key?.length === 1 && !e.meta)
  const typedUps = typing.trace.filter((e) => e.type === 'keyup'
    && e.target === 'input-field' && e.key?.length === 1 && !e.meta)
  const shiftDowns = typing.trace.filter((e) => e.type === 'keydown'
    && e.target === 'input-field' && e.key === 'Shift')
  const shiftUps = typing.trace.filter((e) => e.type === 'keyup'
    && e.target === 'input-field' && e.key === 'Shift')
  const trustedInputs = typing.trace.filter((e) => e.type === 'beforeinput'
    || e.type === 'input')
  check('fillInput clicks before the field receives focus',
        mouseDownAt >= 0 && focusAt > mouseDownAt,
        `mousedown ${mouseDownAt}, focus ${focusAt}`)
  check('fillInput replaces through a real Meta+A selection',
        typing.trace.some((e) => e.type === 'keydown' && e.key === 'a' && e.meta))
  check('fillInput emits trusted key and input events per character',
        typedDowns.length === 6 && typedUps.length === 6
          && shiftDowns.length === 2 && shiftUps.length === 2
          && typedDowns.every((e) => e.trusted)
          && typedUps.every((e) => e.trusted)
          && trustedInputs.length >= 6 && trustedInputs.every((e) => e.trusted),
        `${typedDowns.length} downs, ${typedUps.length} ups, `
          + `${shiftDowns.length}/${shiftUps.length} shifts, ${trustedInputs.length} inputs`)
  check('fillInput key cadence is paced',
        typedDowns.length >= 2 && typedDowns.at(-1).at - typedDowns[0].at >= 180,
        `${typedDowns.length >= 2
          ? Math.round(typedDowns.at(-1).at - typedDowns[0].at) : 0}ms`)
  check('keyboard-paced fill preserves shifted text', typing.value === 'Ab 12!', typing.value)

  await H.js('window.inputTrace = []')
  await H.fillInput('#input-field', '你好🙂')
  const unicode = await H.js(`({
    value: document.getElementById('input-field').value,
    inputs: window.inputTrace.filter((e) => e.type === 'input'),
    keys: window.inputTrace.filter((e) => e.type === 'keydown' && !e.meta)
  })`)
  check('IME and emoji graphemes retain trusted insertion semantics',
        unicode.value === '你好🙂' && unicode.inputs.length === 3
          && unicode.inputs.every((e) => e.trusted) && unicode.keys.length === 0,
        `${unicode.inputs.length} inputs, ${unicode.keys.length} ordinary keys`)

  await H.js('window.inputTrace = []')
  await H.pressKey('Enter')
  const enter = await H.js(`({
    count: window.inputEnter,
    key: window.inputTrace.find((e) => e.type === 'keydown' && e.key === 'Enter')
  })`)
  check('pressKey preserves a trusted Enter key sequence',
        enter.count === 1 && enter.key?.trusted)

  await H.js('window.inputTrace = []')
  await H.fillInput('#input-field', '')
  const cleared = await H.js(`({
    value: document.getElementById('input-field').value,
    backspace: window.inputTrace.find((e) => e.type === 'keydown'
      && e.key === 'Backspace')
  })`)
  check('fillInput clears through select-all and trusted Backspace',
        cleared.value === '' && cleared.backspace?.trusted)

  let rejected = null
  try { await H.fillInput('#reject-field', 'rejected', { instant: true }) } catch (e) {
    rejected = e
  }
  check('setter fallback verifies that the page accepted the value',
        rejected && /did not match requested text/.test(rejected.message))

  // --- scroll fidelity: a wheel gesture, not one large endpoint event -------
  await H.js('scrollTo(0, 0); window.inputTrace = []')
  await H.scroll({ dy: 600 })
  await H.wait(0.2)
  const wheelAudit = await H.js(`({
    y: scrollY,
    wheels: window.inputTrace.filter((e) => e.type === 'wheel')
  })`)
  const wheelSum = wheelAudit.wheels.reduce((sum, e) => sum + e.dy, 0)
  const wheelDeltas = new Set(wheelAudit.wheels.map((e) => Number(e.dy).toFixed(2)))
  const wheelTargets = new Set(wheelAudit.wheels.map((e) => e.target))
  const wheelElapsed = wheelAudit.wheels.length >= 2
    ? wheelAudit.wheels.at(-1).at - wheelAudit.wheels[0].at : 0
  check('scroll dispatches a dense trusted wheel trajectory',
        wheelAudit.wheels.length >= 8 && wheelDeltas.size >= 4
          && wheelTargets.size === 1 && wheelAudit.wheels.every((e) => e.trusted),
        `${wheelAudit.wheels.length} events, ${wheelDeltas.size} deltas, `
          + `${wheelTargets.size} target(s)`)
  check('scroll wheel trajectory is paced and sums to the request',
        wheelElapsed >= 300 && Math.abs(wheelSum - 600) < 0.1,
        `${Math.round(wheelElapsed)}ms, sum ${wheelSum.toFixed(2)}`)
  check('paced wheel trajectory scrolls the document', wheelAudit.y > 0,
        `scrollY ${Math.round(wheelAudit.y)}`)

  // --- input gate: late consent and exact human hit-testing -----------------
  await H.goto(`${BASE}/late-consent`)
  await H.click('#underlay')
  const gateTrace = await H.js('window.gateTrace')
  check('first input catches consent that mounted after navigation polling',
        gateTrace.map((event) => event.kind).join(',') === 'consent,underlay',
        gateTrace.map((event) => event.kind).join(','))
  check('late consent and requested click both use trusted pointer events',
        gateTrace.length === 2 && gateTrace.every((event) => event.trusted))

  await H.goto(`${BASE}/occluded`, { acceptCookies: false })
  let coveredError = null
  try { await H.click('#covered') } catch (e) { coveredError = e }
  const blockedCount = await H.js('window.coveredClicks')
  check('click refuses an element a human cannot hit through an overlay',
        coveredError && /not human-operable/.test(coveredError.message)
          && blockedCount === 0,
        String(coveredError?.message || 'no error').slice(0, 80))
  await H.js('document.getElementById("shield").remove()')
  await H.click('#covered')
  const unblocked = await H.js(`({
    count: window.coveredClicks,
    trusted: window.coveredTrusted
  })`)
  check('same target works once it is visibly reachable',
        unblocked.count === 1 && unblocked.trusted)

  // --- Cloudflare gate: two passive checks, never synthetic solving ---------
  await H.goto(`${BASE}/cf-auto`, { acceptCookies: false })
  const autoCf = await H.waitForChallengeClearance({ attempts: 2, interval: 0.4 })
  check('managed Cloudflare clearance can finish during passive checks',
        autoCf.cleared && autoCf.totalAttempts >= 1 && autoCf.totalAttempts <= 2,
        JSON.stringify(autoCf))
  await H.click('#after-cf')
  check('input continues after passive challenge clearance',
        (await H.js('window.afterCfClicks')) === 1)

  await H.goto(`${BASE}/cf-stuck`, { acceptCookies: false })
  const stuckCf = await H.waitForChallengeClearance({ attempts: 2, interval: 0.25 })
  const repeatedCf = await H.waitForChallengeClearance({ attempts: 2, interval: 0.25 })
  check('unresolved challenge consumes one shared two-check budget',
        !stuckCf.cleared && stuckCf.attempts === 2 && stuckCf.exhausted
          && repeatedCf.attempts === 0 && repeatedCf.totalAttempts === 2,
        `${JSON.stringify(stuckCf)} then ${JSON.stringify(repeatedCf)}`)
  let challengeInputError = null
  try { await H.click('#behind-cf') } catch (e) { challengeInputError = e }
  check('input never attempts to click through an unresolved challenge',
        /after 2 passive rechecks/.test(challengeInputError?.message || '')
          && (await H.js('window.behindCfClicks')) === 0,
        String(challengeInputError?.message || 'no error').slice(0, 100))

  await H.goto(`${BASE}/cf-false-title`, { acceptCookies: false })
  const falseTitleCf = await H.waitForChallengeClearance()
  check('stale Just a moment title alone is not a Cloudflare challenge',
        falseTitleCf.cleared && falseTitleCf.attempts === 0
          && falseTitleCf.challenge === null,
        JSON.stringify(falseTitleCf))

  await H.goto(`${BASE}/cf-blocked`, { acceptCookies: false })
  const blockedCf = await H.waitForChallengeClearance()
  check('Cloudflare hard block gets no passive retry',
        !blockedCf.cleared && blockedCf.attempts === 0
          && blockedCf.challenge?.kind === 'blocked')

  // --- SPA races: late mounts, moving targets, generic waits -----------------
  await H.goto(`${BASE}/spa`)
  s = Date.now()
  await H.click('#late')
  const clicked = await H.js('window.clicked === true')
  check('click resolves a late-mounted button onto its final position', clicked,
        `${Date.now() - s}ms`)
  s = Date.now()
  await H.fillInput('#latefield', 'hello')
  check('fillInput resolves a late-mounted field',
        (await H.js('document.getElementById("latefield").value')) === 'hello',
        `${Date.now() - s}ms`)
  s = Date.now()
  check('waitForFunction waits for a delayed condition',
        (await H.waitForFunction('window.flag === true', { timeout: 10 })) === true,
        `${Date.now() - s}ms`)
  s = Date.now()
  const many = await H.waitForElement('li.item', { minCount: 15, timeout: 10 })
  check('waitForElement minCount', many.found && many.count >= 15,
        `count ${many.count} in ${Date.now() - s}ms`)
  s = Date.now()
  threw = null
  try { await H.click('#nope') } catch (e) { threw = e }
  const missMs = Date.now() - s
  check('missing target fails after the bounded grace',
        threw && missMs >= 2500 && missMs < 6000, `${missMs}ms`)
  threw = null
  try { await H.waitForFunction('nonsense..syntax', { timeout: 1 }) } catch (e) { threw = e }
  check('waitForFunction surfaces evaluation errors on timeout',
        threw && /SyntaxError/.test(threw.message))

  // --- observe/snapshot share one scan ---------------------------------------
  const obs = await H.observe()
  check('observe sees the SPA controls', (obs.elements || []).length >= 3,
        `${(obs.elements || []).length} elements`)
  check('snapshotText tags refs', /\[ref=\d+/.test(await H.snapshotText()))

  // --- importCookies round-trip (local domain only) --------------------------
  const imp = await H.importCookies([{
    name: '__phi_selftest', value: 'ok', domain: '127.0.0.1',
    expirationDate: Math.floor(Date.now() / 1000) + 120,
  }])
  await H.goto(`${BASE}/fast?cookie`)
  const seen = await H.js('document.cookie')
  await H.cdp('Network.deleteCookies', { name: '__phi_selftest', domain: '127.0.0.1' })
  check('importCookies injects into the profile',
        imp.imported === 1 && seen.includes('__phi_selftest=ok'))
  const leftover = (await H.cdp('Storage.getCookies', {})).cookies
    .filter((c) => c.name === '__phi_selftest').length
  check('selftest cookie cleaned up', leftover === 0)

  await H.complete({ success: true })
}

const server = await startServer()
let fatal = null
try {
  await main()
} catch (err) {
  fatal = err
} finally {
  server.close()
  // Never leave the throwaway Space behind, even on a mid-test crash.
  if (fatal) {
    try { await H.ensureAgentSpace(SPACE); await H.complete({ success: false }) } catch {}
  }
  await H.__dispose().catch(() => {})
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed` +
            (fatal ? ` — aborted by: ${fatal.message}` : ''))
process.exit(failed.length || fatal ? 1 : 0)
