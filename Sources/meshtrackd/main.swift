// meshtrackd — the headless, always-on collector (LaunchAgent target, SPEC §3).
//
// Phase 0 proved the composition root wires the real Clock adapter. It now also
// offers a `capture` mode that records a live broker into a golden corpus. The
// full 24/7 ingestion run (open store, attach transports, run the pipeline +
// rule engine, serve the app) is wired as the collector matures.

import Domain
import Transport

let clock: any Domain.Clock = SystemClock()
let arguments = CommandLine.arguments

if arguments.count >= 2, arguments[1] == "capture" {
    let seconds = arguments.dropFirst(2).first.flatMap { Double($0) } ?? 15
    let outputDir = arguments.dropFirst(3).first ?? "Corpus/capture"
    await Capture.run(seconds: seconds, outputDir: outputDir, clock: clock)
} else if arguments.count >= 3, arguments[1] == "replay" {
    await Replay.run(corpusDir: arguments[2], clock: clock)
} else {
    print("meshtrackd — Meshtastic fleet collector")
    print("composition root online; clock now (ns since epoch): \(clock.now().nanosecondsSinceEpoch)")
    print(
        "usage: meshtrackd capture <seconds> <outdir>   (env: MESHTRACK_MQTT_HOST/PORT/USER/PASS/TLS/TOPIC)"
    )
}
