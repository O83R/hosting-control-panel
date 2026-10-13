# ADR-005: Identity and Tenant Isolation

- Status: Accepted
- Phase: 02

## Decision

HCP separates platform-level identities and roles from tenant-scoped memberships and role assignments.

Tenant isolation is enforced in more than one layer:

1. domain validation;
2. relational constraints and assignment triggers;
3. PostgreSQL row-level security for tenant-scoped reads/writes;
4. application authorization before database access.

## Scope rules

Platform roles have no tenant identifier.

Tenant roles require an active membership in exactly the tenant of the assignment.

A tenant request context fails closed if the tenant identifier is absent.

## MFA

MFA factors are modeled as metadata and external credential references. Raw MFA secrets must not be stored in ordinary application columns or committed to source control.

## Production migration

The existing SQLite authentication runtime remains unchanged in Phase 02. PostgreSQL identity tables are additive and CI-only until a separately approved migration/wiring step.
