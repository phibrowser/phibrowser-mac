# M3-4a lane R — implementer deviation ledger

## Task 1

- **计划裁定三 (`testUnknownKindSurvivesRoundTrip` field-slot fix, PR19-style):** the
  brief's task-1-brief.md flags that `PhiEntityProtoTests.testUnknownKindSurvivesRoundTrip`
  (written in M3-2, `c96c8158`) probed `Data([0x1A, 0x00])` as "a future client's field 3",
  but M3-3 gave field 3 to `bookmark` (`phi_entity.proto:21`, pinned by
  `PhiEntityGoldenBytesTests.testKindOneofUsesFieldThreeForBookmarkAndFourForPinTab`). This
  test was already red on `c549c4c5`, as the brief states ("已经是红的"): SwiftProtobuf's
  `BinaryDecoder.decodeSingularMessageField` materializes an empty message for a zero-length
  body, so `Data([0x1A, 0x00])` decodes to `.bookmark(Phi_PhiBookmarkEntity())`, not to an
  unrecognized field, and `XCTAssertNil(decoded.kind)` fails.
  This task is the one that finally occupies slot 5 (`url_rule`), so it is the last natural
  place to also retire the stale slot-3 probe before a THIRD person mistakes 3 for still being
  free. Fixed by moving the probe to field 13 (`(13 << 3) | 2 == 0x6A`), which remains unowned
  across the whole `kind` oneof as of this commit (5 = `url_rule`, 6 = reserved-by-comment for
  M3-4b's `profile`). This is a fix to a pre-existing test-comment/field-choice staleness, not
  a change introduced by this milestone's own schema work.

- **计划裁定四 (`Proto/README.md:27` generated-type-name line, completed rather than
  appended):** the "Generated Swift type names" line under package `phi` had never been
  updated past M3-1's three types (`Phi_PhiEntity`, `Phi_PhiSettingEntity`,
  `Phi_PhiSettingValue`), even though `Phi_PhiSpaceEntity` (M3-2), `Phi_PhiBookmarkEntity` and
  `Phi_PhiPinTabEntity` (M3-3) had shipped since. Rather than appending only
  `Phi_PhiURLRuleEntity` onto an already-incomplete list, this task rewrote the line to name
  every generated `phi`-package message type that exists in `Generated/phi_entity.pb.swift` as
  of this commit (verified via `grep -n "^nonisolated struct Phi_" phi_entity.pb.swift`): all
  seven — `Phi_PhiEntity`, `Phi_PhiSettingEntity`, `Phi_PhiSettingValue`, `Phi_PhiSpaceEntity`,
  `Phi_PhiBookmarkEntity`, `Phi_PhiPinTabEntity`, `Phi_PhiURLRuleEntity`. The brief's own prose
  says "六个" (six) for this line while also saying "含 Phi_PhiURLRuleEntity"; read as "six
  types besides the anchor `Phi_PhiEntity` the sentence already names" this is exactly the
  seven-type list produced here, so no value was chosen against the brief — this note exists
  only because the literal count in the brief's prose does not match the literal type count
  without that reading, and a future reader diffing against the brief text alone might wonder
  why the line lists seven names.

- **`Proto/README.md`'s closing "Keeping this in sync" paragraph (not one of the brief's four
  listed README spots, fixed anyway):** the brief's Step 6 names four exact locations to edit
  (`:27`, the field table, the reserved-range sentence, the client-tags table). The file's final
  paragraph ("`PhiEntity.kind` is an open oneof...") still said "5 / 6 are spoken for by M3-4's
  URL rules and profiles" in the future tense, which was accurate before this commit and wrong
  after it (5 is now a real, shipped field, not a reservation). Left uncorrected it would sit
  right below the field-number table this task just updated and contradict it. Reworded to "M3-4a
  took 5 for URL rules; 6 is spoken for by M3-4b's profiles" -- same sentence, updated tense, no
  other content changed.

## Task 4

Controller ruling (not a deviation): the brief names the ledger as
`docs/superpowers/sdd/m3-4a-progress.md`; in lane R the file is this one
(`m3-4a-progress-r.md`).

- **计划裁定一 (CASE numbering C-10 / C-11):** spec §12.1's compatibility block stops at
  C-9; the `deletedDate` default-read filter (R-M3-4a-51) and the `syncId` backfill's
  distinctness / lowercase / idempotence (R-M3-4a-23) had prose only, no CASE number. The
  plan numbered them C-10 / C-11; both live in the new
  `Tests/PhiBrowserTests/LocalStoreURLRuleThrowingTests.swift` next to C-1 / C-2 (Task 5
  appends C-6 ~ C-9 to the same file). Task 12 folds this into spec §15.

