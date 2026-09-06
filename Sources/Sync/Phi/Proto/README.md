# Phi sync protobuf sources

Everything the Swift phi sync engine needs to talk protobuf, in three parts:

| Path | What it is |
| --- | --- |
| `phi_entity.proto` | The **payload** schema (proto3, package `phi`). Authored here. A serialized `PhiEntity` is what gets sealed with AES-GCM under the Phi domain key. |
| `sync/*.proto` | **Trimmed, wire-compatible copies** of Chromium's sync protocol (proto2, package `sync_pb`). |
| `Generated/*.pb.swift` | `protoc` output. Do not edit by hand — run `./Sources/Sync/Phi/Proto/generate.sh` from the repo root. |

## Toolchain

| Tool | Version |
| --- | --- |
| `protoc` | 36.1 (`brew install protobuf`) |
| `protoc-gen-swift` | 1.38.1 (`brew install swift-protobuf`) |
| SwiftProtobuf runtime | 1.38.1, pinned in `PackageCollection/Package.swift` |

The runtime version **must** match `protoc-gen-swift`; `generate.sh` warns when it does not.
Generation uses `--swift_opt=Visibility=Internal`, so every generated type is `internal` to
the `Phi` module.

## Generated Swift type names

`protoc-gen-swift` prefixes each type with the camel-cased proto package:

- package `phi` → `Phi_PhiEntity`, `Phi_PhiSettingEntity`, `Phi_PhiSettingValue`
- package `sync_pb` → `SyncPb_ClientToServerMessage`, `SyncPb_SyncEntity`, … (note: `SyncPb_`,
  **not** `Sync_pb_`)

## Scope decision: trimmed subset, not a full vendor

`entity_specifics.proto` imports ~50 per-datatype specifics files, and `sync.proto` pulls in a
large transitive closure (client_commands, client_debug_info, password sharing, sharing
messages, unique_position, deletion_origin, …). Generating all of it would add thousands of
lines of Swift for types the phi engine never touches.

Instead, `sync/` holds hand-trimmed copies: **same package, same message names, same field
numbers, types and labels**, with unused fields omitted. This is safe because:

- Protobuf ignores fields it does not know about when parsing, and `SwiftProtobuf` keeps them
  in `unknownFields` and re-emits them on serialize (covered by
  `testUnknownFieldsSurviveTheTrimmedSchema`), so the server's full messages still decode.
- Every field the client *sends* keeps its upstream number/type, so the server — which
  unmarshals with the full Chromium schema — reads exactly what it expects.
- `required` stays `required` (`ClientToServerMessage.share`, `.message_contents`), so a
  message that would be rejected by the server also fails to serialize here.
- `CommitResponse.EntryResponse` stays a proto2 **group** (start/end-group wire encoding, not
  length-delimited); changing it to a nested message would silently break decoding.

Source of truth: `sync-service` repo, branch `feature/m3-phi-sync`, directory
`proto/src/components/sync/protocol/`, vendored from **Chromium 150.0.7871.47**.
`phi_specifics.proto` is authored by the sync-service project (Apache-2.0), not Chromium; all
other files are Chromium (BSD-style license).

## Field-fidelity table

Every field kept in `sync/` below, with the number/type/label copied from the source proto.
Fields *not* listed were dropped; dropped-field lists are in the comments of each trimmed file.

