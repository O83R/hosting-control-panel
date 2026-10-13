# ADR-006: Node Agent Protocol v1

- Status: Accepted
- Phase: 03

## Decision

HCP Node Agents expose a small, typed, versioned HTTP protocol. They do not expose arbitrary shell or arbitrary command execution.

Phase 03 implements a loopback-only reference agent with a single read-only capability:

`agent.ping`

## Request authentication

The Phase 03 reference transport uses an HMAC-SHA256 request signature with:

- protocol version;
- Unix timestamp;
- unique nonce;
- HTTP method;
- exact request path;
- SHA-256 body hash.

Requests outside the allowed clock-skew window are rejected. A nonce may be accepted only once within the replay window.

This HMAC mode is a bootstrap/reference contract only. Remote production agents must not be exposed until a separately reviewed mTLS identity and certificate-rotation phase is complete.

## Action model

Every action has an explicit route and typed payload. Adding a new capability requires code, validation, tests, audit/job integration and review.

A generic `exec`, `shell` or arbitrary command endpoint is forbidden.

## Production impact

None. The Phase 03 agent is not installed on the production VPS and does not replace the existing restricted production Action Agent.
