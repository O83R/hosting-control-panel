package platform

import "testing"

func TestStatusValidation(t *testing.T) {
	if !TenantActive.Valid() || !TenantSuspended.Valid() {
		t.Fatal("expected tenant statuses to be valid")
	}
	if TenantStatus("deleted").Valid() {
		t.Fatal("unexpected tenant status accepted")
	}
	if !NodeOnline.Valid() || !NodeMaintenance.Valid() {
		t.Fatal("expected node statuses to be valid")
	}
	if NodeStatus("draining-forever").Valid() {
		t.Fatal("unexpected node status accepted")
	}
	if !JobQueued.Valid() || !JobFailed.Valid() {
		t.Fatal("expected job statuses to be valid")
	}
	if JobStatus("maybe").Valid() {
		t.Fatal("unexpected job status accepted")
	}
}

func TestJobTransitions(t *testing.T) {
	allowed := [][2]JobStatus{
		{JobQueued, JobRunning},
		{JobQueued, JobCancelled},
		{JobRunning, JobSucceeded},
		{JobRunning, JobFailed},
		{JobRunning, JobCancelled},
	}
	for _, pair := range allowed {
		if !CanTransition(pair[0], pair[1]) {
			t.Fatalf("expected transition %q -> %q", pair[0], pair[1])
		}
	}

	rejected := [][2]JobStatus{
		{JobQueued, JobSucceeded},
		{JobSucceeded, JobRunning},
		{JobFailed, JobQueued},
		{JobCancelled, JobRunning},
		{JobRunning, JobRunning},
		{JobStatus("bad"), JobRunning},
	}
	for _, pair := range rejected {
		if CanTransition(pair[0], pair[1]) {
			t.Fatalf("unexpected transition allowed %q -> %q", pair[0], pair[1])
		}
	}
}
