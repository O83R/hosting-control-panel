# Phase 01 — Platform Foundation

## Purpose

Phase 01 introduces the first durable platform primitives without changing the current production runtime.

The existing panel remains operational with its SQLite auth/audit stores and read-only host snapshot. The new foundation is additive and is exercised only by CI until a later, separately approved migration phase.

## Decisions

### Modular monolith first

The control plane will evolve incrementally from the current single Go package. New platform concepts are introduced in `internal/*` packages while existing stable behavior remains unchanged until each slice is covered by tests and verification.

### PostgreSQL is the future platform system of record

A separate PostgreSQL schema named `hcp` is introduced for platform state. It is not a customer database and it is not connected to any current production application database.

The first migration establishes:

- tenants;
- nodes;
- node capabilities;
- jobs;
- job steps;
- job events;
- resource locks;
- schema migration receipts.

### Jobs are durable and idempotent

Long-running control-plane writes will be represented by durable jobs. The initial state machine is:

```text
queued -> running -> succeeded
      \-> cancelled
running -> failed
running -> cancelled
```

Terminal states are immutable.

### Node operations remain capability-driven

The future Node Agent protocol will expose typed capabilities rather than arbitrary shell execution. The platform schema models observed capabilities separately from the node record.

## Current production impact

None.

This phase does not:

- connect the application to PostgreSQL;
- change the production SQLite stores;
- restart any production service;
- alter the production Action Agent;
- enable production restore;
- provision customer resources.

## CI verification

`scripts/verify-platform-db.sh` starts an isolated PostgreSQL 16 container and performs:

1. migration up;
2. schema and table assertions;
3. representative inserts;
4. constraint checks;
5. migration down;
6. clean re-apply;
7. machine-readable verification receipt.

This is intentionally isolated from production.
