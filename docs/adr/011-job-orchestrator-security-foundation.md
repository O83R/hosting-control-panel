# ADR-011: Job Orchestrator Safe Foundation

- Status: Proposed — Phase 08 first slice
- Date: 2026-10-14

## Decision

Phase 08 starts with a fail-closed tenant isolation contract for existing job tables and deterministic, **non-executing** typed intents. It does not deploy a worker and does not authorize DNS, SSL, proxy or production actions.

The only accepted job kind in `internal/jobs` is `agent.ping`, with an empty object input, tenant scope, actor, node resource and idempotency key. Any unknown or mutating action fails closed.

The intent hash includes tenant, actor, action, target resource and normalized input; it excludes the idempotency key. Reused keys with different intents are rejected by the domain contract. The PostgreSQL uniqueness constraints remain responsible for actual concurrent uniqueness when enqueue is implemented.

## Database boundaries

`hcp.jobs`, `hcp.job_steps`, `hcp.job_events`, and `hcp.resource_locks` receive FORCE RLS. The tenant policy requires `hcp.scope = 'tenant'` plus matching `hcp.tenant_id`; child visibility depends on the parent job. An untrusted `hcp.scope = 'platform'` value is not a bypass for these tables.

Only trusted application components should set request context; PostgreSQL custom GUCs are not themselves authentication. Customer logins must not receive direct PostgreSQL credentials. A separate trusted worker DB identity and scoped read/write entrypoints must be reviewed before production job execution. This migration intentionally does not grant those privileges.

## Non-goals

No background worker, durable claim/heartbeat, retry engine, real provider call, shell command, Docker socket, public listener, production migration, production restore or service restart is introduced in this slice.

## Follow-up requirements

Before production job execution, independently implement and verify:
- atomic enqueue with canonical intent fingerprint and idempotency conflict;
- authenticated tenant/RBAC and approval checks;
- leased claims with resource locks and fencing tokens;
- crash recovery, bounded retry and execution receipts;
- restricted executor allowlist and action-specific rollback/compensation;
- worker DB role with audited, least-privilege storage access.

Until those gates pass, all orchestration remains disabled.
