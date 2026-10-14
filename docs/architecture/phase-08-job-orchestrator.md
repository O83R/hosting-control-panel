# Phase 08 — Durable Job Orchestrator (isolated foundation)

**Base:** `main@4aa4f3c00b526fabc366a57d9b934962794501b1`

## Implemented in the first development slice

- A strict `internal/jobs` intent contract restricted to read-only synthetic `agent.ping`.
- Deterministic fingerprint for conflicting idempotency-key replay detection.
- PostgreSQL migration 000008 adding an optional fingerprint field and tenant queue index.
- FORCE RLS for the four existing job tables, including inherited child visibility.
- Isolated PostgreSQL verifier with tenant isolation, forbidden writes, no-context and platform-GUC bypass negative tests.
- CI receipt and migration up/down/reapply rehearsal.

## Not implemented

A durable database queue/worker, provider adapter execution, lease renewal and recovery, scheduling, retries, approvals, deployment, or production integration are **not** present. Passing the current tests does not prove those capabilities.

## Security assessment

The migration deliberately refuses the generic `platform` context for normal job-table access. An ordinary application role is not allowed to see system jobs or other tenants' jobs using RLS. PostgreSQL tenant context is a trusted-application boundary, not an identity assertion. Never give customer-facing identities direct database access to set context.

## Next verified development slices

1. Authorized DB enqueue with atomic idempotency handling and serialized conflicting-intent checks.
2. Resource-aware claim/lease/fencing semantics with crash/restart simulation.
3. Audit-safe step transitions and immutable, redacted receipts.
4. Restricted synthetic worker and independent concurrency tests.

Each step requires isolated tests and approval before any merge or production release.

## Production boundary

No production database, host, Cloudflare account, ACME server, Nginx Proxy Manager instance, Docker socket, or VPS service is touched.
