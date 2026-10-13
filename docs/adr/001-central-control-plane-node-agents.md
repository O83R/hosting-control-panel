# ADR-001: Central Control Plane with Typed Node Agents

- Status: Accepted
- Phase: 01

## Decision

HCP uses a central control plane and node-local agents. Agents expose typed, versioned capabilities rather than arbitrary shell execution.

## Consequences

- The web UI never receives a generic root-shell primitive.
- Every mutating action is represented by a named action/capability with validated input.
- Jobs, audit, idempotency, preflight and verification surround risky actions.
- Node capability observation is stored independently from desired control-plane state.
- The existing restricted production Action Agent remains unchanged until a separately reviewed migration path exists.
