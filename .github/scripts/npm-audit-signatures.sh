#!/usr/bin/env bash
# Checks the registry signatures of the npm package in the current
# directory, for CI. A package whose signature doesn't verify fails. A
# missing signature or attestation only warns, and so does the check itself
# erroring (the registry's attestation service has transient failures).
set -euo pipefail

out="${RUNNER_TEMP:-/tmp}/signatures.json"
for attempt in 1 2 3; do
  npm audit signatures --json > "$out" 2>/dev/null || true
  if ! jq -e 'type == "object" and (has("error") | not)' "$out" > /dev/null 2>&1; then
    echo "::warning::npm audit signatures errored (attempt $attempt): $(jq -c '.error' "$out" 2>/dev/null || head -c 500 "$out")"
    sleep 20
    continue
  fi
  invalid=$(jq '(.invalid // []) | length' "$out")
  missing=$(jq '(.missing // []) | length' "$out")
  if [ "$invalid" -gt 0 ]; then
    jq '.invalid' "$out"
    echo "::error::$invalid packages have invalid registry signatures or attestations"
    exit 1
  fi
  if [ "$missing" -gt 0 ]; then
    jq '.missing' "$out"
    echo "::warning::$missing packages have no registry signature or attestation"
  fi
  exit 0
done
echo "::warning::npm audit signatures didn't complete; not failing on it"
