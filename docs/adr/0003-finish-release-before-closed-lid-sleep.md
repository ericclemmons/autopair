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
  sleep notification.
- For a stable owner with an active trigger, use the system power source to distinguish
  ordinary sleep from a dock cable move. Retain the pairing while external power remains;
  release before sleep when power is on battery or cannot be determined. This avoids
  forcing a sleeping Magic peripheral to advertise for a new pairing after an ordinary wake.
- Keep hardware-detach release as the earliest path.
- Retry acquisition on the destination after 2 and 5 seconds. If the burst fails while
  the physical ownership trigger remains active, start a fresh coordinated handoff after
  a 10-second cooldown; cancel that recovery immediately when ownership changes.
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
detach notification loses the race, while ordinary docked sleep retains the existing bond.
Sleep can be delayed by up to 12 seconds during a handoff.
The destination keeps attempting Bluetooth acquisition at a low frequency while its
trigger remains active, so waking a device after the first burst no longer requires a
manual retry. The actual two-Mac clamshell transition remains a hardware-in-the-loop test.
