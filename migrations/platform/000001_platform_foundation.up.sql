BEGIN;

CREATE SCHEMA IF NOT EXISTS hcp;

CREATE TABLE hcp.schema_migrations (
  version bigint PRIMARY KEY,
  name text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO hcp.schema_migrations(version, name)
VALUES (1, 'platform_foundation');

CREATE TABLE hcp.tenants (
  id uuid PRIMARY KEY,
  slug text NOT NULL UNIQUE,
  display_name text NOT NULL,
  status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')
);

CREATE TABLE hcp.nodes (
  id uuid PRIMARY KEY,
  name text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'unknown'
    CHECK (status IN ('unknown', 'online', 'degraded', 'offline', 'maintenance')),
  agent_endpoint text,
  agent_version text,
  desired_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE hcp.node_capabilities (
  node_id uuid NOT NULL REFERENCES hcp.nodes(id) ON DELETE CASCADE,
  capability text NOT NULL,
  version text,
  status text NOT NULL DEFAULT 'available'
    CHECK (status IN ('available', 'degraded', 'unavailable')),
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  observed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (node_id, capability)
);

CREATE TABLE hcp.jobs (
  id uuid PRIMARY KEY,
  tenant_id uuid REFERENCES hcp.tenants(id) ON DELETE RESTRICT,
  kind text NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  resource_type text,
  resource_id text,
  idempotency_key text,
  requested_by text NOT NULL,
  input jsonb NOT NULL DEFAULT '{}'::jsonb,
  output jsonb,
  error_code text,
  error_message text,
  attempt integer NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  CHECK (
    (status IN ('succeeded', 'failed', 'cancelled') AND completed_at IS NOT NULL)
    OR status IN ('queued', 'running')
  )
);

CREATE UNIQUE INDEX jobs_tenant_idempotency_key_uq
  ON hcp.jobs(tenant_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX jobs_status_created_at_idx
  ON hcp.jobs(status, created_at);

CREATE INDEX jobs_resource_idx
  ON hcp.jobs(resource_type, resource_id)
  WHERE resource_type IS NOT NULL AND resource_id IS NOT NULL;

CREATE TABLE hcp.job_steps (
  id bigserial PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES hcp.jobs(id) ON DELETE CASCADE,
  ordinal integer NOT NULL CHECK (ordinal > 0),
  name text NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'skipped')),
  receipt jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at timestamptz,
  completed_at timestamptz,
  UNIQUE (job_id, ordinal)
);

CREATE TABLE hcp.job_events (
  id bigserial PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES hcp.jobs(id) ON DELETE CASCADE,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  level text NOT NULL DEFAULT 'info'
    CHECK (level IN ('debug', 'info', 'warn', 'error')),
  event_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX job_events_job_time_idx
  ON hcp.job_events(job_id, occurred_at);

CREATE TABLE hcp.resource_locks (
  resource_type text NOT NULL,
  resource_id text NOT NULL,
  job_id uuid NOT NULL REFERENCES hcp.jobs(id) ON DELETE CASCADE,
  acquired_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  PRIMARY KEY (resource_type, resource_id),
  CHECK (expires_at > acquired_at)
);

COMMIT;
