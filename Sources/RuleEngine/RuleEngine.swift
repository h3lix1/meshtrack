// RuleEngine — typed, data-driven alert rules + config hierarchy + evaluation
// (SPEC §2.6). The alert state machine (firing → acknowledged → resolved, with
// cooldown / snooze / ack and storm suppression on reconnect) wraps the pure
// evaluation.
//
//   • Rules.swift         — AlertType, RuleScope, AlertRule, RuleSet (hierarchy).
//   • RuleEvaluator.swift — pure liveness / battery / voltage condition evaluation.
