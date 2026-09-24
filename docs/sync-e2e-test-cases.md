# Sync E2E test cases

This is a manual acceptance reference for QA, not an execution report. All cases
start as **Not run**. The source baseline is Mac `83361acd` on
`sync/convergence-hardening` and sync-service `main@d49cf41` (PR #3), inspected
on 2026-09-22. Staging runs that service image (`sha-d49cf41`); production still
runs `sha-bdbccd1`, whose create path upserts by client tag instead of answering
a conflicting create with CONFLICT.
Record the actual native app, embedded framework and service versions for every
run: these sources do not establish which features a distributed build contains.

## Scope and acceptance rules

| Area | What to verify |
| --- | --- |
| Account and keys | First-device setup, recovery code, device approval, restart, sign-out and device removal |
| Pairing | Account Profile identity, local Profile mapping, Space mapping and overwrite review |
| Phi data | Registered settings, Spaces, bookmarks/folders, pinned tabs and URL rules |
| Chromium data | Eligible Profile-scoped preferences, history, extensions/settings and sessions; confirm each datatype is enabled in the tested framework |
| Reliability | Offline edits, concurrent changes, clock skew and correction, edit-vs-delete, notifications, reconnect, replay, persistence failures and account isolation |
| Exclusions | Chromium passwords, cookies and autofill are rejected by this service. Phi owns bookmark sync; Chromium BOOKMARKS is disabled. The reserved `PhiChat` Profile is local-only. Conversation storage is a separate feature. |

Profile pairing is in scope; do not infer that all Profile names, avatars or
settings synchronize. The Sync UX cases below cover the new settings pane. Ordinary
open tabs are not Phi pinned tabs: Chromium session data must not be interpreted
as a requirement to recreate every tab automatically on the other Mac.

- **P0:** smoke/release-critical data safety and principal user journeys.
- **P1:** full regression, conflict and recovery coverage.
- **P2:** compatibility or extended robustness coverage.
- **Manual:** QA can use the app and device/network controls.
- **Assisted:** requires an engineering-provided fixture, instrumented build,
  network proxy or staging fault injection. An unavailable fixture is **Blocked**,
  never Pass or Not applicable by default.
- Run normal data operations in both directions, A → B and B → A. Verify the
  rendered behavior and persisted result after restarting B, not just a log line.
- For ordinary small datasets with healthy networking, use **60 seconds as the
  initial QA observation window**, not a contractual latency guarantee. Record
  actual convergence time and investigate an overrun. A UI that catches up only
  after restart does not pass a live-update case.
- With SSE unavailable, observe at least two fallback intervals plus in-flight
  work (start with 150 seconds). Current native defaults are 60 seconds for
  fallback, 300 seconds when healthy, a 45-second watchdog and a 5-second tick.
  Large initial replays use completed rounds/pages as well as elapsed time.
- Stop edits before comparing convergence. Check identities/counts, values,
  ownership, tree structure and order on every device. In a quiet steady state,
  changes must not repeatedly publish themselves. Identical titles alone do not
  prove that two rows are the same entity.

## Test environment and reusable fixtures

1. Use two separate Macs, **A** and **B**, with matching sync-enabled native and
   Chromium builds. Use **C** for the third-device and long-offline cases. A
   second app instance with a different `--user-data-dir` is not full isolation:
   native preferences, account storage and Keychain may still be shared.
2. Use disposable staging accounts **U1** and **U2**. Record the actual endpoints
   of native sync, key APIs and Chromium sync, and the deployed service image tag
   (`sha-<commit>`) of the environment under test — a product version string does
   not identify the server behavior. Canary defaults to staging and release to
   production; an explicit Chromium sync URL can override that default. Do not mix
   environments within a run. A case marked *create-guard* depends on the server
   create path answering a conflicting create with CONFLICT, which requires
   `sha-d49cf41` or later; on `sha-bdbccd1` record it as **Blocked** with the
   image tag as the reason, never as Pass.
3. Prepare a fresh-install fixture and a populated-account fixture separately.
   Have engineering prepare any full reset using the current reset runbook;
   deleting only the app or only Chromium data does not reset native cursors,
   pairing mappings, account keys or server state. Preserve a backup before
   fault injection. Do not reuse recovery codes across independently reset
   accounts.
4. On U1 create Profiles **Work** and **Personal**, and ordinary Spaces **S1**,
   **S2** and **S3**. Bind S1/S2 to Work and S3 to Personal. Keep at least two
   live user Spaces for deletion cases. Map corresponding Profiles and Spaces
   across devices; local directory names and local IDs need not match.
5. In S1 create folder **QA-Folder**, nested folder **QA-Nested**, four bookmarks
   with distinct `https://example.com/sync-qa/...` URLs, and two pins. Add three
   URL rules: a path-specific S1 rule, an S2 rule and an Incognito-target rule.
   Use reachable QA-controlled pages for history, cookies and extension tests.
6. Give all new data a run-specific prefix such as `SYNC-<run>-<case>`. Record
   a before/after manifest: settings, Space fields/order, bookmark paths/URLs,
   pin scope/order and rule host/path/target/ask/order. Use synthetic secrets.
7. Except in the clock-skew case, enable normal clock synchronization. Disable
   automatic app replacement in the test package so the build cannot change
   during a run. Record network and app foreground/background state.

The default precondition below is U1 paired on A/B, the populated fixture fully
converged, and both apps online. A case-specific precondition overrides it.
Reset the relevant fixture between destructive/conflict variants; do not let a
previous case's hidden Space or pending edit determine the next result.

## Account, keys and device lifecycle

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-A01 | P0 / Manual | Fresh U1 and A. Sign in and complete sync setup. Copy/save the recovery code, select “I've saved it”, try an incorrect code and then re-enter the saved code. Complete matching and restart A. Also close/reopen or restart between saving and verification. | The code warns it is shown only once. The next screen has blank input and never re-displays the code. Incorrect input cannot start sync. Pending confirmation survives reopening/restart despite device unlock. Correct input allows matching; only full setup enables sync. |
| SYNC-A02 | P0 / Manual | U1 initialized on A; B is fresh. Sign in as U1 on B, choose “Enter a recovery code”, enter A's code and complete pairing. Create one bookmark on each Mac. | B joins the same account; existing data arrives and both new bookmarks propagate once. A's existing data remains intact. |
| SYNC-A03 | P0 / Manual | Fresh B joining U1. Try an invalid code, then a valid code belonging to U2, then U1's correct code. | Incorrect codes cannot unlock U1 or expose its data. Failure remains recoverable; the correct code can complete joining without resetting A. |
| SYNC-A04 | P0 / Manual | Fresh B requests approval. On A open Settings → Sync, compare the displayed verification code and approve the matching request. Finish pairing on B. | Request/device and code correspond on both Macs. B progresses without hanging; it receives U1 data only after approval and mapping. |
| SYNC-A05 | P1 / Manual | Repeat new requests independently: deny on A; cancel on B; let the displayed expiry pass before trying approval. Then create a fresh request and approve it. | Denied/cancelled/expired requests do not enroll B. B can retry or select recovery. A fresh valid request succeeds; the UI never remains indefinitely on a completed request. |
| SYNC-A06 | P0 / Manual | A/B both joined. On B choose Settings → Sync → “Remove this device from sync…”. First cancel the confirmation; then repeat and confirm. Change data on A. Restart B and later rejoin it. | Cancel changes nothing. Confirm stops B's sync while retaining its local Spaces, bookmarks, history and pins. New changes from A do not land while removed. Rejoining requires approval or recovery; no automatic reuse of removed membership. |
| SYNC-A07 | P0 / Manual | Disposable account with A as its only active device. Attempt self-removal, including from a pairing gate if present. | Removal is refused with the last-device explanation. Existing data/keys remain usable. Pairing can still complete, or a second device can join before retrying removal. |
| SYNC-A08 | P0 / Manual | Sign B out of U1; change A's data while B is signed out. Sign B back into U1 and complete any required unlock/pairing. | Signed-out B stops account sync. Reauthentication resumes sync and catches up, including when Profile UUID/key are unchanged. There is no permanent disabled engine or destructive overwrite of A. |

## Profile and Space pairing

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-P01 | P0 / Manual | A has Work/Personal. Before joining, B has two distinguishable local Profiles with different names and test history. Explicitly map B's Profiles to their intended account Profiles. | Matching follows the selected account identities. Work data reaches Work and Personal data reaches Personal; matching is not inferred solely from display names or local directory names. |
| SYNC-P02 | P0 / Manual | B has an extra local Profile/Space. In pairing choose the available “add as new” choices rather than mapping it to A's existing data. | A new account identity is created; existing account objects are not overwritten. After convergence the new eligible data is visible on A under its own identity. |
| SYNC-P03 | P0 / Manual | A has multiple account Spaces. B has only its initial default Space. Join B and complete the wizard. | Unmatched account Spaces are listed and added automatically; QA need not create placeholder Spaces on B. Catch-up starts at gate opening, without waiting for the 300-second healthy polling interval. |
| SYNC-P04 | P0 / Manual | Give a local non-default Space on B different name, icon, color, theme and light/dark opacity from the account Space. Map it to that Space. Review the diff, go Back, then finish and Apply. | The overwrite review shows changed supported fields and local/account values accurately. Back applies no Space overwrite. Apply adopts the reviewed account fields; default-Space role is not misleadingly presented as a per-Space field. |
| SYNC-P05 | P1 / Manual | Leave an actionable mapping unresolved; try Finish. Navigate Back/Continue, then restart while pairing is incomplete. Complete it after restart. | Required unresolved decisions cannot be silently skipped. Restart safely resumes/reconstructs outstanding pairing. No duplicate account Profile/Space is created by retrying a completed step. Do not expect Back to undo already completed Profile registration. |
| SYNC-P06 | P0 / Assisted | Fail the wizard's remote-summary fetch, then a mapping write, independently. Retry after restoring service/storage. Also attempt app interaction while it loads. | Failure is visible and retryable; the app does not deadlock. No unreviewed overwrite or partially mapped Space publication occurs. Successful retry completes and triggers catch-up. |
| SYNC-P07 | P1 / Manual | After normal convergence create another local Profile and Space on A, and exercise runtime pairing on B when required. | New account identities are discovered without reinstalling. B's Space uses the resolved intended Profile; no fallback to an unrelated/default Profile leaks its browsing context. |
| SYNC-P08 | P0 / Assisted | While U1's pairing/request is in flight on B, sign out and sign in as U2. Release the delayed U1 response. Repeat with delayed key/device registration. | U1's old controller cannot register keys/Profiles into U2, apply U1 mappings to U2 or wake U2's engine with stale work. U2 remains isolated. |

## Settings and Spaces

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-S01 | P0 / Manual | Change each supported setting on A, one at a time, then reverse direction: Cmd-T new-tab behavior, full URL path, bookmark bar visibility, bookmark bar on new-tab page, Incognito-close warning, layout, automatic picture-in-picture mode, appearance, theme and selection tint. | B receives each registered value and its actual behavior/UI updates. Restart preserves it. No claim is made that every setting in Preferences is synchronized. |
| SYNC-S02 | P0 / Manual | A already has non-default settings. Prepare B with conflicting local values but no sync adoption history, then join. | B initially adopts account settings. Its pre-join defaults do not overwrite A. Subsequent explicit B edits synchronize normally. |
| SYNC-S03 | P1 / Manual | Disconnect A/B after a common baseline. Change different settings on each; reconnect. Then let B observe an A change to one setting, change that same setting on B, and sync again. | Independent keys survive together. A causally later edit to the same key wins. Both Macs converge without settings flipping back and forth. |
| SYNC-S04 | P0 / Manual | Create an ordinary Space on A. Edit its name, icon, color, theme and opacity, one field at a time. Reorder it; repeat from B. | Exactly one corresponding Space appears. Fields and account order converge; its Profile binding remains correct. Local navigation and opening a bookmark use that Profile. |
| SYNC-S05 | P1 / Manual | With a shared baseline, disconnect A/B. Rename S1 on A and change its icon on B; reconnect. Then perform two successive offline edits to different S1 fields on A before reconnecting. | Independent field edits are preserved. Reconnect/publish time does not retimestamp an older pending edit into a new user decision. Fields/order stabilize after merging. |
| SYNC-S06 | P0 / Manual | Delete ordinary S2 on A with bookmarks, pins and rules attached; leave other user Spaces alive. Wait, restart B and reconnect C if available. | S2 disappears on peers. Its content is not reassigned to an unrelated Space/Profile. Hidden retained rows do not count as live UI data; no peer recreates S2 just because it retained rows. |
| SYNC-S07 | P0 / Manual | With S1 available on both Macs, delete the original default Space. Open a context-free window; restart and compare both devices. Try deleting the last remaining user Space separately. | The original default identity can be deleted; the default role transfers and converges. Context-free windows use the resolved live default. The last live user Space cannot be locally deleted. |
| SYNC-S08 | P1 / Assisted | On B delay delivery/mapping of the successor Space while A deletes the original default Space. Deliver the successor later. | B retains a usable Space while the default tombstone is deferred. Once a successor is live/mapped, deletion and role resolution complete. B does not overwrite the account's role with its temporary local fallback. |
| SYNC-S09 | P1 / Manual | Inspect the original default Space on both Macs while changing themes and other ordinary Space properties. Create/use Incognito and agent Spaces. | The `default-space` identity does not synchronize a Profile binding or per-Space theme pin. Global theme settings still synchronize. Runtime Incognito/agent Spaces do not become ordinary paired user Spaces. Once the default-Space role sits on an ordinary Space, that Space carries its own `theme_id` and the global theme picker pins and syncs a theme on it (ruling C1-b): expected behavior, not a leaked suppression. |
| SYNC-S10 | P1 / Manual | Hand the default-Space role to a successor on A by deleting its current holder, while B has not yet paired that successor Space. Compare the resolved default Space and context-free window target on both Macs. Then pair the successor on B. | B falls back to the first live user Space in account order and writes nothing back: the account register keeps naming the successor A chose, and B's temporary local choice is never published. Once the successor is paired on B, B adopts the originally registered Space without a second hand-off, and both Macs resolve the same holder. |
| SYNC-S11 | P1 / Manual | From a shared S1 baseline, disconnect A and rename S1 offline. On online B, which has already observed that baseline, rename S1 later to a third value and let it publish. Reconnect A. Separately, on one Mac change an S1 field and put the original value back before the change publishes. | B's causally later rename wins on both Macs; A's older offline rename does not overwrite it when it finally publishes, and no rename flips back afterwards. The edited-and-reverted field publishes nothing: no entity update, no peer-visible change and no reordering. |

## Bookmarks and folders

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-B01 | P0 / Manual | Create a root bookmark, folder and nested bookmark on A. Rename them, edit a bookmark URL, reorder siblings and delete a leaf, waiting between actions. Reverse roles. | Values, hierarchy and sibling order converge with one entity per action. Opening the bookmark on B uses the correct URL and the owning Space's Profile. Deleted leaves remain absent after restart. |
| SYNC-B02 | P0 / Manual | Move a bookmark between folders, then move a folder with children from S1 to S2. Include a nested folder. | The whole visible subtree reaches its intended owner/location once. Descendants are not left behind, duplicated or spuriously moved back by later rounds. |
| SYNC-B03 | P1 / Manual | Disconnect A/B. Rename one shared bookmark on A and move it to another live folder on B. Reconnect. Repeat with both devices moving it to different live folders. | Independent content/location changes survive together. Competing moves choose one consistent location, without duplicates, orphan nodes or oscillation. Concurrent edits are not judged by which network request finished last. |
| SYNC-B04 | P0 / Manual | Disconnect A and rename a previously synced bookmark. On online B delete that bookmark and wait for the deletion to publish. Reconnect A. After convergence delete it again from B. | The unpublished edit survives and the bookmark reappears on B with that edit. The later deliberate deletion, after the edit is observed, removes it everywhere. Reappearance in the concurrent phase is expected. |
| SYNC-B05 | P0 / Manual | Repeat B04 with A editing a child while B deletes its parent folder. Repeat independently with A adding a new child, and with A renaming the folder itself. | Edited/new children survive at the Space root while the unedited deleted folder stays gone. A renamed folder **does reappear, empty**, together with any child that survived in its own right; unedited deleted children are not resurrected with it. No dangling parent or infinite retry remains. Known limitation: a folder whose deletion is cancelled on a later page does not get back the children already lifted to the Space root — record it, do not fail the case. |
| SYNC-B06 | P1 / Manual | Offline A only reorders a bookmark. B deletes it and publishes; reconnect A. | Reordering alone does not count as a content/location edit that defeats deletion. The bookmark stays deleted on all devices. |
| SYNC-B07 | P0 / Manual | Reverse B04's direction: disconnect A and delete a previously synced bookmark there. On online B rename it or change its URL and let that edit publish. Reconnect A. Repeat on an account whose logical time has run ahead of wall clock. | A's pending local deletion is cancelled and the bookmark survives on every device carrying B's content, including when logical time is ahead of wall clock. If its parent folder was deleted in the same operation, it survives at the Space root. Deleting it again after B's edit is observed removes it everywhere. |
| SYNC-B08 | P1 / Assisted | Produce a yielded bookmark with B04 or B05, then have engineering redeliver that same tombstone to the device that has just yielded (a replayed page or a repeated delivery of the current tombstone value). | The redelivered tombstone does not hard-delete the yielded row. The item stays live, its republication at the tombstone's version still happens, and after convergence it is present on every device with the surviving edit. |

| SYNC-B09 | P1 / Manual | Take A and B offline. On A move folder F1 into F2; on B move F2 into F1 (a 3-folder ring is a useful second run). Reconnect B first, then A. Also run it with A reconnecting first. | Ruling C5-a: the move with the newer location stamp stands and the older move is undone — that folder returns to where it was before its move, not to the Space root. Every device shows the same tree with no cycle, and the user who made the older move sees their folder back at its previous parent. A device that had already published the losing move may show the two folders nested inside each other for one round until a peer publishes the revert. |

For B03 (and for
R03 in the rules section), the rank a moved item lands on inside its new owner
follows the non-associative rank-coherence rule, which is a registered expected
failure of the convergence gate for bookmarks and URL rules. Devices still
converge and nothing is lost, but the settled order may differ in corner cases:
report it with the manifest, do not fail the case.

## Pinned tabs

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-T01 | P0 / Manual | For each offered pin scope (App, Profile, Space), pin two distinct pages on A, edit supported title/URL fields, reorder, then unpin one on B. | Pins converge in their proper scope and order; the unpinned item does not return. Profile/Space-owned pins do not leak into unrelated owners. App scope is intentional account-wide visibility. |
| SYNC-T02 | P0 / Manual | With existing synced pins, change the global pin-scope setting through supported scopes. Verify both devices after each settled transition; restart B. | The scope setting and migrated pin identities converge. Old-scope identities disappear without losing the intended pins or retaining duplicates in old and new owners. |
| SYNC-T03 | P1 / Assisted | Delay the scope-setting update to B while delivering pin entities/tombstones created by A's scope change. Then deliver the setting. | Mismatched-scope arrivals/deletions wait safely and are processed after scope agreement. A scope-migration tombstone is not incorrectly treated as a user deletion defeated by an edit. |
| SYNC-T04 | P1 / Manual | Create a pinned split pair. Confirm it on B. Offline A edits one pin while B deletes the pair/partner; reconnect. Run independently for Profile and Space scope. | An edited surviving pin is retained. If its partner did not also survive, it returns unlinked; no broken split or phantom partner remains. A Profile-scoped pin is not blocked by a nonexistent Space owner. |
| SYNC-T05 | P1 / Manual | Reverse T04's direction: disconnect A and delete a synced pin there, including a run where the deleted pin is one half of a split pair. On online B edit that pin's supported title/URL fields and publish. Reconnect A. Run independently for Profile and Space scope, and repeat on an account whose logical time runs ahead of wall clock. | A's pending deletion is cancelled and the pin survives in its own scope with B's content on every device, also when logical time is ahead of wall clock. A split partner that was deleted and not itself edited stays gone, and the survivor returns unlinked; no broken split or phantom partner remains. |

## URL rules and actual navigation

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-R01 | P0 / Manual | Create a rule for a QA host/path → S1 on A. On B inspect it and open a matching URL through the product's routing entry point. Change ask/automatic behavior on B, then retest on A. | Rule fields arrive and the real navigation uses the corresponding local S1/Profile. Ask behavior follows the synced value without restart; merely displaying the rule is insufficient. |
| SYNC-R02 | P0 / Manual | Retarget that rule from S1 to S2. Open matching URLs on both devices. | The same rule changes target, with no extra rule created. Navigation uses S2 and its Profile; the old route is no longer active. |
| SYNC-R03 | P1 / Manual | Reorder overlapping rules on A; inspect order and actual routing on B. Include exact-host/wildcard and shorter/longer path fixtures approved against the current router. Repeat with equal-priority rules created on different devices. | Both native and Chromium routing entry points select the same target for the same URL. Equal-priority ties resolve consistently across devices; remote landing does not cause repeated reorder publication. |
| SYNC-R04 | P0 / Manual | Create an Incognito-target rule, sync it and open a matching URL on B. Delete the rule on B and repeat navigation on A after convergence. | It targets a local Incognito Space, including creating one when needed, rather than waiting for an ordinary Space mapping. Deletion propagates and removes that routing behavior. Incognito browsing content itself is not synchronized. |
| SYNC-R05 | P0 / Manual | Delete a rule and verify its route disappears. Separately delete S2 while it owns two rules. | Rules are removed on both devices. Deleting the Space removes its rules without routing into another Space or leaving active orphan routes. The receiving device does not generate new independent deletions merely because it saw the Space tombstone first. |
| SYNC-R06 | P1 / Manual | Fresh pairing fixture: before joining, create the same two normalized host/path/target rules on A/B, targeting their initial default Spaces. Join A first, then B. Edit the adopted rules on each device. | B adopts the account identities and keeps two rules, not four. Both adopted rules remain bidirectionally editable and route correctly; adoption itself does not create extra server entities/tombstones. Engineering may confirm counts. |
| SYNC-R07 | P1 / Manual | From a synced baseline, disconnect A/B and independently create rules with the same normalized host/path/target. Reconnect and let at least three completed convergence rounds settle without further edits. | Equivalent rules collapse to one effective rule and both devices route identically. Persistent duplicates require investigation; record any documented `yield_no_partner` exception with evidence rather than accepting duplicates generically. |
| SYNC-R08 | P0 / Manual | Use a rule with no equivalent partner and a live target. Offline A changes ask behavior; B deletes and publishes. Reconnect A, then delete again after convergence. | The edit survives and the rule reappears with A's value; actual routing honors it. The later non-concurrent deletion removes it everywhere. Confirmed at `d49cf41`: a tombstoned row still undeletes, and the yield republishes at the tombstone's own version — an update, not a create — so this is not a create-path case and needs no *create-guard* image. |
| SYNC-R09 | P1 / Assisted | Delay a rule's target Space/mapping on B while delivering the rule; later release it. Separately test a concurrent edit while an equivalent-rule collapse is still pending. | Unknown ownership waits without retargeting or dropping the rule. Once resolved it lands and routes correctly. Collapse preserves an unpublished edit by transfer or documented yield; it must not silently replace it with an older copy. |
| SYNC-R10 | P1 / Manual | Reverse R08's direction: disconnect A and delete a rule with no equivalent partner there. On online B change that rule's path or ask/automatic behavior and let it publish. Reconnect A. Separately, let a duplicate-rule group collapse and then deliver an edit for the collapse loser. Repeat on an account whose logical time runs ahead of wall clock. | A's pending deletion is cancelled: the rule survives on every device with B's value and real navigation honors it, also when logical time is ahead of wall clock. An engine-authored collapse-loser deletion is **not** cancelled by an edit — the group still settles on one effective rule and no duplicate returns. |

For R03, configure each row below as an independent fixture. Exercise both
address-bar navigation and a clicked link/redirect so native and Chromium
routing are covered. Use the same URL, rules and account mappings on A/B.

| Rules | Test URL | Expected target |
| --- | --- | --- |
| `example.com`, `/` → S1; `example.com`, `/docs` → S2 | `https://example.com/docs/page` | S2: longer matching path wins |
| `*.example.com`, `/` → S1; `docs.example.com`, `/` → S2 | `https://docs.example.com/page` | S2: exact host wins when path specificity ties |
| `example.com`, `/docs` → S1; `example.com`, `/` → S2 | `https://example.com/docs-other` | S2: `/docs` does not match a different path segment |
| Any broad website-routing rule | `chrome://version` | No Space-routing match or routing prompt |

For equal path/host specificity, lower rule order wins; complete ties use the
account-level tie-break key, then rule ID. Compare final targets across devices
instead of predicting a winner from device-local Space IDs.

## Chromium data and isolation

Datatype support at the server is not proof that a particular framework exposes
or enables it. Record enabled types and the observation surface with the build
owner before C01–C04. A missing required type is a scope/blocker decision, not an
automatic pass. Use developer sync diagnostics when the app has no suitable UI.

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-C01 | P0 / Assisted | In Work on A change a confirmed syncable Chromium preference (for example the default search engine using a QA-approved engine). Inspect Work and Personal on B; reverse roles. | The supported preference converges within the matching Profile namespace. Personal remains unchanged. Phi settings tests do not substitute for this Chromium-engine check. |
| SYNC-C02 | P1 / Assisted | In Work on A visit a unique eligible HTTP(S) page, then verify history on B. Delete that history entry through supported UI and verify the remote deletion path. | Eligible history and deletion directives synchronize in the matching Profile. Personal and Incognito history do not acquire the test visit. Record framework history eligibility/retention restrictions. |
| SYNC-C03 | P1 / Assisted | Install a QA extension eligible for sync. Change a fixture value using its `storage.sync` API, then uninstall through the supported workflow. | Extension presence and sync-backed setting reach the matching Profile; uninstall propagates where supported. Extension `storage.local`, cookies and arbitrary extension files are not expected to synchronize. |
| SYNC-C04 | P1 / Assisted | Open ordinary tabs on A and inspect remote session data on B using the supported surface. Close/update tabs and reconnect after a network interruption. | Remote session data updates without being misclassified as pins. Do not require automatic restoration of live tab contents, login cookies, scroll position or unsaved form state. |
| SYNC-C05 | P0 / Assisted | Put distinct synthetic cookies, a Chromium-stored password and autofill data in A. Use the reserved PhiChat Profile. Inspect B and sync diagnostics/server datatype metadata. | This service does not transport those excluded datatypes. PhiChat is absent from pairing/key registration and its browser sync engine remains gated. A separate password manager or chat backend must not be mistaken for this sync path. |
| SYNC-C06 | P0 / Manual | U1 has distinct data on A/B; U2 has its own fixture. Switch B U1 → U2 → U1. Edit each account only while it is active, including its default-Space role. | Each account gets its own remote data/mappings. No U1 entity or default-Space UUID is uploaded under U2. Returning to U1 replays safely instead of overwriting U1 from an advanced marker without matching cursors. Each switch drops `phi.sync.hlcMax`, `phi.sync.wallClockOffsetMs` and `PhiDefaultSpaceUuid`, and the first pull of the first round re-learns them before any commit is sent, so the previous account's logical time, clock correction or default-Space identity is never published under the new one. Account-transition UI alone is not proof: verify A and U2's peer/diagnostics. |

## Offline operation, invalidation and recovery

| ID | Priority / mode | Preconditions and steps | Expected result |
| --- | --- | --- | --- |
| SYNC-F01 | P0 / Manual | Disconnect B. Make distinct edits to all five Phi kinds on A and other independent edits on B. Restart B offline, then reconnect it. | Persisted local edits survive restart. Reconnect merges both devices' non-conflicting work; no data loss, blanket deletion or upload of a stale snapshot occurs. |
| SYNC-F02 | P0 / Assisted | Keep B's SSE connection healthy. Edit a Phi setting and a Chromium preference on A; capture notification/catch-up and visible arrival on B. | Both sync paths wake and converge without manual refresh or restart. Receiving SSE `ready` alone is not accepted as evidence that data caught up. |
| SYNC-F03 | P0 / Assisted | Block only `/sync/invalidations` while key/data requests remain available. Edit A. Then restore SSE. Independently drop the stream, restart the test listener/service and repeat. | Fallback pulls still converge. Reconnect catches missed changes, does not duplicate data, and restores live notifications. No persistent request storm or frozen engine remains. |
| SYNC-F04 | P1 / Manual | Sleep B while A edits each data kind, then wake B. Repeat after B is offline for an extended period, and with a third device C joining after earlier edits/deletions. | B/C catch up to the final account state, including deletions, without manually touching a local setting to trigger sync. No unedited deleted data reappears. |
| SYNC-F05 | P0 / Assisted | Expire/invalidate B's token or withhold it during session restoration, without confirming sign-out. Restore authentication for the same account. Independently withhold/return the same Profile key. | Sync pauses without treating temporary uncertainty as logout or discarding metadata. With restored identity/token/key it resumes; no duplicate namespace or permanent startup stall. |
| SYNC-F06 | P0 / Assisted | Fail GetUpdates while B has local edits, then restore it. Separately force a multi-page replay beyond one round's page budget, and a commit conflict after a successful pull. | Failed/incomplete pulls authorize no publication in that round. Local edits survive. Publication follows a fully drained pull; a conflict retry first pulls/merges again and is bounded. Confirm through scoped request/round diagnostics, not timing alone. |
| SYNC-F07 | P0 / Assisted | Force native cursor/marker-directory writes to fail on B, then separately fail account-defaults persistence. While failing, change rules/pins/bookmarks and Space/settings on A. Restore writes. | Failed pages report `cursor_save_failed`, do not advance their marker and publish no local changes/tombstones. Recovery replays and converges without loss. Successful earlier pages may already have advanced the marker. Verify actual injected write failure; changing permissions alone is not evidence. |
| SYNC-F08 | P0 / Assisted | In an acceptance build, interrupt B once after landing but before marker persistence; repeat independently between owned-item kinds. A supplies a controlled page with changes to all five Phi kinds. Restart B. | B replays the uncommitted page safely. All changes land exactly once in the final state, with no missing or duplicate rows and no crash loop. Use the deterministic hooks below, not a manually timed force quit. |
| SYNC-F09 | P0 / Assisted | Export an A backup, make further changes on A/B and converge, then restore the older backup to A. Separately lose one owned-item cursor table while retaining local data. | Restored marker/cursor recovery replays remote changes. A does not interpret missing local history as an instruction to delete B's data or recreate account rows with new identities. B remains intact. |
| SYNC-F10 | P1 / Assisted | Inject unreadable ciphertext for one entity/settings payload or an unresolved Profile/Space key, while keeping other valid entities available. Repair the fixture/key and replay. | Unreadable data is not overwritten with local defaults or leaked as plaintext. Eligible unaffected data can progress according to its gates. Recovery is retryable; unresolvable ownership is not silently assigned elsewhere. |
| SYNC-F11 | P1 / Assisted | Run A/B/C on the current convergence build with a controlled clock-skew fixture. Bound the injected skew to **under 5 minutes** (below `PhiHybridClock.wallClockCorrectionThresholdMs`) so no source-side correction applies and the hybrid logical clock alone orders the edits; the fixture must also offset the `Date()` that `LocalStore` writes into `contentUpdatedDate`/`locationUpdatedDate`, not only `hlcNow()`, or the edit-time stamps stay honest and the case proves nothing. B first observes A's edit, then makes a causally later edit while its wall clock is slower. Separately vary reconnect order for independent offline edits. | Causally later observed edits win despite the slow clock. All devices converge. Do not require every concurrent offline edit to survive same-field LWW, or assume that last upload wins. Prefer an injected clock over changing an active Mac's system clock/authentication environment. |
| SYNC-F12 | P2 / Assisted | Upgrade a supported previous persisted-store fixture to this build. Separately run a supported mixed-client pair with one older client lacking the new convergence behavior. | Supported upgrades preserve data and complete replay. Record expected feature differences: old clients may lack default-role sync, edit-over-delete protection, `pendingProjection` edit-time Space stamping or source-side clock correction. A Mac older than `83361acd` against a server at `sha-d49cf41` or later can strand an entity: it retries a create CONFLICT as another create and gives the entity up after three rounds. Ruling C3-c: that combination is **unsupported** — scope any mixed-client pair to clients at `83361acd` or newer and record an older client as Blocked. Do not promise unsupported downgrade compatibility or classify documented old-client behavior as a new-build regression. |
| SYNC-F13 | P0 / Assisted | Put B's clock one hour off through the injected-clock fixture, with A correct and both converged. Let B complete one pull, then edit the same fields on A and afterwards on B, and inspect B's published stamps, the metadata log and the retention timestamps of a deletion made on B. Repeat the whole case with a 2-minute offset. | At one hour the offset exceeds the 5-minute threshold: the whole measured offset corrects the stamps B publishes, the change is logged once at metadata level (offsets and threshold only), and B's later edits win on every device. `deletedAtMs` and the 30-day retention window stay on B's uncorrected wall clock. At 2 minutes no correction is applied at all and the edits still converge. |
| SYNC-F14 | P0 / Assisted (*create-guard*) | On a service at `sha-d49cf41` or later, after a fresh join take A and B offline and on each first-publish the same client tag with different content — for example the same normalized host/path/target URL rule. Reconnect both and let at least three completed rounds settle without further edits. | The losing create is answered with CONFLICT carrying the live row's entity id and version; the loser harvests both and its one scoped retry is an update at that version, not a second create. One entity with one identity survives, no cursor is left with an empty entity id and a version above 0, and the item keeps synchronizing after three or more rounds instead of being given up. |
| SYNC-F15 | P0 / Manual | Populate a store with a V12 build (URL-rule sync columns present, no bookmark location edit column), then upgrade that same user data directory to this build. Inspect pre-existing bookmarks, move one locally, and inspect it again. | Migration completes, the app starts and no data is lost. `locationUpdatedDate` is nil for pre-existing rows and is set after a new local move; nothing is republished merely because the column was added. |

## Deterministic fault checks and evidence

F07–F10 require a disposable dataset and an engineer who can restore the fixture.
This document does not authorize production resets. A hook being compiled out is
a blocked test setup, not a successful crash-recovery test.

Current crash hooks are compiled only with `DEBUG` or
`PHI_SYNC_DEBUG_SWITCHES`:

```sh
# Replace the placeholder with the actual test application's bundle identifier.
# Enable one hook at a time, then let the prepared remote page reach this app.
defaults write <test-bundle-id> phi.sync.debug.abortAfterApply -bool YES
defaults write <test-bundle-id> phi.sync.debug.abortBetweenKinds -bool YES
```

Each hook clears itself before aborting. Confirm the deliberate-abort log and
which page/stage was interrupted; inspect/remove a still-armed hook before
reusing the fixture. An ordinary ad hoc signature alone does not enable them.

Capture the following for each failure, with account identifiers redacted and
recovery codes, tokens and decrypted secrets excluded:

| Evidence | What it establishes |
| --- | --- |
| Case/variant ID, native commit/build, framework version/UUID, service version, environment | Exactly which combination was tested |
| A/B/C identities, Profile/Space mapping and before/after manifest | Correct owner, tree, values and counts; not just matching labels |
| Timestamped screen recording/screenshots and operation/reconnect order | Which edits were concurrent and when the UI converged |
| `[phi-sync] round` outcome, pages, `marker_advanced`, `cursor_save_failed` | Whether the pull completed and persistence permitted publication |
| Per-kind `pulled`, `applied`, `pushed`, `tombstones`, `parked`, `refused`, `resurrected` when emitted | Loss, repeated publication, legitimate resurrection and pending ownership |
| URL-rule `adopted`, `collapsed`, `transferred`, `yield_no_partner` | Identity adoption/collapse and preservation of an unpublished edit |
| Redacted SSE/HTTP diagnostics and cursor snapshots captured by engineering | Notification delivery versus actual sync and durable progress |

Counts alone are insufficient: one missing row plus one duplicate leaves the
same total. Do not require `parked == 0` when the case intentionally leaves an
owner unresolved. A published tombstone remains in server history, so total
server rows are not equal to visible live UI rows.

## Execution order and result sheet

Before any acceptance run, engineering runs the hostless convergence gate on the
commit under test: `bash build-scripts/test-sync-convergence.sh` must exit 0.
Exit 1 is an unexpected property violation and blocks acceptance. Exit 2 means a
registered expected failure stopped reproducing and must be removed from the
harness's expected-failure list before the run counts. Record the exit status
with the build combination.

Start with A01–A04, P01/P03/P04, S01/S04, B01, T01, R01/R02,
C01/C06 and F01/F02 as the smoke sequence. Then run the remaining P0 cases;
the smoke subset does not replace release acceptance. Run P1 before signing off
the complete feature, and P2 on the supported upgrade/version matrix.

| Run | Case / variant | Build combination | A/B/C fixture | Actual result / convergence time | Status | Evidence / issue / owner |
| --- | --- | --- | --- | --- | --- | --- |
| `<run>` | `SYNC-...` | `<native / framework / service>` | `<fixture>` | `<observations>` | Not run | `<link>` |

Allowed statuses: **Not run, Pass, Fail, Blocked, Not applicable**. Record a reason
and owner for Blocked/Not applicable. Release sign-off must list unresolved
failures and explicitly accepted known limitations; do not turn them into Pass.
In particular, rank-conflict convergence has registered expected failures in the
hostless harness, and first settings adoption is not atomic across all writes.
Their exact applicability must be reviewed against the tested build.

## Source references

- [Sync behavior and invariants](sync.md): pairing catch-up, default Space,
  hybrid logical clocks, edit/delete rules, marker persistence and known limits.
- [Key setup UI](../Sources/Sync/Keys/UI/KeyLayerView.swift),
  [pairing wizard](../Sources/Sync/Keys/UI/PairingWizardView.swift),
  [self-removal contract](../Sources/Sync/Keys/UI/SelfRevokeStrings.swift).
- [Registered settings](../Sources/Sync/Phi/SyncableSettings.swift),
  [Space merge](../Sources/Sync/Phi/SyncableSpaces.swift),
  [owned items](../Sources/Sync/Phi/SyncableOwnedItems.swift),
  [URL rules](../Sources/Sync/Phi/URLRuleKind.swift).
- [Sync engine and debug hooks](../Sources/Sync/Phi/PhiSyncEngine.swift),
  [native notification scheduler](../Sources/Sync/Phi/PhiSyncInvalidation.swift),
  [convergence harness limitations](../Tests/SyncConvergence/README.md).
- Companion repository: `sync-service/internal/chromiumsync/datatype.go` for the
  server datatype allowlist. Its presence alone does not enable a client type.
- Company knowledge base, relative to `~/.agents/company-knowledge/`:
  `30-projects/phinomenon/sync-service/{operations,status,contracts}.md`,
  `30-projects/phinomenon/sync-service/design/2026-09-21-concurrency-review-rulings.md`
  and `design/2026-09-16-m3-4a-url-rules-marker-boundary-design.md` beneath that project.
  Historical design steps are context; current code and `sync.md` take precedence
  where later convergence changes supersede them.

## Sync UX acceptance (2026-09-23)

These cases supplement the data-convergence scenarios above. They remain **Not
run** until exercised with recorded app/framework/server versions on two Macs.
The implementation branch is `feat/sync-ux` based on native `1b4e7305`; framework
source changes are in the canonical Chromium checkout. This is not a release signoff.

| Case | Steps | Required result | Result |
| --- | --- | --- | --- |
| UX-01 | First device opens Sync, starts setup, saves and re-enters recovery code | No account creation before Continue; one-time warning; incorrect input/restart cannot bypass confirmation; one window through completion | Not run |
| UX-02 | B uses a bad recovery code, then corrects it | Editable retained input and actionable inline error; proceeds to matching | Not run |
| UX-03 | B requests approval; A approves in Sync | Matching codes/device, live expiry, recovery alternative; one continuous window | Not run |
| UX-04 | Later/close/Escape during load, choice, overwrite review, refresh and error; restart B | Local browsing works; Sync says unpaired/not started; no automatic reopening or data sync | Not run |
| UX-05 | Defer, change account Profiles/Spaces on A, enter B again; repeat offline | Fresh choices online; retry error offline without cached fallback | Not run |
| UX-06 | Delay fresh review; try Back/change mappings, then Later | Edits/navigation frozen; Later cancels; no unreviewed overwrite or late mapping writes | Not run |
| UX-07 | Interrupt/fail a confirmed partial mapping write; reopen and retry | Confirmed writes retained; unresolved choices reload; completion persists only after all mappings | Not run |
| UX-08 | Switch accounts while loading, reviewing, approving or removing | No old response changes current account UI, mappings, credentials or engine | Not run |
| UX-09 | Rejoin a revoked fingerprint that rotates during registration; restart | Enrollment persists the new device identity; no redundant pairing after restart | Not run |
| UX-10 | Observe missing/old framework, offline, pending data, rejected commit and unreadable settings | Checking/offline/attention as appropriate; no global success from partial evidence | Not run |
| UX-11 | Add local data while status counts or native debounce are pending | Prior success invalidated; returns to success only after actual work completes | Not run |
| UX-12 | Fail device list load, return empty list, use duplicate names, approve expired request | Errors differ from empty results; current Mac identified by key ID; no invented last-seen time | Not run |
| UX-13 | Remove device, cancel removal, try last-device removal; then Later | Explicit local-data preservation; rejection actionable; Later still available | Not run |
| UX-14 | Keyboard navigation, VoiceOver, narrow window, long translations | Actions discoverable; focus/order and recovery-code acknowledgement usable | Not run |
| UX-15 | Approve B, then Finish later during matching without reopening settings | B remains unpaired; the existing Sync pane shows authorized devices and removal controls | Not run |
| UX-16 | Complete Profile writes, fail the second Space write, then Retry and Finish in the same session | Completed mappings are reused; still-valid unwritten choices survive; independent server changes still require review | Not run |
| UX-17 | Complete B's login while A's confirmed cleanup is waiting for its database write; keep Sync settings closed | B initializes automatically after cleanup exits; no A state crosses accounts | Not run |
| UX-18 | Open synced bookmarks/pins or update only their favicons; then edit and revert content within debounce | Local-only changes retain success; real edits invalidate immediately and their round restores status even after a revert | Not run |
| UX-19 | On B open join-method selection, request approval, cancel and request again three times; repeat with window close and recovery entry | No Finish later before verification; A's refreshed list contains only B's current request; approving it advances B; other devices' requests survive | Not run |
| UX-20 | Match Profiles with same-name local/account Spaces, revisit Profile choices, edit or clear a Space picker and go Back; repeat with ambiguous names and stale Space identities | Unique names within the selected Profile are preselected; stored valid identities win; explicit choices survive Back; ambiguity stays undecided; no writes before Finish | Not run |

Automated evidence is recorded separately from these manual cases: hostless
pairing/device/status/invalidation regressions and convergence properties have
executed; native `build-for-testing` compiles hosted tests but does not run them.
Targeted Chromium object builds compile the changed implementation/tests; a new
`components_unittests` binary has not been linked/executed in this task.

The PR #153 follow-up regressions also run without launching a browser host:

- `build-scripts/test-sync-cleanup-resume.sh`: deferred login, account replacement,
  sign-out, request coalescing, and ordinary removal.
- `build-scripts/test-sync-pairing-retry.sh`: registration/adoption/creation retries,
  retained choices, changed server candidates, local edits during submission,
  same-name Space suggestions, Profile changes, ambiguity and manual overrides.
- `build-scripts/test-sync-join.sh`: production verification state machine and
  account manager with in-memory keys/transport; cancel/recovery/close withdrawal,
  stale same-key requests, failed withdrawal, delayed POST, cancelled approval
  polling and successful current approval.
- `build-scripts/test-sync-setup-dismissal.sh`: pane refresh notification on defer,
  unchanged enrollment, and duplicate/retired-session suppression.
- `build-scripts/test-sync-local-changes.sh`: Core Data/Combine publishers and the
  production SwiftData schema, local-only and failed saves, immediate content
  invalidation, debounced bursts, and edit/revert settlement.

These use production code with temporary or in-memory app/transport/storage
boundaries. They do not mark the manual app UI or two-Mac cases above as passed.

### Coordinated last-success acceptance (PHI-1251)

- With at least two user Profiles, close Settings and change Chromium data. Open
  Settings after catch-up: the common time advances only after native data and
  both Profiles complete a fresh round. Merely opening/reopening Settings must
  not synthesize or reset that time.
- Hold one Profile offline or with pending/error state. Let native and the other
  Profile finish: the previous common time remains. Restore the held Profile and
  verify one completed barrier advances the time without repeated refresh loops.
- Add/remove a Profile during an outstanding status callback; completion must
  wait for the current participant set. Switch accounts during the callback and
  verify neither the new account nor the retired account receives a late write.
- A framework lacking status support remains Checking. Explicit reconfiguration
  or removal clears the common time. Restart preserves the last recorded time
  as history and requires fresh completion before claiming Up to date.
- Sentinel is a hostless registration-hook test only; no Sentinel transport is
  enabled by this change. Live two-Mac acceptance remains required before release.
