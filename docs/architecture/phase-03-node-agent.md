# Phase 03 — Typed Node Agent

## Objective

Establish the control-plane-to-node protocol boundary without changing the production Action Agent.

## Initial protocol

The reference Node Agent provides:

- public loopback health check;
- authenticated capability discovery;
- authenticated typed `agent.ping` action;
- signed requests;
- timestamp freshness validation;
- nonce replay protection;
- action receipts;
- exact allowlisting.

## Safety invariants

The Phase 03 reference implementation:

- binds only to loopback;
- contains no `os/exec` or shell execution primitive;
- exposes no generic command endpoint;
- has no Docker socket access;
- has no production filesystem mount;
- has no production database access.

## Future transport

Remote node enrollment will require authenticated node identity and mTLS/certificate lifecycle. The bootstrap HMAC contract is not permission to expose this listener on a public or private network interface.

## Compatibility

The existing production Action Agent remains the production execution mechanism until a later migration is separately rehearsed and approved.
