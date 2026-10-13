# ADR-008: Sites and Safe Adoption

- Status: Accepted
- Phase: 05

## Decision

A site is a tenant-owned resource under a hosting account. Existing workloads are brought into HCP through an explicit adoption workflow rather than silently becoming managed resources.

## Site model

A site records:

- tenant and hosting account;
- optional assigned node;
- stable site key;
- runtime kind;
- managed or adopted origin;
- desired and observed state;
- lifecycle status and optimistic version.

Package `max_sites` is enforced at the database boundary.

## Adoption model

Read-only discovery creates an adoption candidate. Candidate states are:

```text
detected -> reviewed -> adopted
        \-> rejected
reviewed \-> rejected
```

Adoption records an HCP site but does not, by itself, mutate the discovered workload.

## Safety

Existing production projects are not modified or adopted automatically. A later phase may connect readonly discovery output to these candidates, but any actual production mutation remains behind durable jobs, typed agent capabilities and explicit release approval.
