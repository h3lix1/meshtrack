# ADR 0008 — Node ownership: "mine" & managed vs unmanaged

- Status: accepted
- Date: 2026-06-20

## Context
A fleet monitor sees every node on the public mesh, not just the operator's. Running
battery/silence rules against strangers' nodes produces a flood of false alerts (we
don't own their batteries and can't act on them). Operators also want to focus views
on their own nodes. We need to separate *visibility* from *alerting eligibility*
without complicating the existing node → class → global config hierarchy (SPEC §2.6).

## Decision
Two independent boolean flags on `node` (migration v3, default false):
- **`is_mine`** — part of the operator's fleet. Drives the **"My Nodes"** filter
  across all views. Affects visibility only.
- **`is_managed`** — we administer the node (own its battery / hold an admin key).
  **Ownership-sensitive rules — `battery_below`, `voltage_below`, `stale` — evaluate
  only when `is_managed`.** Unmanaged nodes are observed read-only: visible, charted,
  traced, but never battery/silence-alerted. Movement/geofence and `new_node_seen`
  remain global.

`RuleEvaluator` gains a `management`-aware gate that skips ownership-sensitive rule
types for unmanaged nodes; the config hierarchy is otherwise untouched. Flags are
user-settable singly or in bulk; `is_managed` may be inferred when we successfully
admin a node.

## Consequences
- No false battery/stale alerts for nodes we don't run — proven by a RuleEngine test
  (unmanaged + low battery → no alert; managed + low battery → exactly one).
- Visibility and alerting are orthogonal: a node can be "mine" but unmanaged
  (e.g. a neighbour's I track) or managed but filtered out of a focused view.
- The flags are descriptive metadata; they never alter ingestion or dedup.
