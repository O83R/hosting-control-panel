package hosting

import (
	"errors"
	"regexp"
	"strings"
)

var resourceCodePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)

type PackageStatus string

const (
	PackageActive   PackageStatus = "active"
	PackageDisabled PackageStatus = "disabled"
)

func (s PackageStatus) Valid() bool {
	return s == PackageActive || s == PackageDisabled
}

type AccountStatus string

const (
	AccountPending   AccountStatus = "pending"
	AccountActive    AccountStatus = "active"
	AccountSuspended AccountStatus = "suspended"
	AccountDisabled  AccountStatus = "disabled"
)

func (s AccountStatus) Valid() bool {
	switch s {
	case AccountPending, AccountActive, AccountSuspended, AccountDisabled:
		return true
	default:
		return false
	}
}

func CanTransitionAccount(from, to AccountStatus) bool {
	if !from.Valid() || !to.Valid() || from == to {
		return false
	}
	switch from {
	case AccountPending:
		return to == AccountActive || to == AccountDisabled
	case AccountActive:
		return to == AccountSuspended || to == AccountDisabled
	case AccountSuspended:
		return to == AccountActive || to == AccountDisabled
	default:
		return false
	}
}

type PackageLimits struct {
	MaxSites     int
	MaxDomains   int
	MaxDatabases int
	StorageMB    int64
	BandwidthMB  *int64
}

func (l PackageLimits) Validate() error {
	if l.MaxSites < 1 {
		return errors.New("max sites must be at least 1")
	}
	if l.MaxDomains < 0 {
		return errors.New("max domains must not be negative")
	}
	if l.MaxDatabases < 0 {
		return errors.New("max databases must not be negative")
	}
	if l.StorageMB < 1 {
		return errors.New("storage must be positive")
	}
	if l.BandwidthMB != nil && *l.BandwidthMB < 1 {
		return errors.New("bandwidth must be positive when limited")
	}
	return nil
}

type Package struct {
	ID          string
	TenantID    string
	Code        string
	DisplayName string
	Status      PackageStatus
	Limits      PackageLimits
}

func (p Package) Validate() error {
	if strings.TrimSpace(p.ID) == "" || strings.TrimSpace(p.TenantID) == "" {
		return errors.New("package id and tenant id are required")
	}
	if !resourceCodePattern.MatchString(p.Code) {
		return errors.New("package code is invalid")
	}
	if strings.TrimSpace(p.DisplayName) == "" {
		return errors.New("package display name is required")
	}
	if !p.Status.Valid() {
		return errors.New("package status is invalid")
	}
	return p.Limits.Validate()
}

type Account struct {
	ID          string
	TenantID    string
	PackageID   string
	OwnerUserID string
	NodeID      string
	Key         string
	DisplayName string
	Status      AccountStatus
	Version     int64
}

func (a Account) Validate() error {
	if strings.TrimSpace(a.ID) == "" ||
		strings.TrimSpace(a.TenantID) == "" ||
		strings.TrimSpace(a.PackageID) == "" ||
		strings.TrimSpace(a.OwnerUserID) == "" {
		return errors.New("account identity fields are required")
	}
	if !resourceCodePattern.MatchString(a.Key) {
		return errors.New("account key is invalid")
	}
	if strings.TrimSpace(a.DisplayName) == "" {
		return errors.New("account display name is required")
	}
	if !a.Status.Valid() {
		return errors.New("account status is invalid")
	}
	if a.Version < 1 {
		return errors.New("account version must be positive")
	}
	return nil
}
