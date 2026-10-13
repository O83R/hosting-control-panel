# Hosting Control Panel

A secure hosting control platform evolving from the existing production operations panel.

## Stable baseline

The imported production baseline is tagged:

`v0.20.1-baseline`

The `main` branch contains only reviewed and accepted changes.

## Development flow

```text
phase/* branch
  -> source CI
  -> platform contract tests
  -> independent verifier
  -> isolated staging
  -> verification receipts
  -> review / approval
  -> main
```

See `AGENTS.md` and `docs/development-factory.md` for repository and safety rules.

## Architecture direction

The project is evolving incrementally into a modular monolith with:

- identity and RBAC;
- tenants and hosting accounts;
- nodes and typed Node Agents;
- durable jobs and reconciliation;
- domains, DNS and SSL;
- databases;
- backups and restore rehearsal;
- monitoring and audit;
- separate admin and customer experiences.

Production operations remain allowlist-driven. Arbitrary root shell execution from the web UI is not part of the architecture.
