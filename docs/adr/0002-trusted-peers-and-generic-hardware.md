# ADR 0002: Trusted peers and generic connected hardware

## Status

Accepted

## Context

Bonjour made coordination automatic but allowed any AutoPair instance on the LAN to
request release. The CalDigit trigger also encoded one vendor in the product model
even though IOKit exposes stable identities for arbitrary attached hardware.

## Decision

- Computers become mutually trusted through a six-digit, five-minute pairing code.
- Pairing proofs use HMAC; the resulting random 256-bit secret is encrypted with an
  AES-GCM key derived from the code and nonce before transport.
- Release messages require HMAC-SHA256 authentication, a fresh nonce, and a timestamp
  within 60 seconds. Only saved trusted computers are contacted or accepted.
- Attached USB and Thunderbolt devices are enumerated from IOKit and selected by the
  user. Matching prefers serial number, then vendor/product IDs, then names.
- The prior CalDigit trigger migrates to a vendor-level connected-hardware identity.

## Consequences

Both Macs must be upgraded and paired before coordinated requests work. Proactive
release on trigger removal remains available during migration and for the closed-lid
workflow. Six digits favor desk-side usability over resistance to offline exhaustive
search, so codes expire quickly and attempts are limited.
