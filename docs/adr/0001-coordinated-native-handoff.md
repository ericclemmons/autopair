# ADR 0001: Coordinated native Bluetooth handoff

## Status

Accepted

## Context

The original implementation let each Mac react independently to display transitions.
It used `blueutil` to unpair/pair, power-cycled the entire Bluetooth controller, and
did not know whether the other Mac had completed release. Apple Magic peripherals
frequently invalidated or retained bond state across that race.

## Decision

- The Mac whose selected ownership trigger becomes active initiates handoff.
- A Mac whose trigger becomes inactive proactively releases before dock removal can
  put a closed-lid Mac to sleep or remove its network connection.
- AutoPair instances discover each other through Bonjour on the local network.
- The destination sends a best-effort release request, then always waits for a
  bounded Bluetooth settling interval before acquiring locally. Acknowledgment is
  diagnostic information, not a gate: an unavailable peer cannot prevent handoff.
- Bluetooth mutation uses IOBluetooth directly on one serial queue.
- Acquisition tries a valid existing bond, removes a stale bond, then uses a retained
  `IOBluetoothDevicePair` delegate. Pairing succeeds only after the delegate reports
  success and the paired connection remains stable for a short interval.
- Physical ownership signals conform to `OwnershipTrigger` and do not own Bluetooth
  or network behavior.

## Consequences

Two-Mac handoff requires both apps and local-network permission. Releasing a pairing
still uses IOBluetooth's undocumented `remove` selector, so direct distribution is
required and future macOS releases may require maintenance. Trigger implementations
and the handoff state machine can be tested without Bluetooth hardware.
