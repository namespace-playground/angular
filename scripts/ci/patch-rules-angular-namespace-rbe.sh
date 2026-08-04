#!/usr/bin/env bash

set -euo pipefail

readonly BAZELRC="${BAZELRC:-/home/devbox/.bazelrc}"
readonly TARGET='@rules_angular//src/worker:worker_vanilla_ts'
readonly REMOTE_JS_RUN_BINARY_CONFIG='build --modify_execution_info=JsRunBinary=-no-remote-exec'

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
else
  occurrences="$(grep -Fc "$original" "$workerSrc" || true)"
  if [[ "$occurrences" != "1" ]]; then
    echo "ERROR: Expected one known sandbox check, found $occurrences." >&2
    echo "rules_angular may have changed; inspect $workerSrc" >&2
    exit 1
  fi

  sed -i "s#$original#$replacement#" "$workerSrc"

  grep -nF "$namespaceCheck" "$workerSrc"
  echo "Patched rules_angular for Namespace RBE."
fi

workspace="$(bazelisk --bazelrc="$BAZELRC" info workspace)"
userBazelrc="$workspace/.bazelrc.user"

if grep -Fxq "$REMOTE_JS_RUN_BINARY_CONFIG" "$userBazelrc" 2>/dev/null; then
  echo "Already configured: $userBazelrc"
else
  if [[ -s "$userBazelrc" ]]; then
    printf '\n' >> "$userBazelrc"
  fi
  printf '%s\n' "$REMOTE_JS_RUN_BINARY_CONFIG" >> "$userBazelrc"
  echo "Configured remote JsRunBinary execution in: $userBazelrc"
fi
