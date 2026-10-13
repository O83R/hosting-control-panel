# ADR-002: Modular Monolith Before Microservices

- Status: Accepted
- Phase: 01

## Decision

The control plane evolves as a modular Go monolith with explicit internal package boundaries.

## Consequences

- New bounded contexts are introduced under `internal/`.
- Existing stable behavior is moved only when covered by tests and verification.
- Interfaces are used at domain boundaries where replacement or external adapters are expected.
- Independent services may be extracted later when operational evidence justifies them.
