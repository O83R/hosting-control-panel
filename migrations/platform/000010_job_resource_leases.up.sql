BEGIN;

-- Phase 08 isolated lease metadata. The row is retained after expiry/release:
-- its monotonically increasing fencing token must never be reset by cleanup.
ALTER TABLE hcp.resource_locks
  ADD COLUMN fencing_token bigint NOT NULL DEFAULT 1
    CHECK (fencing_token > 0);

-- Prevent normal job deletion from silently deleting fence history.
ALTER TABLE hcp.resource_locks
  DROP CONSTRAINT resource_locks_job_id_fkey;
ALTER TABLE hcp.resource_locks
  ADD CONSTRAINT resource_locks_job_id_fkey
  FOREIGN KEY (job_id) REFERENCES hcp.jobs(id) ON DELETE RESTRICT;

-- All functions remain SECURITY INVOKER and require an authorized tenant role
-- with explicit grants. A tenant GUC is not authentication by itself.
CREATE FUNCTION hcp.claim_tenant_ping_lease(
  p_job_id uuid, p_lease_seconds integer
)
RETURNS TABLE(claimed boolean, token bigint, lease_until timestamptz)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, hcp
AS $$
DECLARE
  v_tenant uuid;
  v_resource_type text;
  v_resource_id text;
  v_old_job_id uuid;
  v_old_expiry timestamptz;
  v_now timestamptz;
  v_token bigint;
  v_until timestamptz;
BEGIN
  IF hcp.current_request_scope() IS DISTINCT FROM 'tenant'
     OR hcp.current_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'tenant-scoped worker context required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_job_id IS NULL OR p_lease_seconds IS NULL
     OR p_lease_seconds < 1 OR p_lease_seconds > 300 THEN
    RAISE EXCEPTION 'invalid lease request'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_tenant := hcp.current_tenant_id();

  -- Lock the proposed queued job first, so competing claims on the same job
  -- cannot both succeed and so a terminal job is never dispatched.
  SELECT j.resource_type, j.resource_id
    INTO v_resource_type, v_resource_id
  FROM hcp.jobs j
  WHERE j.id=p_job_id AND j.tenant_id=v_tenant
    AND j.status='queued' AND j.kind='agent.ping'
    AND j.resource_type='node' AND j.resource_id IS NOT NULL
    AND j.input='{}'::jsonb AND j.intent_fingerprint IS NOT NULL
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN QUERY SELECT false, NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  v_now := clock_timestamp();
  v_until := v_now + p_lease_seconds * interval '1 second';

  -- Reading the prior holder also enforces tenant RLS. A conflicting lock
  -- from another tenant is never silently taken over.
  SELECT l.job_id, l.expires_at
    INTO v_old_job_id, v_old_expiry
  FROM hcp.resource_locks l
  WHERE l.resource_type=v_resource_type AND l.resource_id=v_resource_id
  FOR UPDATE;

  IF v_old_job_id IS NOT NULL AND v_old_expiry > v_now THEN
    RETURN QUERY SELECT false, NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  INSERT INTO hcp.resource_locks(
    resource_type,resource_id,job_id,acquired_at,expires_at,fencing_token
  )
  VALUES(v_resource_type,v_resource_id,p_job_id,v_now,v_until,1)
  ON CONFLICT (resource_type,resource_id) DO UPDATE
    SET job_id=EXCLUDED.job_id,
        acquired_at=EXCLUDED.acquired_at,
        expires_at=EXCLUDED.expires_at,
        fencing_token=hcp.resource_locks.fencing_token+1
  WHERE hcp.resource_locks.expires_at <= v_now
  RETURNING hcp.resource_locks.fencing_token, hcp.resource_locks.expires_at
    INTO v_token, v_until;

  IF v_token IS NULL THEN
    RETURN QUERY SELECT false, NULL::bigint, NULL::timestamptz;
    RETURN;
  END IF;

  -- Reconcile the expired previous owner in the *same transaction* as
  -- ownership transfer. A late worker cannot renew or release its old token.
  IF v_old_job_id IS NOT NULL AND v_old_job_id <> p_job_id THEN
    UPDATE hcp.jobs
       SET status='failed', error_code='LEASE_EXPIRED',
           error_message='Resource lease expired before verified completion'
     WHERE id=v_old_job_id AND tenant_id=v_tenant AND status='running';
  END IF;

  UPDATE hcp.jobs SET status='running'
  WHERE id=p_job_id AND tenant_id=v_tenant AND status='queued';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'job state changed while acquiring lease'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN QUERY SELECT true, v_token, v_until;
