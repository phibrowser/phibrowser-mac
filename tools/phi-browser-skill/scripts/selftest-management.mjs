#!/usr/bin/env node
// Copyright 2026 Phinomenon Inc.
//
// Self-test for the browser-management surface of the phi-browser skill
// (Spaces, profiles, URL rules, pinned tabs, bookmarks, tab groups, split
// view, downloads). Run after changing the management helpers or their Swift
// handlers:
//   node scripts/selftest-management.mjs
//
// Needs a running Phi Browser with the CDP endpoint enabled (see
// references/install.md) and at least one browser window open. Safe on a
// live browser: every resource it creates carries a 'Phi Mgmt Selftest' /
// 'phi-mgmt-' marker, leftovers from a crashed run are swept up front, and
// everything is removed again on the way out. The visible side effects are a
// marker pinned tab in the active profile's sidebar for a few seconds and a
// tiny marker file that briefly lands in the profile's Downloads folder
// (record and file are both removed before exit).
// Profile CREATION is deliberately not exercised (profiles have no delete
// API, so a created one would be permanent residue) — only its refusal
// paths are. Takes ~90s; exits non-zero when any check fails.

import { createServer } from 'node:http'
import { rmSync } from 'node:fs'
import * as H from './lib/helpers.mjs'

const PORT = 8380
const BASE = `http://127.0.0.1:${PORT}`
const SPACE_NAME = 'Phi Mgmt Selftest'
const AGENT_SPACE = 'phi-skill-mgmt-selftest'
const PIN_TITLE = 'Phi Mgmt Selftest Pin'
const RULE_MARKER = 'phi-mgmt-' // every test rule's host starts with this
const DOWNLOAD_MARKER = 'phi-mgmt-selftest' // the test download's filename prefix