- **计划裁定二 (`Compatibility/README.md` V11 line):** that README has no version-history
  section (Background / Design / Opening Flow / Development Rules only), so no new section or
  table was opened. One English sentence appended at the end of the file, wording set by the
  plan: "The current store format is 11 (`TabDataModelSchemaV11`), which adds the six
  `SpaceURLRule` account-sync columns and the two `ProfileModel` columns."

- **计划裁定三 (derived version expressions in `LocalStoreCompatibilityTests`):** the two
  assertions on the shipping configuration (`:393` / `:394`) keep the literals `11` /
  `1...11` — they are the anchor of the whole chain. The "too new" group
  (`testShippingReadableStoreFormatVersionBounds`) and the "older build" group
  (`testStoreFormatElevenIsPreservedWhenOpenedByAnAppThatOnlyReadsTen`) now derive from
  `LocalStore.compatibilityConfiguration.currentStoreFormatVersion` (`+ 1` → `tooNewVersion`,
  `- 1` → `olderBuildVersion`). After the sweep the only remaining `\b10\b` literals in that
  file are the backup-version group (`:353` / `:368` / `:380` / `:388`), which name the V10
  store being upgraded and are correct as literals.

- **Two further rulings the brief carried, applied as written:** (a) C-1 / C-2 go in the new
  file, not in `LocalStoreCompatibilityTests` (that file runs on text placeholder files and
  two throwaway schemas; it never reaches `migrateV10toV11`); (b) `ProfileModel.init` gains
  no parameters — `syncId` / `createdDate` are declared-but-dead in M3-4a and default to nil
  on the `@Model` (precedent `TabDataModelSchemaV10.TabDataModel.syncId`).

- **spec line-number errata (measured on `c549c4c5`, unchanged at `32889806`):**
  `LocalStore.compatibilityConfiguration` is at `LocalStore.swift:44-48` (spec §4.2 says
  `:37-42`); the production `ModelContainer(for:…)` is at `:129-137` (spec says `:131-137`;
  `migrationPlan:` at `:135` matches); the `migrateV8toV9` backfill precedent is at
  `TabDataModel.swift:146-163` (spec says `:145-161`). spec §12.1 CASE C-3 says "11 处 `10`";
  the measured count is 12 (`:357 :358 :369 :379 :393 :394 :397 :398 :412 :435 :449 :456`) and
  all 12 were changed; the one the "11" count misses is `:412`.

- **Implementer deviations (comment / message level, no assertion changed):**
  1. `LocalStoreCompatibilityTests`: the CASE 2a.24 header comment now reads "schema V11"
     and is tagged "/ C-3"; the CASE 2a.25b header is rewritten to describe V11's six columns
     (account identity, soft-delete intent, merge partner) and tagged "/ C-4"; the two
     `XCTFail` messages moved one version up ("version ten store … version eleven app",
     "version eleven store … refused by a version ten app"). The brief's table lists only the
     literals, neighbours and function names; leaving the comments on V10/V9 would have made
     them contradict the code directly below.
  2. C-2 carries three structural assertions beyond the brief's two: `schemas.count == 11`,
     `TabDataModelSchemaV11.versionIdentifier == Schema.Version(11, 0, 0)` and
     `TabDataModelSchemaV11.models.count == 5`. Additive; the brief's two
     (`stages.count == schemas.count - 1`, `schemas.last` is V11 by `ObjectIdentifier`) are
     present verbatim.
  3. C-10 subscribes to `urlRulesPublisher()` **before** inserting the four rows (the brief
     fixes "subscribe and take the first value, then `save()`" but not the order of insert vs
     subscribe). `ModelContext.fetch` includes pending inserts, so subscribing after the
     inserts could make the initial emission already equal the post-save projection, and the
     publisher's `removeDuplicates` would then swallow the post-save emission — step ③ would
     time out. Subscribing first pins the first value to `[]` and makes the post-save emission
     structurally distinct.
  4. `getAllURLRules()` gained a two-line `///` doc comment naming the R-M3-4a-51 filter and
     that `urlRulesPublisher()` follows it; `TabDataModelSchemaV11.SpaceURLRule.init` carries
     a two-line `//` comment on why all six new parameters default. The V11 file header is in
     English (V10 precedent) and carries the brief's required substance (one migration instead
     of two; `beforeSchemaUpgrade` copies the whole store + sidecars each bump; favicon PNG
     bytes are inlined on bookmark rows; README forbids folding backup deletion into a schema
     change).

## Task 5