END;
$$;

CREATE FUNCTION hcp.renew_tenant_ping_lease(
  p_job_id uuid, p_token bigint, p_lease_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, hcp
AS $$
DECLARE
  v_now timestamptz;
  v_updated integer;
BEGIN
  IF hcp.current_request_scope() IS DISTINCT FROM 'tenant'
     OR hcp.current_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'tenant-scoped worker context required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_job_id IS NULL OR p_token IS NULL OR p_token < 1
     OR p_lease_seconds IS NULL OR p_lease_seconds < 1 OR p_lease_seconds > 300 THEN
    RAISE EXCEPTION 'invalid lease renewal'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_now := clock_timestamp();
  UPDATE hcp.resource_locks l
     SET expires_at=GREATEST(
       l.expires_at, v_now + p_lease_seconds * interval '1 second'
     )
  WHERE l.job_id=p_job_id AND l.fencing_token=p_token
    AND l.expires_at > v_now
    AND EXISTS (
      SELECT 1 FROM hcp.jobs j
      WHERE j.id=l.job_id AND j.tenant_id=hcp.current_tenant_id()
        AND j.status='running' AND j.kind='agent.ping'
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

CREATE FUNCTION hcp.release_tenant_ping_lease(
  p_job_id uuid, p_token bigint
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, hcp
AS $$
DECLARE
  v_now timestamptz;
  v_updated integer;
BEGIN
  IF hcp.current_request_scope() IS DISTINCT FROM 'tenant'
     OR hcp.current_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'tenant-scoped worker context required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_job_id IS NULL OR p_token IS NULL OR p_token < 1 THEN
    RAISE EXCEPTION 'invalid lease release'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_now := clock_timestamp();
  -- Running jobs cannot silently release ownership before a terminal receipt.
  UPDATE hcp.resource_locks l
     SET expires_at=GREATEST(v_now,l.acquired_at+interval '1 microsecond')
  WHERE l.job_id=p_job_id AND l.fencing_token=p_token
    AND l.expires_at > v_now
    AND EXISTS (
      SELECT 1 FROM hcp.jobs j
      WHERE j.id=l.job_id AND j.tenant_id=hcp.current_tenant_id()
        AND j.status IN ('succeeded','failed','cancelled')
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

CREATE FUNCTION hcp.reconcile_expired_tenant_ping_lease(
  p_job_id uuid, p_token bigint
)
RETURNS boolean
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, hcp
AS $$
DECLARE
  v_now timestamptz;
  v_updated integer;
BEGIN
  IF hcp.current_request_scope() IS DISTINCT FROM 'tenant'
     OR hcp.current_tenant_id() IS NULL THEN
    RAISE EXCEPTION 'tenant-scoped worker context required'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_job_id IS NULL OR p_token IS NULL OR p_token < 1 THEN
    RAISE EXCEPTION 'invalid reconciliation request'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_now := clock_timestamp();
  UPDATE hcp.jobs j
     SET status='failed', error_code='LEASE_EXPIRED',
         error_message='Resource lease expired before verified completion'
  WHERE j.id=p_job_id AND j.tenant_id=hcp.current_tenant_id()
    AND j.kind='agent.ping' AND j.status='running'
    AND EXISTS (
      SELECT 1 FROM hcp.resource_locks l
      WHERE l.job_id=j.id AND l.fencing_token=p_token
        AND l.expires_at <= v_now
    );
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated = 1;
END;
$$;

REVOKE ALL ON FUNCTION hcp.claim_tenant_ping_lease(uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION hcp.renew_tenant_ping_lease(uuid,bigint,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION hcp.release_tenant_ping_lease(uuid,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION hcp.reconcile_expired_tenant_ping_lease(uuid,bigint) FROM PUBLIC;

INSERT INTO hcp.schema_migrations(version,name)
VALUES(10,'job_resource_leases');

COMMIT;
