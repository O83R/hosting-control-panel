# ADR-009: Domain Ownership and Proxy Route Contracts

- Status: Accepted
- Phase: 06

## Decision

Domains are globally unique control-plane resources attached to a tenant-owned site. Reverse-proxy routes are explicit resources attached to a domain.

A domain cannot become active until ownership verification is complete. A proxy route cannot become active unless both its domain and site are active and the domain remains verified.

## Domain quota

The hosting package `max_domains` limit is enforced across all non-disabled domains owned by the hosting account, even when the account contains multiple sites.

## DNS and SSL modes

Phase 06 records intent only:

- DNS: `external` or `managed`
- SSL: `off`, `automatic`, or `manual`

No DNS provider or ACME mutation is performed in this phase.

## Proxy target

The route stores a typed HTTP/HTTPS upstream host and port. It does not store arbitrary proxy configuration text.

## Production impact

None. No Nginx Proxy Manager, Cloudflare, certificate issuer, DNS record, firewall rule or production project is changed by Phase 06.
