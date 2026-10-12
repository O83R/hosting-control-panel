# Development Factory

This document defines the development acceleration path for the Hosting Control Panel.

## Canonical flow

```text
main (stable)
  -> phase/* branch
  -> source CI
  -> independent verifier
  -> loopback-only ephemeral staging
  -> verification receipt
  -> review / approval
  -> merge to main
```

## Separation of responsibilities

### Source CI

The source CI validates the repository itself:

- Go formatting;
- `go vet`;
- `go test`;
- clean Go build;
- JavaScript syntax;
- Compose parsing;
- production-safety source contracts;
- Docker image build.

### Independent verifier

The verifier starts from a fresh checkout in a separate CI job. It does not reuse a running production service or production database.

It performs a clean Docker build, creates a synthetic snapshot fixture, starts an ephemeral loopback-only panel, verifies health/auth/access contracts and runtime isolation, and emits a machine-readable verification receipt.

The verifier must not receive production credentials.

## Staging contract

CI staging is intentionally limited to:

- bind address: `127.0.0.1`;
- synthetic snapshot data only;
- temporary isolated Docker volumes;
- read-only root filesystem;
- `no-new-privileges`;
- all Linux capabilities dropped;
- no Docker socket mount;
- no `/srv/apps/*` mounts;
- no production database connection;
- cleanup after every run.

This CI staging is a release gate, not production deployment.

## Production promotion

Promotion to production remains a separate controlled operation. A successful GitHub CI/verification result does not itself authorize deployment, service restart, database mutation, or production restore.

The production Action Agent remains restricted and allowlist-driven.
