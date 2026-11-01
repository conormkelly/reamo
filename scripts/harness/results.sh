# What a harness run keeps of each scenario. Sourced by run.sh and
# windows/run.sh, which set ROOT, OUT (the run's scratch dir) and ARTIFACTS.
#
#   out/<scenario>/            the latest run: output.log (the scenario's
#                              console output), reamo.log, screenshots
#   out/failures/<when>-<os>-reaper<version>-<scenario>/
#                              a copy of each failed run that later runs
#                              leave alone, with replay.txt (how to run it
#                              again, and the code it ran) and, if the
#                              working tree had changes, worktree.diff

kept_failures=()

# The code this run builds, recorded as it starts: the tree can change
# while a long run goes on.
record_tree() {
    git -C "$ROOT" rev-parse HEAD >"$OUT/tree-commit"
    git -C "$ROOT" status --porcelain >"$OUT/tree-status"
    git -C "$ROOT" diff HEAD >"$OUT/tree.diff"
}

# keep_output <artifact dir> <log>: the scenario's console output, beside
# the log and screenshots it left.
keep_output() {
    mkdir -p "$1"
    cp "$2" "$1/output.log"
}

# keep_failure <artifact dir> <scenario> <os> <reaper version>
keep_failure() {
    local src="$1" scenario="$2" os="$3" reaper="$4"
    local dest
    dest="$ARTIFACTS/failures/$(date -u +%Y%m%dT%H%M%SZ)-$os-reaper$reaper-$(basename "$src")"
    mkdir -p "$dest"
    cp -R "$src/." "$dest/"
    {
        echo "scenario: $scenario"
        echo "os: $os"
        echo "reaper: $reaper"
        echo "failed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "commit: $(cat "$OUT/tree-commit")"
        if [ -s "$OUT/tree-status" ]; then
            echo "working tree: changed (tracked changes in worktree.diff; untracked files are listed with ??)"
            sed 's/^/  /' "$OUT/tree-status"
        else
            echo "working tree: clean"
        fi
        echo
        echo "run it again:"
        # A soak's length and load are in its SOAK_* settings. %q quotes
        # each value so the line pastes back into a shell as it ran.
        local env_prefix="" v
        for v in TOUR_ONLY $(compgen -e | grep '^SOAK_' || true); do
            [ -n "${!v:-}" ] && env_prefix+="$(printf '%s=%q ' "$v" "${!v}")"
        done
        echo "  ${env_prefix}scripts/harness/run.sh --os $os --reaper $reaper $scenario"
    } >"$dest/replay.txt"
    [ ! -s "$OUT/tree.diff" ] || cp "$OUT/tree.diff" "$dest/worktree.diff"
    kept_failures+=("$dest")
}

# Where each failure was kept, for the end of the run's output.
print_kept_failures() {
    [ ${#kept_failures[@]} -gt 0 ] || return 0
    echo "failed runs kept (output.log, reamo.log, screenshots, replay.txt):"
    printf '  %s\n' "${kept_failures[@]}"
}
