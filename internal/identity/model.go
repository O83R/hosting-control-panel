package identity

import (
	"errors"
	"strings"
)

type Scope string

const (
	ScopePlatform Scope = "platform"
	ScopeTenant   Scope = "tenant"
)

func (s Scope) Valid() bool {
	return s == ScopePlatform || s == ScopeTenant
}

type UserStatus string

const (
	UserActive    UserStatus = "active"
	UserSuspended UserStatus = "suspended"
	UserDisabled  UserStatus = "disabled"
)

func (s UserStatus) Valid() bool {
	switch s {
	case UserActive, UserSuspended, UserDisabled:
		return true
	default:
		return false
	}
}

type MembershipStatus string

const (
	MembershipActive    MembershipStatus = "active"
	MembershipSuspended MembershipStatus = "suspended"
)

func (s MembershipStatus) Valid() bool {
	return s == MembershipActive || s == MembershipSuspended
}

type RoleAssignment struct {
	UserID   string
	RoleCode string
	Scope    Scope
	TenantID string
}

func (a RoleAssignment) Validate() error {
	if strings.TrimSpace(a.UserID) == "" {
		return errors.New("user id is required")
	}
	if strings.TrimSpace(a.RoleCode) == "" {
		return errors.New("role code is required")
	}
	if !a.Scope.Valid() {
		return errors.New("role scope is invalid")
	}
	switch a.Scope {
	case ScopePlatform:
		if a.TenantID != "" {
			return errors.New("platform role assignment must not include tenant id")
		}
	case ScopeTenant:
		if strings.TrimSpace(a.TenantID) == "" {
			return errors.New("tenant role assignment requires tenant id")
		}
	}
	return nil
}

type TenantContext struct {
	Scope    Scope
	TenantID string
}

func (c TenantContext) Validate() error {
	if !c.Scope.Valid() {
		return errors.New("request scope is invalid")
	}
	if c.Scope == ScopePlatform && c.TenantID != "" {
		return errors.New("platform scope must not include tenant id")
	}
	if c.Scope == ScopeTenant && strings.TrimSpace(c.TenantID) == "" {
		return errors.New("tenant scope requires tenant id")
	}
	return nil
}
