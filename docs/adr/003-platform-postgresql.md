# ADR-003: Separate PostgreSQL Platform State

- Status: Accepted
- Phase: 01

## Decision

Future HCP platform state is stored in a dedicated PostgreSQL database/schema separate from customer databases and from the existing SQLite auth/audit runtime.

## Consequences

- CI rehearses migrations in isolated PostgreSQL containers.
- Production remains disconnected until an explicitly approved integration phase.
- Platform migrations are versioned and reversible.
- Customer database credentials and lifecycle remain separate resources.
- PostgreSQL becomes the durable basis for tenants, nodes, jobs, hosting resources and reconciliation.
