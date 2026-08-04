#!/usr/bin/env bash

set -euo pipefail

readonly BAZELRC="${BAZELRC:-/home/devbox/.bazelrc}"
readonly TARGET='@rules_angular//src/worker:worker_vanilla_ts'

echo "Fetching $TARGET..."
bazelisk --bazelrc="$BAZELRC" fetch "$TARGET"

targetLocation="$(bazelisk --bazelrc="$BAZELRC" query --output=location "$TARGET")"
buildFile="${targetLocation%%:*}"
workerSrc="$(dirname "$buildFile")/worker.mts"

if [[ ! -f "$workerSrc" ]]; then
  echo "ERROR: Could not locate rules_angular worker source: $workerSrc" >&2
  exit 1
fi

echo "Checking: $workerSrc"

namespaceCheck="process.cwd().startsWith('/var/lib/namespace-bazel/')"
original="const isRemoteExecution = process.cwd().startsWith('/b/f/w/');"
replacement="const isRemoteExecution = process.cwd().startsWith('/b/f/w/') || process.cwd().startsWith('/var/lib/namespace-bazel/');"

if grep -Fq "$namespaceCheck" "$workerSrc"; then
  echo "Already patched."
  exit 0
fi

occurrences="$(grep -Fc "$original" "$workerSrc" || true)"
if [[ "$occurrences" != "1" ]]; then
  echo "ERROR: Expected one known sandbox check, found $occurrences." >&2
  echo "rules_angular may have changed; inspect $workerSrc" >&2
  exit 1
fi

sed -i "s#$original#$replacement#" "$workerSrc"

grep -nF "$namespaceCheck" "$workerSrc"
echo "Patched rules_angular for Namespace RBE."
