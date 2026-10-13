# ADR-010: DNS and SSL Provider Adapters

- Status: Accepted
- Phase: 07

## Decision

DNS and certificate integrations are adapters behind typed control-plane contracts. Provider credentials are referenced through secret references and are never stored as raw token or key material in ordinary platform tables.

## DNS modes

Two initial provider modes are supported:

- Cloudflare managed mode: HCP may plan desired record mutations.
- External read-only mode: HCP records observed DNS state but cannot create, update or delete records.

The Cloudflare adapter in Phase 07 is a pure request planner. It does not perform outbound HTTP requests.

## SSL

The ACME adapter creates typed order intents for DNS-01 or HTTP-01 challenges. It does not contact an ACME server in Phase 07.

Certificate metadata stores references to certificate and private-key material, not raw private keys.

## Safety

Provider network execution, credentials, retries and real mutation are deferred to durable jobs plus approved runtime adapters. Phase 07 has zero provider network access and zero production mutation.
