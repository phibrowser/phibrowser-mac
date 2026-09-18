# M3-4a lane R — implementer deviation ledger

## Task 1

- **计划裁定三 (`testUnknownKindSurvivesRoundTrip` field-slot fix, PR19-style):** the
  brief's task-1-brief.md flags that `PhiEntityProtoTests.testUnknownKindSurvivesRoundTrip`
  (written in M3-2, `c96c8158`) probed `Data([0x1A, 0x00])` as "a future client's field 3",
  but M3-3 gave field 3 to `bookmark` (`phi_entity.proto:21`, pinned by
  `PhiEntityGoldenBytesTests.testKindOneofUsesFieldThreeForBookmarkAndFourForPinTab`), which
  made the test's own comment wrong (though the assertion still happened to pass, since an
  unknown-field probe and a known-field decode are not distinguishable by this test's
  assertions alone in the general case — here it stayed red only in spirit, not in CI, because
  the wire bytes for an empty `bookmark` and an "unknown field 3" both round-trip identically).
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
