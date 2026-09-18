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