Commit scope: `LocalStore+SpaceURLRule.swift` (rewrite), `LocalStore+Space.swift`,
`PhiSpaceLocalAccess.swift`, `SpaceManager.swift` (`:1410` + the two wrapper bodies),
`LocalStoreURLRuleThrowingTests.swift` (+25 cases), `URLRouterTests.swift` (two assertions),
`PinnedTabScopeTests.swift` (two call sites), this ledger. Verification is compile-only
(`build-for-testing`, exit 0, no warnings in the touched files); the new cases were confirmed
present in the built `PhiBrowserTests` bundle via `nm`, not executed.

- **计划裁定一 (per-row bodies are `internal`):** `upsertURLRuleBody(…in:)` /
  `hardDeleteURLRuleBody(syncId:in:)` are internal, not private, so Task 8's
  `applyURLRuleSyncBatchBody` can compose them inside one write block (nesting a second
  `performBackgroundWriteAndWaitThrowing` deadlocks the serial write actor). spec §4.3 item 6
  only names the throwing halves.

- **计划裁定二 (`URLRuleDraft` carries "which units were sent" as `Optional`):** `content:
  ContentUnit?` (host / pathPrefix / askBeforeRouting share one stamp, so they travel as one
  unit), `spaceId: String?`, `sortOrder: Int?`, `createdDate: Date?`; `nil` = "not sent" ⇒ the
  body writes nothing, stamps nothing, and does not count it towards `pendingLocalEdit`. Sent
  but equal ⇒ also a zero write. This extends spec §4.3 item 1 / Task 11 rulings 1-2.
  Two additions ruled by the controller when the brief's literal signature could not compile
  against pre-Task-11 code:
  1. the flat convenience init takes `spaceId: String? = nil` (the brief wrote `spaceId:
     String`): the four leaf construction sites (`AgentSpaceRouter+Management.swift:248/:308/:350`,
     `SpaceURLRulesEditor.swift:143`) and `URLRouterTests.swift:383` do not pass a target;
     `SpaceManager.setAllRules` / `setRules` overwrite `draft.spaceId` from the dictionary key /
     `forSpaceId` anyway. Task 11 passes `spaceId:` explicitly at those sites.
  2. three read-only forwarding accessors on `URLRuleDraft` (`host` → `content?.host ?? ""`,
     `pathPrefix` → `content?.pathPrefix`, `askBeforeRouting` → `content?.askBeforeRouting ??
     false`), each documented as a compatibility read for pre-Task-11 callers (the two optimistic
     pushes at `SpaceManager.swift` read `draft.host` / `draft.pathPrefix` /
     `draft.askBeforeRouting`; so does `URLRouterTests:383`). Task 11 / 8b-4 use `content`
     directly; the accessors can be retired with the pushes.
  The flat init lives in `extension LocalStore.URLRuleDraft` so the synthesized memberwise
  initializer (`init(id:syncId:content:spaceId:sortOrder:createdDate:contentUpdatedDate:)`, every
  parameter defaulted) stays available — that is the "成员逐个构造" path the brief names for
  8b-4, and what the 置位表 cases use to send genuinely `nil` units.

- **计划裁定三 (`id` miss falls back to `syncId` and rewrites `row.id`):** the editor's
  `Row.init(from:)` turns a non-UUID historical id into a fresh UUID on every round trip; the body
  therefore locates by `syncId` when `byId` misses and adopts `draft.id` on the row (CASE
  U-14-legacy). spec §4.3 item 3 only says "insert".

- **计划裁定四 (densify domain includes the buckets of `deletedIds`):** a soft delete leaves a
  hole exactly like a retarget; `touchedBuckets` = every upsert's new bucket + every retargeted
  row's old bucket + every soft-deleted row's bucket. Same ruling as Task 11's ruling 4.

- **计划裁定五 (new rows mint no content stamp):** insert writes `contentUpdatedDate =
  draft.contentUpdatedDate` (nil for a genuinely new row) and `targetUpdatedDate = nil`; the
  no-baseline projection falls back to `createdDate`, which is the same instant.
  `pendingLocalEdit = true` still.

