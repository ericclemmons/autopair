# ADR 0003: Finish device release before closed-lid sleep

## Status

Accepted

## Context

Removing a dock from a closed-lid Mac simultaneously removes the ownership trigger,
network, external display, and clamshell power condition. The original proactive
release queued Bluetooth work but did not delay system sleep, so macOS could suspend
the process before the pairing was removed.

## Decision

- Register for macOS system-power notifications with `IORegisterForSystemPower`.
- On `SystemWillSleep`, give hardware-detach events 500 ms to settle, then delay the
  required acknowledgement while selected devices are released, with a 12-second
  failsafe that always allows sleep. Display removal can arrive only after wake, so an
  active trigger does not by itself prove this Mac should retain ownership.
- Retain devices only while acquisition is in progress or for 10 seconds after a
  successful acquisition. This covers the destination's transient clamshell/login
  sleep notification without letting a stable source sleep while holding the devices.
- Keep hardware-detach release as the earliest path.
- Retry acquisition on the destination after 2, 5, 10, and 15 seconds.
- Persist a small rolling diagnostics timeline and expose it through **Copy Diagnostics**.
- Debounce hardware removal for 750 ms so transient dock re-enumeration does not publish
  ownership loss; the raw IOKit state remains available to the sleep path immediately.
- Treat repeated ownership values as idempotent and cooperatively cancel stale native
  Bluetooth work when ownership truly changes.
- Refuse peer release requests while the local physical ownership trigger is active.
- Reconcile current ownership after system wake.
- Determine pairing success by polling macOS's paired/connected state after starting
  native pairing; delegate completion is unreliable across clamshell wake transitions.

## Consequences

Closed-lid cable moves get a final release opportunity even when display or hardware
detach notification loses the race. Sleep can be delayed by up to 12 seconds during a handoff.
The destination may keep attempting Bluetooth acquisition for longer before reporting
failure. The actual two-Mac clamshell transition remains a hardware-in-the-loop test.
