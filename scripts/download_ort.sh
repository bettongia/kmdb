#!/usr/bin/env bash
# Copyright 2026 The Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Downloads the ONNX Runtime shared library for the given version and platform
# into the local cache at packages/kmdb_inferencing/assets/native/{platform}/.
# Skips the download if the file is already present (idempotent).
#
# Usage: download_ort.sh <version> <ort-platform>
#   version      ORT release version, e.g. 1.22.0
#   ort-platform ORT archive platform string, e.g. osx-arm64 or linux-x64

set -euo pipefail

VERSION="${1:?Usage: download_ort.sh <version> <ort-platform>}"
PLATFORM="${2:?Usage: download_ort.sh <version> <ort-platform>}"

case "$(uname -s)" in
  Darwin) LIB_NAME="libonnxruntime.${VERSION}.dylib" ;;
  Linux)  LIB_NAME="libonnxruntime.so.${VERSION}" ;;
  *)
    echo "ERROR: Unsupported OS: $(uname -s)" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CACHE_DIR="${REPO_ROOT}/packages/kmdb_inferencing/assets/native/${PLATFORM}"
CACHE_FILE="${CACHE_DIR}/${LIB_NAME}"

if [ -f "${CACHE_FILE}" ]; then
  echo "ORT ${VERSION} for ${PLATFORM} already cached — skipping download." >&2
  exit 0
fi

URL="https://github.com/microsoft/onnxruntime/releases/download/v${VERSION}/onnxruntime-${PLATFORM}-${VERSION}.tgz"

TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

echo "Downloading ONNX Runtime ${VERSION} for ${PLATFORM}..." >&2
curl -fSL --progress-bar "${URL}" -o "${TMP_FILE}"

mkdir -p "${CACHE_DIR}"

echo "Extracting ${LIB_NAME}..." >&2
# Strip 2 path components (archive-dir/lib/) so the dylib lands directly in CACHE_DIR.
tar -xzf "${TMP_FILE}" \
  --strip-components=2 \
  -C "${CACHE_DIR}" \
  "onnxruntime-${PLATFORM}-${VERSION}/lib/${LIB_NAME}"

echo "Cached at ${CACHE_FILE}" >&2
