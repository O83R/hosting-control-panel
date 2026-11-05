package jobs

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
)

var jobUUID = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

var ErrMissingTransaction = errors.New("trusted tenant transaction is required")

// EnqueueResult identifies an existing or newly queued synthetic job.
type EnqueueResult struct {
	JobID    string
	Replayed bool
}

// EnqueueTenantPing requires a transaction whose DB role and tenant context
// were selected by an authenticated server, never from request-controlled GUCs.
// This method creates metadata only; it never dispatches an agent action.
func EnqueueTenantPing(ctx context.Context, tx *sql.Tx, jobID string, intent Intent) (EnqueueResult, error) {
	if tx == nil {
		return EnqueueResult{}, ErrMissingTransaction
	}
	if err := ctx.Err(); err != nil {
		return EnqueueResult{}, err
	}
	if !jobUUID.MatchString(jobID) || !jobUUID.MatchString(intent.TenantID) {
		return EnqueueResult{}, fmt.Errorf("%w: job and tenant IDs must be UUIDs", ErrInvalidIntent)
	}
	plan, err := Prepare(intent)
	if err != nil {
		return EnqueueResult{}, err
	}
	var result EnqueueResult
	err = tx.QueryRowContext(ctx, `
SELECT result_job_id::text, was_replayed
FROM hcp.enqueue_tenant_ping($1::uuid, $2::uuid, $3::text, $4::text, $5::text, $6::text)`,
		jobID,
		plan.Intent.TenantID,
		plan.Intent.RequestedBy,
		plan.Intent.IdempotencyKey,
		plan.Intent.ResourceID,
		plan.Fingerprint,
	).Scan(&result.JobID, &result.Replayed)
	if err != nil {
		return EnqueueResult{}, fmt.Errorf("enqueue synthetic job: %w", err)
	}
	return result, nil
}