### `sync/sync.proto` (source: `sync.proto`)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `CommitMessage` | `entries` | 1 | repeated `SyncEntity` |
| `CommitMessage` | `cache_guid` | 2 | optional `string` |
| `GetUpdatesMessage` | `caller_info` | 2 | optional `GetUpdatesCallerInfo` |
| `GetUpdatesMessage` | `fetch_folders` | 3 | optional `bool` [default = true] |
| `GetUpdatesMessage` | `from_progress_marker` | 6 | repeated `DataTypeProgressMarker` |
| `GetUpdatesMessage` | `get_updates_origin` | 9 | optional `SyncEnums.GetUpdatesOrigin` |
| `ClientStatus` | `is_sync_feature_enabled` | 2 | optional `bool` |
| `ClientToServerMessage` | `share` | 1 | **required** `string` |
| `ClientToServerMessage` | `protocol_version` | 2 | optional `int32` [default = 99] |
| `ClientToServerMessage` | `message_contents` | 3 | **required** `Contents` |
| `ClientToServerMessage` | `commit` | 4 | optional `CommitMessage` |
| `ClientToServerMessage` | `get_updates` | 5 | optional `GetUpdatesMessage` |
| `ClientToServerMessage` | `store_birthday` | 7 | optional `string` |
| `ClientToServerMessage` | `client_status` | 13 | optional `ClientStatus` |
| `ClientToServerMessage.Contents` | `COMMIT` / `GET_UPDATES` / `DEPRECATED_3` / `DEPRECATED_4` / `CLEAR_SERVER_DATA` | 1 / 2 / 3 / 4 / 5 | enum |
| `CommitResponse.ResponseType` | `SUCCESS` / `CONFLICT` / `RETRY` / `INVALID_MESSAGE` / `OVER_QUOTA` / `TRANSIENT_ERROR` | 1 / 2 / 3 / 4 / 5 / 6 | enum |
| `CommitResponse` | `EntryResponse` | 1 | repeated **group** |
| `CommitResponse.EntryResponse` | `response_type` | 2 | optional `ResponseType` |
| `CommitResponse.EntryResponse` | `id_string` | 3 | optional `string` |
| `CommitResponse.EntryResponse` | `version` | 6 | optional `int64` |
| `CommitResponse.EntryResponse` | `error_message` | 9 | optional `string` |
| `CommitResponse.EntryResponse` | `mtime` | 10 | optional `int64` [deprecated] |
| `GetUpdatesResponse` | `entries` | 1 | repeated `SyncEntity` |
| `GetUpdatesResponse` | `changes_remaining` | 4 | optional `int64` |
| `GetUpdatesResponse` | `new_progress_marker` | 5 | repeated `DataTypeProgressMarker` |
| `ClientToServerResponse` | `commit` | 1 | optional `CommitResponse` |
| `ClientToServerResponse` | `get_updates` | 2 | optional `GetUpdatesResponse` |
| `ClientToServerResponse` | `error_code` | 4 | optional `SyncEnums.ErrorType` [default = UNKNOWN] |
| `ClientToServerResponse` | `error_message` | 5 | optional `string` |
| `ClientToServerResponse` | `store_birthday` | 6 | optional `string` |
| `ClientToServerResponse` | `error` | 13 | optional `Error` |
| `ClientToServerResponse.Error` | `error_type` | 1 | optional `SyncEnums.ErrorType` [default = UNKNOWN] |
| `ClientToServerResponse.Error` | `error_description` | 2 | optional `string` |
| `ClientToServerResponse.Error` | `action` | 4 | optional `SyncEnums.Action` [default = UNKNOWN_ACTION] |
| `ClientToServerResponse.Error` | `error_data_type_ids` | 5 | repeated `int32` |

### `sync/sync_entity.proto` (source: `sync_entity.proto`)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `SyncEntity` | `id_string` | 1 | optional `string` |
| `SyncEntity` | `parent_id_string` | 2 | optional `string` |
| `SyncEntity` | `version` | 4 | optional `int64` |
| `SyncEntity` | `mtime` | 5 | optional `int64` |
| `SyncEntity` | `ctime` | 6 | optional `int64` |
| `SyncEntity` | `name` | 7 | optional `string` |
| `SyncEntity` | `non_unique_name` | 8 | optional `string` |
| `SyncEntity` | `server_defined_unique_tag` | 10 | optional `string` |
| `SyncEntity` | `deleted` | 18 | optional `bool` [default = false] |
| `SyncEntity` | `originator_cache_guid` | 19 | optional `string` |
| `SyncEntity` | `originator_client_item_id` | 20 | optional `string` |
| `SyncEntity` | `specifics` | 21 | optional `EntitySpecifics` |
| `SyncEntity` | `folder` | 22 | optional `bool` [default = false] |
| `SyncEntity` | `client_tag_hash` | 23 | optional `string` |

`non_unique_name` (8), `server_defined_unique_tag` (10) and `folder` (22) are beyond the
minimum the brief listed; they are kept because the sync-service `toSyncEntity` populates all
three on every GetUpdates entry.

### `sync/entity_specifics.proto` (source: `entity_specifics.proto`)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `EntitySpecifics` | `encrypted` | 1 | optional `EncryptedData` |
| `EntitySpecifics` | `phi` | **2000** | optional `PhiSpecifics` |

