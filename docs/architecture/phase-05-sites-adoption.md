# Phase 05 — Sites & Existing Application Adoption

## Objective

Introduce the site resource and a safe path for bringing existing applications under HCP control.

## Site hierarchy

```text
Tenant
  -> Hosting Account
      -> Site
```

A site may later own domains, proxy routes, certificates, databases and deployments.

## Supported runtime kinds

The first schema distinguishes:

- containerized;
- static;
- external.

This is classification only. Phase 05 does not start, stop, rebuild or deploy any workload.

## Adoption

Discovery and adoption are separate operations:

1. discover existing workload read-only;
2. create/update an adoption candidate;
3. review the candidate;
4. create an adopted site record;
5. mark the candidate adopted.

This preserves a visible boundary between observed production state and HCP desired state.

## Production impact

None. Existing production projects remain unchanged. No collector, Action Agent, Node Agent or project configuration is modified by this phase.
