# ADR-007: Tenant-Owned Hosting Accounts and Packages

- Status: Accepted
- Phase: 04

## Decision

A hosting account is a tenant-owned control-plane resource with an explicit owner, package, lifecycle state and optional assigned node.

Packages are tenant-scoped quota profiles. An account may reference only a package from the same tenant.

## Isolation and ownership

- package codes are unique within a tenant;
- account keys are unique within a tenant;
- account owners must have an active membership in the account tenant;
- PostgreSQL row-level security applies to packages and accounts;
- missing tenant context fails closed.

## Lifecycle

```text
pending -> active -> suspended -> active
   \          \-> disabled
    \----------------> disabled
```

Disabled is terminal.

## Production impact

None. Phase 04 creates contracts and isolated CI migrations only. It does not provision operating-system users, containers, sites, databases, proxy routes or production resources.