- **计划裁定六 (both `replace*` functions deleted now; `SpaceManager` wrapper bodies rerouted):**
  `replaceURLRules` / `replaceAllURLRules` and their contract comments are gone;
  `setAllRules` / `setRules` keep signature, stale doc comments (`:1910-1916` / `:1978-1981`) and
  the two optimistic pushes verbatim, and their bodies now compute `deletedIds` = affected cached
  rows not named in the payload, then `Task { try await applyURLRuleEditsThrowing(…) }` with an
  `AppLogError` + `PhiSyncLog.describe` catch. `SpaceManager.swift:1410` passes
  `origin: .userIntent` (no default ⇒ compile-forced), so Task 11 Step 2's line for it is a no-op.
  Post-check: `git grep 'replaceURLRules\|replaceAllURLRules' -- Sources` leaves only the stale
  `SpaceManager.swift:1914` comment (Task 11 deletes it). The brief expected two further hits in
  `TabDataModelSchemaV7.swift:135` / `V8.swift:137`; those lines mention
  `SpaceManager.setRules(_:forSpaceId:)`, not the replace functions — nothing to do there.
  **Pre-Task-11 consequence worth knowing:** the agent router's `draft(from:)` does not pass
  `id:`, so until Task 11 lands, each agent `urlRules.*` mutation soft-deletes the bucket's
  existing rows and re-inserts them under fresh ids / syncIds (user-visible behaviour equals
  today's delete-then-insert; the difference is soft-deleted rows accumulate locally). Rule sync
  is not live before Tasks 8/9, so nothing reaches the account; Task 11 must land before it does.

- **计划裁定七 (no `urlRuleChangesPublisher()` here):** spec §12.3 item 5 lists it under this
  task, §11's file table and the plan skeleton put it in `LocalStore.swift` under Task 8. Followed
  the latter; `LocalStore.swift` untouched.

- **计划裁定八 (R-M3-4a-104, a `syncId == nil` draft hitting a soft-deleted row):** step 2b in
  the body: the soft-deleted row is left byte-for-byte alone, the draft goes through the insert
  branch with a freshly minted `id` **and** `syncId` (`draft.id` is still held by the soft-deleted
  row under `@Attribute(.unique)`), `pendingLocalEdit = true`; a `syncId != nil` draft hitting a
  soft-deleted row throws `.rowAlreadyMapped` (that path belongs to the per-row primitives, whose
  soft-delete semantics are the opposite — CASE C-9 ①). CASE C-12 has all three legs. spec §4.3
  needs this cell; appendix C-39.

- **Further deviations / notes (implementer):**
  1. `Tests/PhiBrowserTests/PinnedTabScopeTests.swift:327` / `:710` call
     `deleteSpaceCascade(spaceId:)`; with `origin` mandatory they now pass `.userIntent`
     (controller ruling; both origins are identical for `TabDataModel`, which is all those tests
     assert on). File added to the commit.
  2. `URLRouterTests.swift`: the plan skeleton lists this file under Task 10 only; this task
     changed exactly the two "bare `/` ⇒ nil" assertions to `"/"` (§8.1) and renamed them
     `testNormalizeBareSlashBecomesRootOnly` / `testNormalizeMultipleSlashesCollapseToRootOnly`;
     the other four normalizer cases are untouched and still hold under the new function.
  3. `SpaceCascadeOrigin` is file-scope as specified; to keep it "紧挨着级联三件套" the single
     `extension LocalStore` in `LocalStore+Space.swift` is closed before the enum and reopened
     after it. `deleteSpaceCascadeBody` takes its one `now` at the top of the body.
  4. **CASE C-9 ③ as written in the brief is unreachable** with the specified signature:
     `upsertURLRuleBody(syncId:…)` addresses strictly by `syncId` over the full table and the
     brief's own semantics say "命中不到 ⇒ 建行、绝不抛 `.rowNotFound`". After `B.syncId → R3`,
     an upsert for `R2` finds no row, so it cannot throw `.rowAlreadyMapped`. The test writes the
     outcome those semantics produce — a new row is created, `B` is untouched, count +1 (probe:
     addressing never clobbers by anything but `syncId`). The `:2196-2199`-shaped guard is in
     both bodies but is vacuous under `syncId` addressing (commented as such). If a throwing ③ was
     intended it needs an `id:` parameter on the primitive — an API change Task 8 consumes —
     so it is left for a controller ruling.
  5. CASE C-8b orders the legitimate upsert (`B`) before the colliding one (`A`) so the
     `performThrowing` rollback is actually exercised; the brief listed `A` first, where the
     throw would happen before anything was written.
  6. The 2b-minted `id` is `UUID().uuidString.lowercased()` as the brief says (the draft default
     `id` is uppercase). The editor's `Row.init(from:)` re-uppercases via
     `UUID(uuidString:).uuidString`, so such a row misses `byId` on its next Save; harmless once
     Task 11 makes editor drafts carry `syncId` (ruling 3 adopts the new id), noted for Task 11.
  7. C-6's "structural assertion" is executable: the test reads
     `Sources/LocalStorage/LocalStore+SpaceURLRule.swift` via `#filePath` and asserts that
     `func applyURLRuleEdits(`, `func replaceURLRules(` and `func replaceAllURLRules(` are absent
     and `func applyURLRuleEditsThrowing(` is present.
  8. Test header comment now lists every case group Task 5 appended (the Task 4 wording said
     "C-6 ~ C-9" only).
