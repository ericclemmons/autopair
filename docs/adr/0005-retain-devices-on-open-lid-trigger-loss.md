# ADR 0005: Retain devices when an open-lid Mac loses its trigger

## Status

Accepted

## Context

Proactive release on trigger loss exists for the closed-lid dock move, where the
losing Mac is about to sleep and cannot answer a peer's release request. It also ran
when the lid was open and the Mac stayed awake. When no peer claimed the peripheral,
the Magic Trackpad sat unpaired, deep-slept, and stopped answering pages: every native
pairing attempt ended with HCI page timeout (result 4) until it was power-cycled, even
after the same Mac's trigger returned.

## Decision

- When the trigger becomes inactive while the built-in display is online (lid open),
  keep the bond and connection.
- Release on an authenticated peer request or on `SystemWillSleep`, as before.
- A closed-lid Mac (built-in display absent from the CoreGraphics online list) still
  releases immediately on trigger loss.

## Consequences

Re-attaching the trigger to the same Mac reuses the retained bond instead of pairing
an unreachable device. Handoff from an open-lid Mac now depends on that Mac staying
reachable over the local network or sleeping; if it loses all networking while awake,
the destination keeps retrying until it reconnects, sleeps, or the user releases it.
