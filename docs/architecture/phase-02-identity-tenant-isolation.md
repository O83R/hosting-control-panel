# Phase 02 — Identity & Tenant Isolation

## Objective

Establish the future multi-tenant identity model without disrupting the current production authentication system.

## Foundation

Phase 02 introduces:

- platform users;
- tenant memberships;
- platform and tenant role definitions;
- permission definitions;
- role-permission mappings;
- scoped role assignments;
- MFA factor metadata;
- tenant-aware row-level security.

## Built-in roles

Platform:

- platform_owner
- platform_admin
- security_admin
- node_operator
- auditor

Tenant:

- tenant_owner
- tenant_admin
- tenant_operator
- tenant_viewer

## Isolation model

The control plane sets a request scope and, for tenant operations, a tenant ID on the database transaction.

Tenant-scoped policies expose only rows belonging to that tenant. Missing tenant context returns no tenant rows.

Database RLS is a defense-in-depth boundary; it does not replace application authorization.

## Existing runtime

The current production panel continues using the existing SQLite users/sessions/project assignments during this phase. No automatic user migration occurs.
