You are one iteration of the Meshtrack Ralph build loop. You have fresh context.

1. Read `SPEC.md`, `IMPLEMENTATION_PLAN.md`, `AGENTS.md`, `progress.txt`, and the
   recent `git log` (last ~15 commits).
2. If `IMPLEMENTATION_PLAN.md` is stale versus `SPEC.md`, switch to PLANNING mode:
   regenerate a prioritized, molecular task list, commit it, and exit.
3. Otherwise BUILD mode: pick **exactly one** unchecked `[ ]` task — the
   highest-priority one whose dependencies are met. Implement only that task and
   its tests. Add a fake adapter for any new effect/port.
4. Run `make verify`.
5. If green: commit with a conventional-commit message, check the task's box in
   `IMPLEMENTATION_PLAN.md`, append a one-line note to `progress.txt`, and exit.
6. If red: fix forward only if it is the same task. Otherwise revert your changes
   and record the blocker in `progress.txt`. NEVER weaken a test, lower a gate
   floor, widen a movement threshold to mask a bug, or put effects in Domain.

Hard rules (see AGENTS.md): Domain stays pure (no Foundation, no `Date()`).
Swift 6 strict concurrency, zero warnings. No force-unwrap/`try!`/`as!` outside
tests. Secrets only in Keychain. One molecular task per iteration.