`phi` is a standalone field upstream, deliberately **not** inside the `specifics_variant`
oneof, so the engine reads and writes it directly with no oneof switch. Field 2000 is also the
`data_type_id` used in `DataTypeProgressMarker`. `PhiEntityProtoTests` asserts the on-the-wire
tag bytes (`(2000 << 3) | 2 == 16002` → `0x82 0x7D`).

### `sync/phi_specifics.proto` (source: `phi_specifics.proto`, verbatim)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `PhiSpecifics` | `ciphertext` | 1 | optional `bytes` |

### `sync/encryption.proto` (source: `encryption.proto`, verbatim)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `EncryptedData` | `key_name` | 1 | optional `string` |
| `EncryptedData` | `blob` | 2 | optional `string` |

Kept only because `EntitySpecifics.encrypted` (field 1) references it. Phi data is **not**
Nigori-encrypted — it is AES-GCM sealed under the Phi domain key inside `PhiSpecifics` — so the
engine never populates `encrypted`.

### `sync/data_type_progress_marker.proto` (source: `data_type_progress_marker.proto`)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `DataTypeProgressMarker` | `data_type_id` | 1 | optional `int32` |
| `DataTypeProgressMarker` | `token` | 2 | optional `bytes` |
| `DataTypeProgressMarker` | `gc_directive` | 6 | optional `GarbageCollectionDirective` |
| `DataTypeContext` | `data_type_id` | 1 | optional `int32` |
| `DataTypeContext` | `context` | 2 | optional `bytes` |
| `DataTypeContext` | `version` | 3 | optional `int64` |
| `GarbageCollectionDirective` | `type` | 1 | optional `Type` [default = UNKNOWN, deprecated] |
| `GarbageCollectionDirective` | `version_watermark` | 2 | optional `int64` |
| `GarbageCollectionDirective.Type` | `UNKNOWN` / `VERSION_WATERMARK` / `DEPRECATED_AGE_WATERMARK` / `DEPRECATED_MAX_ITEM_COUNT` | 0 / 1 / 2 / 3 | enum |

### `sync/get_updates_caller_info.proto` (source: `get_updates_caller_info.proto`, verbatim)

| Message | Field | Number | Label + type |
| --- | --- | --- | --- |
| `GetUpdatesCallerInfo` | `notifications_enabled` | 2 | optional `bool` |

### `sync/sync_enums.proto` (source: `sync_enums.proto`)

Only three of `SyncEnums`' fourteen enums are kept; every value keeps its upstream number.

| Enum | Values (name = number) |
| --- | --- |
| `SyncEnums.ErrorType` | `SUCCESS`=0, `NOT_MY_BIRTHDAY`=2, `THROTTLED`=3, `TRANSIENT_ERROR`=8, `MIGRATION_DONE`=9, `DISABLED_BY_ADMIN`=10, `PARTIAL_FAILURE`=12, `CLIENT_DATA_OBSOLETE`=13, `ENCRYPTION_OBSOLETE`=14, `UNKNOWN`=100 |
| `SyncEnums.Action` | `UPGRADE_CLIENT`=0, `UNKNOWN_ACTION`=5 |
| `SyncEnums.GetUpdatesOrigin` | `UNKNOWN_ORIGIN`=0, `PERIODIC`=4, `NEWLY_SUPPORTED_DATATYPE`=7, `MIGRATION`=8, `NEW_CLIENT`=9, `RECONFIGURATION`=10, `GU_TRIGGER`=12, `PROGRAMMATIC`=14, `DEVICE_STATISTICS_METRICS`=15 (13 reserved, was `RETRY`) |

## `phi_entity.proto` (authored here)

| Message | Field | Number | Type |
| --- | --- | --- | --- |
| `PhiEntity` | `kind.setting` | 1 | `PhiSettingEntity` (oneof `kind`) |
| `PhiSettingEntity` | `values` | 1 | `map<string, PhiSettingValue>` |
| `PhiSettingValue` | `updated_at_ms` | 1 | `int64` |
| `PhiSettingValue` | `v.bool_value` | 2 | `bool` (oneof `v`) |
| `PhiSettingValue` | `v.string_value` | 3 | `string` (oneof `v`) |
| `PhiSettingValue` | `v.int_value` | 4 | `int64` (oneof `v`) |

## Keeping this in sync

If the server-side protos change (a new field on `PhiSpecifics`, a new `SyncEnums.ErrorType`,
…), copy the change here with the same number/type/label, re-run `generate.sh`, and update the
table above. Re-vendoring Chromium in sync-service does **not** automatically affect this
directory.
