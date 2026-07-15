# Security Model

This document defines the security boundaries that shape CareerOps. It is a design baseline, not a claim that controls are already implemented.

## Table of Contents

- [Security Principles](#security-principles)
- [Authentication Boundaries](#authentication-boundaries)
- [Authorization and Workspace Isolation](#authorization-and-workspace-isolation)
- [Browser Security](#browser-security)
- [Input and File Boundaries](#input-and-file-boundaries)
- [Connected-System Privacy](#connected-system-privacy)
- [External Content and Generation](#external-content-and-generation)
- [Audit and Retention](#audit-and-retention)
- [Verification Status](#verification-status)

## Security Principles

1. Workspace scope is established before domain reads or writes.
2. Authorization remains server-side and deterministic.
3. Source content, uploaded files, and retrieved text are untrusted input.
4. External side effects occur only after committed state exists.
5. Secrets are never stored in source control or returned to clients.
6. Sensitive candidate data is collected only where it supports a defined product capability.
7. Security claims require implemented controls and verification evidence.

## Authentication Boundaries

| Interface | Planned authentication |
| --- | --- |
| Django and HTMX web application | Secure Django session, CSRF protection, email verification, optional MFA |
| Browser extension | OAuth or another installed-client flow suitable for cross-origin use |
| Native mobile application | Deferred; secure installed-client authentication and native credential storage after the API is proven |
| CLI or personal automation | Scoped personal access token if that client is accepted |
| Service workers and internal jobs | Service identity with least-privilege credentials |
| Inbound provider webhooks | Provider-specific signature verification and replay protection |

The first-party interface does not use JWT merely for fashion. External clients use separate credentials because their transport and lifecycle differ from a browser session.

## Authorization and Workspace Isolation

Workspace membership is the primary tenant boundary.

Authorization rules include:

- Selectors establish workspace visibility before composing query vocabulary.
- Write services receive the actor and workspace explicitly.
- Workspace-sensitive records carry explicit workspace ownership where it prevents leakage or enables filtered retrieval.
- External API scopes supplement rather than replace object-level authorization.
- Cross-workspace analytics require an explicit privacy model and separate projection.

Authorization tests cover both permitted access and deliberate cross-workspace denial.

## Browser Security

The planned browser baseline includes:

- HTTPS and HSTS in production
- Secure, HTTP-only, same-site cookies
- CSRF protection
- Host and proxy validation
- Content Security Policy without routine `unsafe-inline` or `unsafe-eval`
- No inline event handlers or JavaScript URLs
- Self-hosted static assets by default
- `X-Content-Type-Options: nosniff`
- Restrictive referrer and permissions policies
- Clickjacking protection through `frame-ancestors`

Security-header scanning is one release check. It does not replace application testing for authorization, injection, dependency risk, credential handling, or data isolation.

## Input and File Boundaries

The capture boundary defines explicit limits for:

- Request body size
- Raw payload size
- Extracted text size
- URL length
- JSON nesting depth
- Allowed content types
- Processing timeouts

Large source documents move to object storage with a hash and reference in PostgreSQL rather than unbounded JSONB storage.

Uploaded files require type verification, size limits, isolated processing, and a malware-scanning interface before they can become trusted evidence.

## Connected-System Privacy

External connections are narrow by default:

- GitHub imports only repositories explicitly selected by the user.
- Email begins with forwarded or explicitly selected messages rather than full-mailbox synchronization.
- Calendar integration begins outbound-first.
- Contact import requires explicit selection.
- Revocation stops future synchronization without silently deleting accepted domain evidence.

Provider credentials, raw sensitive content, authorization headers, and access tokens never enter application logs.

## External Content and Generation

Job descriptions, emails, CVs, notes, and retrieved text are treated as data rather than instructions.

Evidence-grounded generation remains advisory:

- Workspace filtering occurs before retrieval.
- Retrieved evidence retains source and version metadata.
- Substantive generated claims require citations.
- Unsupported claims are rejected or marked explicitly.
- Generated output cannot authorize access, resolve job identity, calculate the authoritative score, transition an application, or write domain state directly.
- User review is required before generated application content is published or sent.

The main control is capability separation: the generation component has no direct write authority over protected domain operations.

## Audit and Retention

Audit events record security-relevant and business-relevant actions with actor, request identifier, target reference, and relevant state delta.

Retention rules will distinguish:

- Immutable source evidence
- Candidate documents
- Generated drafts
- Application history
- Audit evidence
- Expired idempotency and operation records

Deletion and export workflows will be designed against applicable privacy requirements once the data model enters implementation.

## Verification Status

| Area | Status |
| --- | --- |
| Security boundaries | Documented |
| Threat model | Deferred until the first concrete request and data flows exist |
| Authentication implementation | Not started |
| Authorization tests | Not started |
| CSP and header verification | Not started |
| Dependency and container scanning | Planned for repository engineering |
| Privacy export and deletion | Deferred to candidate-evidence implementation |
