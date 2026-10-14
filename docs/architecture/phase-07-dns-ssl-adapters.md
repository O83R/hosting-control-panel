# Phase 07 — DNS & SSL Provider Adapters

## Objective

Introduce provider-neutral DNS and certificate resources plus safe adapter boundaries before any live provider integration.

## DNS provider bindings

A tenant may bind a DNS zone as:

- cloudflare / managed
- external / read_only

Cloudflare bindings require only references to provider zone identity and credentials. External bindings cannot carry managed credentials.

## DNS records

Managed bindings hold desired record state. Read-only bindings hold observed record state only.

Record names and their associated domains must remain inside the configured provider zone.

## Certificates

Certificate lifecycle:

    pending -> issuing -> active
                      -> failed -> issuing
    active -> issuing | expired | revoked

An active certificate requires an active, verified domain and certificate and private-key references.

## Adapter execution boundary

Phase 07 adapters only produce typed provider request or order plans. They contain no HTTP client execution and do not call Cloudflare or ACME endpoints.

A later job-orchestrator phase will execute approved plans with idempotency, audit, retries and receipts.

## Production impact

None. No Cloudflare token is read, no DNS record is changed, no certificate is issued, and no production service is restarted or reconfigured.
