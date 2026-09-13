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
- On `SystemWillSleep`, delay the required acknowledgement while the selected devices
  are released, with a 12-second failsafe that always allows sleep.
- Keep hardware-detach release as the earliest path.
- Retry acquisition on the destination after 2, 5, 10, and 15 seconds.
- Persist a small rolling diagnostics timeline and expose it through **Copy Diagnostics**.

## Consequences

Closed-lid cable moves get a final release opportunity even when the hardware-detach
callback loses the race. Sleep can be delayed by up to 12 seconds during a handoff.
The destination may keep attempting Bluetooth acquisition for longer before reporting
failure. The actual two-Mac clamshell transition remains a hardware-in-the-loop test.
