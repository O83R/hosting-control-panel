# Phase 08 — Durable Job Orchestrator (isolated foundation)

**Base:** `main@4aa4f3c00b526fabc366a57d9b934962794501b1`

## Implemented in the first development slice

- A strict `internal/jobs` intent contract restricted to read-only synthetic `agent.ping`.
- Deterministic fingerprint for conflicting idempotency-key replay detection.
- PostgreSQL migration 000008 adding an optional fingerprint field and tenant queue index.
- FORCE RLS for the four existing job tables, including inherited child visibility.
- Isolated PostgreSQL verifier with tenant isolation, forbidden writes, no-context and platform-GUC bypass negative tests.
- CI receipt and migration up/down/reapply rehearsal.

## Development slice 2 — Atomic enqueue (not deployed)

- Migration 000009 adds `hcp.enqueue_tenant_ping`, a SECURITY INVOKER
  PostgreSQL entrypoint accepting **only** synthetic `agent.ping`.
- Atomic `INSERT ... ON CONFLICT DO NOTHING` preserves one job per
  tenant/idempotency key, and checks fingerprint, requester and target
  for replay conflicts.
- The function is not executable by PUBLIC; a separately reviewed, trusted
  application DB role would need an explicit EXECUTE grant.
- The Go transaction adapter `EnqueueTenantPing` does not run agents.
- Isolated tests cover identical replay, changed-intent conflict, missing
  tenant, platform-GUC bypass, job-ID collision, eight concurrent requests
  for the same key, and migration rollback/reapply.

A trusted server must establish an authenticated tenant identity and DB
transaction scope before the adapter may be used. PostgreSQL custom GUC
values alone are **not** proof of user identity.

## Development slice 3 — Fenced resource leases (isolated)

- Migration `000010` extends the existing `hcp.resource_locks` rather
  than adding a conflicting source of truth.
- A persistent positive `fencing_token` increases at every expired/released
  lease takeover, including by another job of the same tenant. The job
  foreign key changes to `ON DELETE RESTRICT` to retain fence history.
- `claim_tenant_ping_lease` atomically claims a **queued, typed, synthetic**
  `agent.ping` job, acquires its resource fence and transitions it to
  `running`. A contending job remains queued.
- `renew_tenant_ping_lease` requires the current job, fence, non-expired
  lease and running state.
- `release_tenant_ping_lease` requires the matching fence, a still-active
  lease and an already-terminal job. It expires but never deletes the lock.
- `reconcile_expired_tenant_ping_lease` marks an expired, still-owned
  running job failed, with `LEASE_EXPIRED`. An expired holder is also
  marked failed transactionally during successful takeover.
- All lease functions are `SECURITY INVOKER`, default `PUBLIC` execution
  revoked. No deployment role grants, scheduling or network executor.
- The ephemeral PostgreSQL verifier simulates expiry without sleeping,
  checks cross-tenant denial and stale fences, and races two independent
  worker sessions against one resource.

**Fencing must be validated at the actual downstream side-effect boundary
before any future mutating job action is enabled.** This initial slice
contains no such downstream integration or external calls; it proves only
database metadata coordination.

## Not implemented

A deployed worker, provider adapter execution, scheduling, bounded retries, approvals, deployment, or production integration are **not** present. Passing the current tests does not prove those capabilities.

## Security assessment

The migration deliberately refuses the generic `platform` context for normal job-table access. An ordinary application role is not allowed to see system jobs or other tenants' jobs using RLS. PostgreSQL tenant context is a trusted-application boundary, not an identity assertion. Never give customer-facing identities direct database access to set context.

## Next verified development slices

1. Review the trusted DB principal/authenticated tenant context (enqueue entrypoint has no production grant).
2. Independently review claim/lease fencing semantics and crash recovery under load.
3. Audit-safe step transitions and immutable, redacted receipts.
4. Restricted synthetic worker and independent concurrency tests.

Each step requires isolated tests and approval before any merge or production release.

## Production boundary

No production database, host, Cloudflare account, ACME server, Nginx Proxy Manager instance, Docker socket, or VPS service is touched.