function startServer() {
  return new Promise((resolve, reject) => {
    const srv = createServer((req, res) => {
      if (req.url.startsWith('/download')) {
        res.setHeader('content-type', 'application/octet-stream')
        res.setHeader('content-disposition',
                      'attachment; filename="phi-mgmt-selftest.bin"')
        res.end('phi-mgmt-selftest payload')
        return
      }
      res.setHeader('content-type', 'text/html')
      res.end('<!doctype html><title>fast</title><h1>fast</h1>')
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

/** Polls `fn` until truthy or the timeout lapses; returns the last value. */
async function until(fn, { timeout = 6, poll = 0.2 } = {}) {
  const deadline = Date.now() + timeout * 1000
  for (;;) {
    const value = await fn()
    if (value || Date.now() >= deadline) return value
    await H.wait(poll)
  }
}

/** Runs `fn` expecting a throw; returns the error, or null if it succeeded. */
async function threw(fn) {
  try { await fn(); return null } catch (err) { return err }
}

/** Removes every marker resource a previous (possibly crashed) run left
 *  behind: Spaces by name prefix, URL rules by host marker (incognito rules
 *  survive Space deletion, so they need their own sweep), pins by title. */
async function sweepLeftovers() {
  for (const space of await H.listSpaces()) {
    if (space.name.startsWith(SPACE_NAME)) {
      await H.deleteSpace(space.spaceId).catch(() => {})
    }
  }
  // Rule ids regenerate on every write — re-list after each delete.
  for (let i = 0; i < 10; i++) {
    const rule = (await H.listUrlRules()).find((r) => r.host.startsWith(RULE_MARKER))
    if (!rule) break
    await H.deleteUrlRule(rule.id).catch(() => {})
  }
  for (const profile of await H.listProfiles()) {
    for (const pin of await H.listPinnedTabs({ profile: profile.profileId })) {
      if ((pin.title ?? '').startsWith(PIN_TITLE)) {
        await H.removePinnedTab(pin.guid).catch(() => {})
      }
    }
  }
}

async function main() {
  await sweepLeftovers()

  // --- Spaces: create / list / update -----------------------------------------
  const created = await H.createSpace(SPACE_NAME, { themeId: 'coral' })
  const spaceId = created.spaceId
  let listed = (await H.listSpaces()).find((s) => s.spaceId === spaceId)
  check('createSpace appears in listSpaces', !!listed, spaceId)
  check('createSpace applies name and theme',
        listed?.name === SPACE_NAME && listed?.themeId === 'coral',
        `${listed?.name} ${listed?.themeId}`)
  check('createSpace binds a profile', !!created.profileId, created.profileId)

  // A hex snaps to the nearest built-in theme — the pinned theme is what the
  // window shows, so that is what must change.
  const respaced = await H.updateSpace(spaceId, { name: `${SPACE_NAME} 2`, colorHex: '#3A6FF8',
                                                  iconName: 'mail' })
  listed = (await H.listSpaces()).find((s) => s.spaceId === spaceId)
  check('updateSpace renames, rethemes and re-icons',
        listed?.name === `${SPACE_NAME} 2` && listed?.themeId === respaced.themeId &&
        respaced.themeId !== 'coral' && listed?.iconName === 'phi:phi-icon-mail',
        `${listed?.name} ${listed?.themeId} ${listed?.iconName}`)

  let err0 = await threw(() => H.updateSpace(spaceId, { iconName: 'not-an-icon' }))
  check('updateSpace rejects an unknown icon', /invalid_icon/.test(String(err0?.message)),
        String(err0?.message).slice(0, 60))
  err0 = await threw(() => H.updateSpace(spaceId, { themeId: 'no-such-theme' }))
  check('updateSpace rejects an unknown theme', /unknown_theme/.test(String(err0?.message)),
        String(err0?.message).slice(0, 60))

  // --- Profiles: refusal paths only (creation would be permanent residue) -----
  const profiles = await H.listProfiles()
  check('listProfiles returns usable rows',
        profiles.length > 0 && profiles.every((p) => p.profileId && p.displayName),
        `${profiles.length} profiles`)
  let err = await threw(() => H.createProfile(profiles[0].displayName))
  check('createProfile refuses a duplicate display name', !!err,
        String(err?.message).slice(0, 60))
  err = await threw(() => H.renameProfile('phi-mgmt-no-such-profile', 'x'))
  check('renameProfile refuses an unknown profileId', !!err,
        String(err?.message).slice(0, 60))

  // --- URL rules: add / update (ids regenerate) / delete / incognito ----------
  const rule = await H.addUrlRule({
    space: spaceId, host: `${RULE_MARKER}selftest.invalid`, pathPrefix: '/docs',
  })
  check('addUrlRule returns the settled row',
        rule.id && rule.spaceId === spaceId &&
        rule.host === `${RULE_MARKER}selftest.invalid` && rule.pathPrefix === '/docs',
        rule.id)

  await H.updateUrlRule(rule.id, { host: `${RULE_MARKER}selftest2.invalid`, ask: true })
  const rules = await H.listUrlRules()
  const updated = rules.find((r) =>
    r.spaceId === spaceId && r.host === `${RULE_MARKER}selftest2.invalid`)
  check('updateUrlRule rewrites the rule', !!updated && updated.ask === true,
        updated?.id)
  check('rule ids regenerate on write',
        !!updated && updated.id !== rule.id &&
        !rules.some((r) => r.id === rule.id),
        `${rule.id} -> ${updated?.id}`)

  await H.deleteUrlRule(updated.id)
  check('deleteUrlRule removes the rule',
        !(await H.listUrlRules()).some((r) => r.id === updated.id ||
          r.host === `${RULE_MARKER}selftest2.invalid`))

  const incognito = await H.addUrlRule({
    space: 'incognito', host: `${RULE_MARKER}incognito.invalid`,
  })
  check('addUrlRule accepts the incognito target',
        incognito.id && incognito.spaceId === 'space.incognito', incognito.id)
  await H.deleteUrlRule(incognito.id)
  check('incognito rule deletes',
        !(await H.listUrlRules()).some((r) => r.host === `${RULE_MARKER}incognito.invalid`))

  err = await threw(() => H.addUrlRule({ space: 'phi-mgmt-no-such-space', host: 'x.invalid' }))
  check('addUrlRule refuses an unknown Space', err && /unknown space/i.test(err.message),
        String(err?.message).slice(0, 60))

  // --- Pinned tabs: add / update / remove --------------------------------------
  const pin = await H.addPinnedTab(`${BASE}/?pin`, {
    title: PIN_TITLE, profile: created.profileId,
  })
  let pins = await H.listPinnedTabs({ profile: created.profileId })
  const pinRow = pins.find((p) => p.guid === pin.guid)
  check('addPinnedTab appears in the profile list',
        !!pinRow && pinRow.title === PIN_TITLE, pin.guid)

  await H.updatePinnedTab(pin.guid, { title: `${PIN_TITLE} 2`, url: `${BASE}/?pin2` })
  pins = await H.listPinnedTabs({ profile: created.profileId })
  const pinAfter = pins.find((p) => p.guid === pin.guid)
  check('updatePinnedTab edits title and url',
        pinAfter?.title === `${PIN_TITLE} 2` && (pinAfter?.url ?? '').includes('pin2'),
        `${pinAfter?.title} ${pinAfter?.url}`)

  await H.removePinnedTab(pin.guid)
  check('removePinnedTab unpins',
        !(await H.listPinnedTabs({ profile: created.profileId }))
          .some((p) => p.guid === pin.guid))

  // --- Bookmarks: folder / add / update / move / remove ------------------------
  const folder = await H.addBookmarkFolder('Mgmt Test Folder', { space: spaceId })
  const mark = await H.addBookmark(`${BASE}/?bookmark`, {
    title: 'Mgmt Test Bookmark', space: spaceId, folder: folder.guid,
  })
  let tree = (await H.listBookmarks({ space: spaceId })).bookmarks
  const folderNode = tree.find((n) => n.guid === folder.guid)
  check('addBookmark lands inside its folder',
        !!folderNode && (folderNode.children ?? []).some((n) => n.guid === mark.guid))

  await H.updateBookmark(mark.guid, { title: 'Mgmt Test Bookmark 2' })
  tree = (await H.listBookmarks({ space: spaceId })).bookmarks
  const renamed = (tree.find((n) => n.guid === folder.guid)?.children ?? [])
    .find((n) => n.guid === mark.guid)
  check('updateBookmark renames', renamed?.title === 'Mgmt Test Bookmark 2',
        renamed?.title)

  await H.moveBookmark(mark.guid, {}) // to the Space root
  const atRoot = await until(async () =>
    (await H.listBookmarks({ space: spaceId })).bookmarks
      .some((n) => n.guid === mark.guid))
  check('moveBookmark relocates to the Space root', atRoot)

  await H.removeBookmark(mark.guid)
  await H.removeBookmark(folder.guid)
  tree = (await H.listBookmarks({ space: spaceId })).bookmarks
  check('removeBookmark deletes bookmark and folder',
        !tree.some((n) => n.guid === mark.guid || n.guid === folder.guid))

  // --- Tab groups & split view (inside a throwaway agent Space) ---------------
  await H.ensureAgentSpace(AGENT_SPACE)
  const a = (await H.openTab(`${BASE}/?a`)).targetId
  const b = (await H.openTab(`${BASE}/?b`)).targetId
  const c = (await H.openTab(`${BASE}/?c`)).targetId // stays active: safe to collapse a/b's group

  const g1 = await H.createTabGroup([a, b], { title: 'Mgmt Group', color: 'blue' })
  let group = (await H.listTabGroups()).find((g) => g.token === g1.token)
  const members = new Set((group?.tabs ?? []).map((t) => t.targetId))
  check('createTabGroup groups the tabs',
        !!group && members.size === 2 && members.has(a) && members.has(b), g1.token)
  check('createTabGroup applies title and color',
        group?.title === 'Mgmt Group' && group?.color === 'blue',
        `${group?.title} ${group?.color}`)

  await H.updateTabGroup(g1.token, { title: 'Mgmt Group 2', color: 'red', collapsed: true })
  group = await until(async () => {
    const g = (await H.listTabGroups()).find((x) => x.token === g1.token)
    return g && g.title === 'Mgmt Group 2' && g.color === 'red' && g.collapsed ? g : null
  })
  check('updateTabGroup retitles, recolors, collapses', !!group)
  await H.updateTabGroup(g1.token, { collapsed: false })

  await H.addTabsToGroup(g1.token, [c])
  let count = await until(async () =>
    ((await H.listTabGroups()).find((g) => g.token === g1.token)?.tabs.length ?? 0) === 3)
  check('addTabsToGroup grows the group to 3', count)

  await H.removeTabsFromGroup([c])
  count = await until(async () =>
    ((await H.listTabGroups()).find((g) => g.token === g1.token)?.tabs.length ?? 0) === 2)
  check('removeTabsFromGroup shrinks it back to 2', count)

  await H.ungroupTabGroup(g1.token)
  let open = new Set((await H.listTabs()).map((t) => t.targetId))
  check('ungroupTabGroup dissolves but keeps the tabs',
        !(await H.listTabGroups()).some((g) => g.token === g1.token) &&
        open.has(a) && open.has(b) && open.has(c))

  const s1 = await H.createSplitView(a, b, { layout: 'vertical' })
  let split = (await H.listSplitViews()).find((s) => s.splitId === s1.splitId)
  const paneTargets = new Set([split?.primary.targetId, split?.secondary.targetId])
  check('createSplitView pairs the two tabs',
        !!split && split.layout === 'vertical' && paneTargets.has(a) && paneTargets.has(b),
        s1.splitId)

  await H.updateSplitView(s1.splitId, { ratio: 0.7, layout: 'horizontal' })
  split = await until(async () => {
    const s = (await H.listSplitViews()).find((x) => x.splitId === s1.splitId)
    return s && s.layout === 'horizontal' && Math.abs(s.ratio - 0.7) < 0.05 ? s : null
  })
  check('updateSplitView adjusts ratio and layout', !!split,
        split ? `${split.layout} ${split.ratio}` : '')

  const before = (await H.listSplitViews()).find((s) => s.splitId === s1.splitId)
  await H.swapSplitView(s1.splitId)
  const swapped = await until(async () => {
    const s = (await H.listSplitViews()).find((x) => x.splitId === s1.splitId)
    return s && s.primary.tabId === before.secondary.tabId &&
           s.secondary.tabId === before.primary.tabId ? s : null
  })
  check('swapSplitView exchanges the panes', !!swapped)

  await H.removeSplitView(s1.splitId)
  open = new Set((await H.listTabs()).map((t) => t.targetId))
  check('removeSplitView keeps both tabs open',
        !(await H.listSplitViews()).some((s) => s.splitId === s1.splitId) &&
        open.has(a) && open.has(b))

  const g2 = await H.createTabGroup([a, b], { title: 'Mgmt Close Me' })
  await H.closeTabGroup(g2.token)
  const closed = await until(async () => {
    const ids = new Set((await H.listTabs()).map((t) => t.targetId))
    return !ids.has(a) && !ids.has(b) && ids.has(c)
  })
  check('closeTabGroup closes the group AND its tabs', closed)

  err = await threw(() => H.createTabGroup(['phi-mgmt-bogus-target']))
  check('group ops refuse an unresolvable target',
        err && /cannot resolve/i.test(err.message), String(err?.message).slice(0, 60))

  // --- Downloads (per-profile; observed through the agent Space's window) -------
  // Clear any leftover marker download a crashed run left behind (record +
  // file), so the appearance check below can't match a stale item.
  for (const d of (await H.listDownloads())
         .filter((d) => (d.filename ?? '').startsWith(DOWNLOAD_MARKER))) {
    await H.removeDownload(d.guid).catch(() => {})
    if (d.targetPath) { try { rmSync(d.targetPath, { force: true }) } catch {} }
  }
  check('listDownloads returns a list', Array.isArray(await H.listDownloads()))
  err = await threw(() => H.getDownload('phi-mgmt-no-such-download'))
  check('getDownload rejects an unknown guid',
        err && /unknown_download/i.test(err.message), String(err?.message).slice(0, 60))

  // Trigger a real download without navigating the tab away: a same-origin
  // anchor with a download attribute, clicked from page JS.
  await H.openTab(`${BASE}/?dl`)
  await H.js(`(() => { const a = document.createElement('a');` +
             ` a.href = '/download?dl'; a.download = '${DOWNLOAD_MARKER}.bin';` +
             ` document.body.appendChild(a); a.click(); a.remove(); return true })()`)
  const dl = await until(async () => (await H.listDownloads())
    .find((d) => (d.filename ?? '').startsWith(DOWNLOAD_MARKER)), { timeout: 8 })
  check('a triggered download appears in listDownloads', !!dl,
        dl ? `${dl.filename} ${dl.state}` : 'not seen')
  if (dl) {
    const one = await H.getDownload(dl.guid)
    check('getDownload returns the same item by guid',
          one?.guid === dl.guid && (one?.url ?? '').includes('/download'), one?.state)
    // A tiny localhost file finishes near-instantly.
    const finished = await until(async () =>
      ['complete', 'cancelled', 'interrupted'].includes(
        (await H.getDownload(dl.guid))?.state), { timeout: 8 })
    check('the download reaches a terminal state', finished)
    const path = one?.targetPath || dl.targetPath
    await H.removeDownload(dl.guid)
    check('removeDownload drops it from the list',
          !(await H.listDownloads()).some((d) => d.guid === dl.guid))
    if (path) { try { rmSync(path, { force: true }) } catch {} }
  }

  await H.complete({ success: true })

  // --- deleteSpace: removal + cascade ------------------------------------------
  await H.addUrlRule({ space: spaceId, host: `${RULE_MARKER}cascade.invalid` })
  await H.deleteSpace(spaceId)
  check('deleteSpace removes the Space',
        !(await H.listSpaces()).some((s) => s.spaceId === spaceId))
  const cascaded = await until(async () =>
    !(await H.listUrlRules()).some((r) => r.host === `${RULE_MARKER}cascade.invalid`))
  check('deleteSpace cascades its URL rules', cascaded)

  err = await threw(() => H.deleteSpace('phi-mgmt-no-such-space'))
  check('deleteSpace refuses an unknown Space', err && /unknown space/i.test(err.message),
        String(err?.message).slice(0, 60))
}

const server = await startServer()
let fatal = null
try {
  await main()
} catch (err) {
  fatal = err
} finally {
  server.close()
  // Never leave marker residue behind, even on a mid-test crash.
  try { await sweepLeftovers() } catch {}
  if (fatal) {
    try { await H.ensureAgentSpace(AGENT_SPACE); await H.complete({ success: false }) } catch {}
  }
  await H.__dispose().catch(() => {})
}

const failed = results.filter((r) => !r.ok)
console.log(`\n${results.length - failed.length}/${results.length} checks passed` +
            (fatal ? ` — aborted by: ${fatal.message}` : ''))
process.exit(failed.length || fatal ? 1 : 0)
