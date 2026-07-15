# Bounded Contexts

CareerOps is designed as a modular monolith. Bounded contexts define ownership, vocabulary, and dependency direction inside one deployable Django system; they do not imply separate services.

## Table of Contents

- [Context Overview](#context-overview)
- [Dependency Direction](#dependency-direction)
- [Integrations](#integrations)
- [Job Registry](#job-registry)
- [Shared Platform Mechanisms](#shared-platform-mechanisms)
- [Rejected Boundaries](#rejected-boundaries)

## Context Overview

| Context | Responsibility | Status |
| --- | --- | --- |
| Identity and Access | Account identity, authentication, and credential lifecycle | Accepted, not yet designed |
| Workspaces | Tenant boundary, memberships, roles, and workspace policy | Accepted, not yet designed |
| Integrations | External transport, provenance, versioned contracts, imports, and provider communication | Initial boundary specified |
| Job Registry | Observations, normalization, identity resolution, canonical jobs, and canonical merge | Specified |
| Candidate Evidence | Candidate profiles, evidence documents, chunks, and provenance | Accepted, not yet designed |
| Opportunity Matching | Deterministic requirement coverage and scoring | Accepted, not yet designed |
| Application Operations | Applications, state transitions, interviews, contacts, and follow-ups | Accepted, not yet designed |
| Notifications | User-facing delivery and preferences | Accepted, not yet designed |
| Analytics | Career outcomes and product behaviour derived from domain events | Accepted, not yet designed |
| Audit and Compliance | Audit evidence, retention, export, and policy records | Accepted, not yet designed |
| Shared Platform Mechanisms | Idempotency, asynchronous operations, transactional outbox, and cross-cutting request metadata | Accepted |

## Dependency Direction

The main dependency flow is:

```text
Identity and Access ──▶ Workspaces
                           │
Integrations ──────────────▶ Job Registry
                               │
Candidate Evidence ────────────┼──▶ Opportunity Matching
                               │             │
                               └─────────────┘
                                             ▼
                                  Application Operations
                                             │
                                  Notifications / Analytics

Domain contexts ───────────────▶ Shared Platform Mechanisms
```

Key rules:

1. Integrations preserve inbound transport evidence and submit versioned contracts through the Job Registry's application boundary; they do not write registry tables directly.
2. The Job Registry publishes committed canonical-job events through the outbox.
3. Opportunity Matching consumes canonical-job events and candidate evidence.
4. Application Operations depends on canonical jobs and match results but owns application state.
5. Notifications and Analytics consume committed events and do not block correctness-critical workflows.
6. Contexts communicate through application services or versioned events, not direct access to another context's internal tables.
7. Shared Platform Mechanisms support domain contexts and contain no domain policy of their own.

See the [bounded-context diagram](../architecture/diagrams/bounded-context-map.mmd).

## Integrations

Integrations is CareerOps's anti-corruption layer for external systems. The informal term **Data Bridge** describes this role; the formal bounded-context name remains Integrations.

It owns provider communication, transport authentication, inbound envelopes, import runs, contract translation, synchronization state, and outbound delivery. Provider schemas stop at this boundary.

The initial capture slice supports three channels:

- First-party HTMX capture
- Browser-extension API capture
- CSV batch import

Native mobile capture, connected accounts, feeds, email, calendars, contacts, ATS integrations, and partner webhooks remain deferred until the capture contract is stable.

The durability point for pull-based synchronization is committed envelope persistence. Domain processing may continue asynchronously without holding back the provider cursor.

See the [Integrations specification](INTEGRATIONS.md).

## Job Registry

The Job Registry converts external evidence into a canonical representation of job opportunities.

It owns four aggregates with independent lifecycles:

| Aggregate | Responsibility |
| --- | --- |
| `JobObservation` | Preserve immutable source evidence and processing state |
| `JobNormalization` | Store versioned structured interpretations |
| `JobResolution` | Record append-only identity decisions |
| `CanonicalJob` | Maintain the workspace's current usable job representation |

### Why the aggregates are separate

A job observation must exist before its canonical owner is known. Some observations remain invalid, ambiguous, unresolved, or excluded. Multiple source observations may later resolve to the same canonical job, and one source listing may produce several immutable revisions.

Attaching observations directly beneath a canonical job would require knowing the canonical owner before identity resolution—the operation whose purpose is to determine that owner.

### Coordinated resolution transaction

Independent lifecycles do not mean the aggregates are never written together.

Identity resolution deliberately coordinates the observation outcome, append-only resolution decision, and canonical identity in one short transaction because those facts must not contradict one another. Requirement extraction, candidate matching, notifications, projections, retrieval indexing, and external delivery occur after commit.

See [Architecture](../architecture/ARCHITECTURE.md) and the [resolution transaction diagram](../architecture/diagrams/resolution-transaction.mmd).

### Job Registry exclusions

The Job Registry does not own:

- Source credentials or provider schedules
- Candidate evidence
- Candidate-to-job scoring
- Application state
- Notification delivery
- Product analytics
- Generative explanations

## Shared Platform Mechanisms

Shared mechanisms have one implementation across the modular monolith:

- Request idempotency
- Asynchronous operation status
- Transactional outbox
- Request and correlation identifiers
- Cross-cutting audit infrastructure

The shared layer contains mechanisms, not business decisions. For example, it stores and dispatches an outbox event but does not decide which domain event should exist.

Audit targets use polymorphic references because audit evidence may outlive deleted domain records. This deliberately trades database foreign-key enforcement for cross-domain history.

## Rejected Boundaries

### One raw-and-canonical aggregate

Rejected because:

- Source evidence must be stored before canonical identity is known.
- Ambiguous or invalid observations may never have a canonical association.
- Independent source revisions would give the aggregate an unbounded lifecycle.
- Identity resolution would become circular: an observation would need an owner before the owner could be determined.

### Separate Job Acquisition and Job Catalogue contexts

Rejected for the initial system because identity resolution requires both incoming observations and existing canonical candidates. Splitting them would move the central domain operation across a context boundary or create a third artificial coordination context.

### Accepted boundary

One Job Registry bounded context contains separate observation, normalization, resolution, and canonical-job aggregates. Integrations remains outside the registry, and Opportunity Matching remains downstream.
