# Phase 06 — Domains & Proxy Routes

## Objective

Define safe tenant-aware resources for domain ownership and reverse-proxy intent before connecting any external provider.

## Resource chain

```text
Tenant
  -> Hosting Account
      -> Site
          -> Domain
              -> Proxy Route
```

## Domain workflow

```text
unverified -> pending -> verified
                     \-> failed -> pending

domain:
pending -> active -> disabled
   \----------------> disabled
disabled -> active   (only while verified)
```

A domain must be verified before activation.

## Proxy workflow

A route begins pending. Activation requires:

- same tenant as its domain;
- active domain;
- verified domain;
- active site;
- valid HTTP/HTTPS target host and port.

## What this phase does not do

Phase 06 does not:

- create DNS records;
- call Cloudflare;
- create Nginx Proxy Manager hosts;
- issue or renew certificates;
- expose new public ports;
- alter production services.

Those behaviors require adapters, typed jobs and isolated rehearsals in later phases.
