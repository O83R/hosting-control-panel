# HCP Domain Boundaries

Phase 01 keeps the current production application intact while establishing boundaries for new code.

## Core control-plane domains

```text
identity
  users, memberships, RBAC, MFA, sessions

platform
  tenants, nodes, node capabilities, resource identity

jobs
  durable operations, steps, events, idempotency, locks, receipts

hosting
  accounts, packages, sites, deployments

networking
  domains, DNS, reverse-proxy routes, certificates

databases
  database servers, databases, users, grants

backups
  policies, runs, artifacts, verification, restore rehearsals

governance
  audit, approvals, notifications

adapters
  node agent, proxy, DNS provider, ACME, database engines, object storage
```

## Dependency rule

Domain packages must not depend on HTTP handlers, HTML/UI code, Docker CLI details, or production filesystem paths.

Infrastructure adapters may depend on domain contracts. Domain packages must not import infrastructure adapters.

## Migration rule

The current `main.go` remains the stable legacy composition root until behavior is covered by tests and moved slice-by-slice. Phase 01 does not perform a broad rewrite.
