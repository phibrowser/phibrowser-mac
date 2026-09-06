#!/bin/bash
# Regenerates the Swift protobuf sources under Sources/Sync/Phi/Proto/Generated/.
# Run from the repository root:  ./Sources/Sync/Phi/Proto/generate.sh
#
# Requirements (macOS):
#   brew install protobuf swift-protobuf
# Pinned toolchain (must match, or the generated files will drift):
#   protoc            36.1
#   protoc-gen-swift  1.38.1   <- must equal the SwiftProtobuf version pinned in
#                                 PackageCollection/Package.swift
#
# The sync_pb/*.proto files here are TRIMMED, wire-compatible copies of
# Chromium 150.0.7871.47's components/sync/protocol/*.proto (vendored in the
# sync-service repo, branch feature/m3-phi-sync). See README.md.
#
# Idempotent: running it twice produces no diff.

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${PROTO_DIR}/Generated"

REQUIRED_PROTOC_VERSION="36.1"
REQUIRED_PLUGIN_VERSION="1.38.1"

check_version() {
  local tool="$1" expected="$2" actual="$3"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "warning: ${tool} is ${actual}, expected ${expected}; generated files may drift" >&2
  fi
}

check_version protoc "${REQUIRED_PROTOC_VERSION}" "$(protoc --version | awk '{print $2}')"
check_version protoc-gen-swift "${REQUIRED_PLUGIN_VERSION}" "$(protoc-gen-swift --version | awk '{print $2}')"

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

# 1. The phi payload schema (proto3, package `phi` -> Phi_* Swift types).
protoc \
  --proto_path="${PROTO_DIR}" \
  --swift_out="${OUT_DIR}" \
  --swift_opt=Visibility=Internal \
  phi_entity.proto

# 2. The trimmed Chromium sync protocol (proto2, package `sync_pb` -> SyncPb_*).
protoc \
  --proto_path="${PROTO_DIR}/sync" \
  --swift_out="${OUT_DIR}" \
  --swift_opt=Visibility=Internal \
  data_type_progress_marker.proto \
  encryption.proto \
  entity_specifics.proto \
  get_updates_caller_info.proto \
  phi_specifics.proto \
  sync.proto \
  sync_entity.proto \
  sync_enums.proto

echo "generated $(ls -1 "${OUT_DIR}" | wc -l | tr -d ' ') files into ${OUT_DIR}"
