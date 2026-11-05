BEGIN;

-- SECURITY INVOKER: no elevated privileges, no implicit tenant bypass.
-- Only a verified, synthetic agent.ping can be enqueued through this entrypoint.
CREATE FUNCTION hcp.enqueue_tenant_ping(
  p_job_id uuid,
  p_tenant_id uuid,
  p_requested_by text,
  p_idempotency_key text,
  p_resource_id text,
  p_intent_fingerprint text
)
RETURNS TABLE(result_job_id uuid, was_replayed boolean)
LANGUAGE plpgsql
VOLATILE
SECURITY INVOKER
SET search_path = pg_catalog, hcp
AS $$
DECLARE
  v_new_id uuid;
  v_old_id uuid;
  v_old_fingerprint text;
  v_old_requester text;
  v_old_resource text;
BEGIN
  IF hcp.current_request_scope() IS DISTINCT FROM 'tenant'
     OR hcp.current_tenant_id() IS DISTINCT FROM p_tenant_id THEN
    RAISE EXCEPTION 'tenant context is required to enqueue'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_job_id IS NULL OR p_tenant_id IS NULL
     OR NULLIF(btrim(p_requested_by), '') IS NULL
     OR NULLIF(btrim(p_resource_id), '') IS NULL
     OR NULLIF(btrim(p_idempotency_key), '') IS NULL
     OR length(p_idempotency_key) > 200
     OR p_intent_fingerprint IS NULL
     OR p_intent_fingerprint !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'invalid synthetic job enqueue parameters'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO hcp.jobs (
    id, tenant_id, kind, status, requested_by, idempotency_key,
    resource_type, resource_id, input, intent_fingerprint
  )
  VALUES (
    p_job_id, p_tenant_id, 'agent.ping', 'queued', p_requested_by,
    p_idempotency_key, 'node', p_resource_id, '{}'::jsonb,
    p_intent_fingerprint
  )
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_new_id;

  IF v_new_id IS NOT NULL THEN
    RETURN QUERY SELECT v_new_id, false;
    RETURN;
  END IF;

  -- In READ COMMITTED this is a new statement snapshot after waiting for
  -- a concurrent unique-key transaction. Under stronger isolation callers
  -- may need to retry a serialization failure.
  SELECT j.id, j.intent_fingerprint, j.requested_by, j.resource_id
    INTO v_old_id, v_old_fingerprint, v_old_requester, v_old_resource
  FROM hcp.jobs AS j
  WHERE j.tenant_id = p_tenant_id
    AND j.idempotency_key = p_idempotency_key;

  IF v_old_id IS NULL THEN
    RAISE EXCEPTION 'job identity collision or invisible idempotency row'
      USING ERRCODE = 'unique_violation';
  END IF;

  IF v_old_fingerprint IS DISTINCT FROM p_intent_fingerprint
     OR v_old_requester IS DISTINCT FROM p_requested_by
     OR v_old_resource IS DISTINCT FROM p_resource_id THEN
    RAISE EXCEPTION 'idempotency key conflicts with a different intent'
      USING ERRCODE = 'unique_violation';
  END IF;

  RETURN QUERY SELECT v_old_id, true;
END;
$$;

-- A trusted application database role must receive an explicit EXECUTE
-- grant after its authentication/RBAC and tenant-context contract is reviewed.
REVOKE ALL ON FUNCTION hcp.enqueue_tenant_ping(
  uuid, uuid, text, text, text, text
) FROM PUBLIC;

INSERT INTO hcp.schema_migrations(version, name)
VALUES (9, 'tenant_ping_enqueue');

COMMIT;
