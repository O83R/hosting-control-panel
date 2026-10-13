package platform

// TenantStatus is the lifecycle state of a control-plane tenant.
type TenantStatus string

const (
	TenantActive    TenantStatus = "active"
	TenantSuspended TenantStatus = "suspended"
)

func (s TenantStatus) Valid() bool {
	switch s {
	case TenantActive, TenantSuspended:
		return true
	default:
		return false
	}
}

// NodeStatus represents the control plane's current view of a managed node.
type NodeStatus string

const (
	NodeUnknown     NodeStatus = "unknown"
	NodeOnline      NodeStatus = "online"
	NodeDegraded    NodeStatus = "degraded"
	NodeOffline     NodeStatus = "offline"
	NodeMaintenance NodeStatus = "maintenance"
)

func (s NodeStatus) Valid() bool {
	switch s {
	case NodeUnknown, NodeOnline, NodeDegraded, NodeOffline, NodeMaintenance:
		return true
	default:
		return false
	}
}

// JobStatus is the durable state of an asynchronous control-plane job.
type JobStatus string

const (
	JobQueued    JobStatus = "queued"
	JobRunning   JobStatus = "running"
	JobSucceeded JobStatus = "succeeded"
	JobFailed    JobStatus = "failed"
	JobCancelled JobStatus = "cancelled"
)

func (s JobStatus) Valid() bool {
	switch s {
	case JobQueued, JobRunning, JobSucceeded, JobFailed, JobCancelled:
		return true
	default:
		return false
	}
}

// CanTransition reports whether a durable job may move from one state to another.
// Terminal states are immutable.
func CanTransition(from, to JobStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case JobQueued:
		return to == JobRunning || to == JobCancelled
	case JobRunning:
		return to == JobSucceeded || to == JobFailed || to == JobCancelled
	default:
		return false
	}
}
