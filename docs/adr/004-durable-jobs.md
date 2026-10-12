# ADR-004: Durable Idempotent Jobs

- Status: Accepted
- Phase: 01

## Decision

Long-running or mutating control-plane operations are durable jobs with explicit state transitions, idempotency keys, steps, events and resource locks.

## State machine

```text
queued -> running -> succeeded
queued -> cancelled
running -> failed
running -> cancelled
```

Terminal states are immutable.

## Consequences

- Tenant-scoped and system-scoped jobs both enforce idempotency.
- Resource locks prevent conflicting concurrent operations.
- Job transitions are enforced in domain code and PostgreSQL.
- Receipts and events are first-class operational evidence.
