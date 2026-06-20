#!/usr/bin/env bash
# Ralph loop driver.
#
# Each iteration is a FRESH-CONTEXT agent that: reads SPEC.md / IMPLEMENTATION_PLAN.md
# / AGENTS.md / progress.txt / recent git log, picks EXACTLY ONE unchecked task,
# implements it and its tests, runs `make verify`, and commits on green (checking
# the box + appending to progress.txt). Persistent memory = git history +
# progress.txt + plan checkboxes; the agent never trusts its own "done".
#
# Usage:   ./scripts/loop.sh [max_iterations]
# Env:
#   AGENT_CMD  command that runs ONE fresh-context iteration.
#              Default uses the Claude Code CLI in headless mode; override to use
#              any agent runner. The command must operate on this working tree.
#   STUCK_N    consecutive no-progress iterations before escalating (default 3).
set -euo pipefail
cd "$(dirname "$0")/.."

MAX_ITERS="${1:-50}"
STUCK_N="${STUCK_N:-3}"
PROMPT_FILE="scripts/iteration-prompt.md"
AGENT_CMD="${AGENT_CMD:-claude -p --permission-mode acceptEdits \"\$(cat $PROMPT_FILE)\"}"

stuck=0
for ((i = 1; i <= MAX_ITERS; i++)); do
    echo "════════════════ iteration $i / $MAX_ITERS ════════════════"

    if ! grep -qE '^[[:space:]]*-[[:space:]]*\[ \]' IMPLEMENTATION_PLAN.md; then
        echo "🎉 IMPLEMENTATION_PLAN.md has no unchecked tasks — nothing to do."
        exit 0
    fi

    before="$(git rev-parse HEAD 2>/dev/null || echo none)"

    # One fresh-context iteration. The agent is responsible for running
    # `make verify` and committing only on green.
    set +e
    eval "$AGENT_CMD"
    agent_rc=$?
    set -e

    after="$(git rev-parse HEAD 2>/dev/null || echo none)"

    if [[ "$after" != "$before" ]]; then
        echo "✓ iteration $i committed ($before → $after)"
        stuck=0
    else
        stuck=$((stuck + 1))
        echo "⚠️  iteration $i made no commit (agent rc=$agent_rc); stuck=$stuck/$STUCK_N"
    fi

    # Stuck-detector: escalate to a human after STUCK_N no-progress iterations.
    if ((stuck >= STUCK_N)); then
        echo "🛑 STUCK: $STUCK_N iterations without progress. Escalating to a human."
        echo "    --- last 'make verify' output ---"
        make verify 2>&1 | tail -50 || true
        exit 2
    fi
done

echo "Reached max iterations ($MAX_ITERS)."
