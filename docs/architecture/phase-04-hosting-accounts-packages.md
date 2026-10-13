# Phase 04 — Hosting Accounts & Packages

## Objective

Introduce the account and package resources that sit between tenants and concrete hosted applications.

## Package model

A package defines tenant-owned limits for:

- sites;
- domains;
- databases;
- storage;
- optional bandwidth.

Mail quotas are intentionally absent because integrated mail hosting is outside M1.

## Account model

Each hosting account belongs to exactly one tenant and includes:

- stable account key;
- display name;
- active tenant-member owner;
- package;
- optional assigned node;
- lifecycle state;
- optimistic version number.

## What this phase does not do

Phase 04 does not create Linux users, Docker containers, reverse-proxy routes, DNS records or databases. Provisioning will be introduced through durable jobs and typed Node Agent capabilities in later phases.

## Verification

CI validates:

- package and account domain models;
- lifecycle transitions;
- same-tenant package enforcement;
- active owner membership;
- tenant RLS isolation;
- fail-closed tenant context;
- hosting RBAC permissions.
