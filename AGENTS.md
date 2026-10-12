# Hosting Control Panel — Agent Rules

This repository is the canonical source for the Hosting Control Panel.

## Branch policy

- `main` is the last reviewed, accepted, stable source.
- Development happens on `phase/*` branches.
- Merge to `main` only after CI, review, and explicit release approval.
- The production baseline is tagged `v0.20.1-baseline`.

## Production safety invariants

Development and CI must not:

- connect to or mutate production application databases;
- restart or mutate production containers or services;
- mount the root Docker socket;
- add arbitrary shell execution to the production Action Agent;
- expose the panel publicly by default;
- enable production restore;
- commit credentials, tokens, private keys, runtime SQLite databases, backups, or logs.

The production Action Agent must remain allowlist-driven. New production actions must use explicit typed actions, validation, audit, preflight, verification, and rollback/compensation where applicable.

## Development workflow

For every task:

1. inspect the relevant source and contracts;
2. make the smallest coherent change;
3. run change-aware checks;
4. run the full release gate before merging a phase;
5. record the commit and verification result;
6. merge only after review/approval.

Do not modify historical baseline bytes merely to satisfy formatting checks. New or changed code must pass current formatting and lint rules.

## Required local/CI checks

At minimum:

- Go formatting check;
- `go vet ./...`;
- `go test ./...`;
- clean Go build;
- JavaScript syntax checks;
- Compose configuration validation;
- production-safety contract checks;
- Docker image build.

## Architecture direction

Evolve the current application incrementally toward a modular monolith. Do not rewrite the stable control plane from scratch. Keep operations, identity/RBAC, audit, jobs, node-agent protocol, hosting resources, backups, and adapters separated by explicit package boundaries as they are introduced.
