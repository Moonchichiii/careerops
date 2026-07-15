# Engineering Standards

These standards define how CareerOps code is structured, checked, and accepted. They are intended to remain strict without encouraging routine suppressions or framework-hostile abstractions.

## Table of Contents

- [Responsibility Boundaries](#responsibility-boundaries)
- [Django Code Structure](#django-code-structure)
- [Integration Contracts](#integration-contracts)
- [Database and Query Discipline](#database-and-query-discipline)
- [Transactions and Asynchronous Work](#transactions-and-asynchronous-work)
- [HTMX and TypeScript](#htmx-and-typescript)
- [Typing and Linting](#typing-and-linting)
- [Testing](#testing)
- [CI Gate Activation](#ci-gate-activation)
- [Definition of Done](#definition-of-done)
- [Suppression Policy](#suppression-policy)
- [Documentation Governance](#documentation-governance)

## Responsibility Boundaries

| Concern | Owner |
| --- | --- |
| Persistent invariants | PostgreSQL constraints |
| Small entity behaviour | Model methods |
| Reusable query vocabulary | Custom QuerySets |
| Authorized read composition | Selectors |
| Transactional writes | Services |
| HTTP parsing and rendering | Django views |
| External API representation | DRF serializers and views |
| Durable background execution | Celery tasks |
| Provider communication and schema translation | Integration adapters and versioned contracts |
| Inbound transport evidence | Integrations and inbound envelopes |
| Committed asynchronous publication | Transactional outbox |
| Server-driven interaction | HTMX |
| Browser-only complexity | TypeScript |

A rule has one authoritative implementation. Better error messages may be added at an outer boundary, but they do not replace the underlying invariant.

## Django Code Structure

### QuerySets and selectors

Custom QuerySets expose composable domain vocabulary such as `active()`, `remote()`, or `posted_since()`.

Selectors establish workspace visibility and authorization before composing QuerySet methods. QuerySet methods do not receive a user and do not decide access.

This prevents reusable query fragments from accidentally becoming authorization boundaries.

### Services

Services own domain writes and transaction boundaries. Public service functions use keyword-only arguments, explicit actor and workspace parameters, typed return values, and domain-specific exceptions.

Services do not accept request, serializer, or template objects.

### Models

Models own data shape, database-facing validation, and small behaviours tied directly to one entity. Core workflows do not depend on Django signals.

The default manager remains unfiltered. Archived or active records are selected explicitly through QuerySet methods so administrative, migration, and repair workflows do not lose visibility.

### Abstractions

Stateless operations remain functions. A class is introduced when it owns meaningful collaborators or state, such as a source-specific import pipeline.

Custom descriptors are not used on Django models. Queryable derived values use database fields or `GeneratedField`; simple non-queryable values may use `@property`.

## Integration Contracts

> External systems communicate with CareerOps only through versioned integration contracts. Provider schemas stop at the adapter boundary. The Data Bridge proves provenance and safe delivery; domain contexts determine meaning and state.

Integration rules:

- Raw provider payloads remain immutable transport evidence.
- Adapters verify transport concerns and translate provider schemas.
- Domain services consume provider-neutral contracts rather than provider payloads.
- Contract versions change explicitly when compatibility changes.
- Cursor progress is acknowledged only after inbound envelopes are durably committed.
- Provider credentials, raw sensitive content, and authorization headers do not enter logs.
- Selective import and least-privilege scopes are the default for connected systems.
- Integration failures and domain ambiguity are classified separately.

Django app and module structures are targets, not empty scaffolding requirements. A module is created when a real responsibility exists to occupy it.

## Database and Query Discipline

PostgreSQL owns invariants that must survive concurrency and alternate write paths.

Examples include:

- Salary minimum does not exceed salary maximum
- Workspace memberships are unique
- A normalization version is unique for one observation
- Source-replay identity is unique within its defined scope
- Ordered pipeline stages do not collide

Read paths are explicit about related data:

- `select_related()` for single-valued relationships
- Filtered `Prefetch` objects for controlled collections
- Cursor pagination for external synchronization
- `.iterator()` for large exports
- Bulk operations where service-layer invariants permit them

Critical selectors receive query-count regression tests. Search and identity-resolution queries receive PostgreSQL plan review once real data volumes exist.

## Transactions and Asynchronous Work

Transactions are short and contain only work required for consistency.

External calls, message delivery, document parsing, retrieval, and generation occur outside database transactions.

The transactional outbox records publication intent in the same transaction as domain state. An `on_commit` callback may wake the dispatcher, but durable polling preserves correctness.

Celery tasks are:

- Idempotent
- Retry-safe
- Time-bounded
- Observable
- Explicit about terminal failure
- Routed to queues by workload type where operational evidence justifies it

## HTMX and TypeScript

Django renders complete pages and reusable partials. A view uses the same selector, pagination, and context for full-page and HTMX responses; only the render target changes.

TypeScript is reserved for genuine browser-specific behaviour such as:

- Accessible drag and drop
- Upload progress and cancellation
- Keyboard command interfaces
- Complex chart interaction
- Browser-extension functionality

TypeScript does not duplicate domain validation or maintain a second authoritative copy of server state.

The browser baseline excludes inline scripts, inline event handlers, `eval`, dynamically inserted scripts, and unreviewed third-party assets.

## Typing and Linting

### mypy

mypy runs in strict mode with `django-stubs`. Application code is fully typed; generated migrations are excluded.

Important settings include:

- `strict = true`
- `warn_unreachable = true`
- `warn_redundant_casts = true`
- `warn_unused_ignores = true`
- `no_implicit_reexport = true`

Custom managers and QuerySets receive explicit types so query vocabulary does not degrade to `Any`.

### Ruff

Ruff owns formatting, imports, common Python defects, modernization, Django-specific checks, pytest style, simplification, and selected performance rules.

Type completeness remains mypy's responsibility. Line wrapping remains the formatter's responsibility. Rules that generate routine false-positive suppressions are not enabled merely for maximum rule count.

## Testing

The test strategy includes:

### Unit tests

- Normalization rules
- Identity signals and thresholds
- Application transition rules
- Scoring components
- Signature and hashing utilities

### PostgreSQL integration tests

- Constraints
- Transactions and rollback
- Advisory-lock behaviour
- Concurrent identity resolution
- Full-text and trigram search
- Materialized projections where introduced

SQLite is not used as a substitute for PostgreSQL behaviour.

### API contract tests

- Authentication and authorization
- Idempotency
- Cursor pagination
- Error envelopes
- Operation resources
- Schema generation and compatibility

### Browser tests

- Full-page and HTMX responses
- Keyboard navigation
- Accessibility
- Runtime CSP violations
- Console and page errors
- Critical user journeys

### Asynchronous workflow tests

- Outbox delivery
- Task idempotency
- Retry and terminal failure
- Queue routing
- Trace propagation
- Worker restart behaviour

## CI Gate Activation

The full merge contract is declared early and activated when a real artifact exists to validate.

| Gate | Status | Activation point |
| --- | --- | --- |
| Repository structure policy | Active after the initial lockfile is committed | Repository engineering foundation |
| Ruff and mypy | Configured; active after the initial lockfile is committed | Repository engineering foundation |
| Django system and deployment checks | Configured; active after the initial lockfile is committed | Django scaffold |
| Migration consistency | Configured for the custom user model | First persistent model |
| Container build and scan | Deferred | First production container |
| Constraint tests | Deferred | First database invariant |
| Query budgets | Deferred | First production selector |
| OpenAPI validation and generated types | Deferred | First DRF endpoint |
| Playwright, HTML, accessibility, and runtime CSP | Deferred | First HTMX journey |
| Celery reliability and outbox delivery | Deferred | First asynchronous workflow |
| Deployment smoke tests | Deferred | First preview environment |

A gate is marked as declared, active, deferred to a milestone, or retired. It does not silently skip.

## Definition of Done

Every completed change includes:

- Clear ownership and naming
- Relevant tests
- Updated documentation when a contract or decision changes
- No unexplained lint or type suppressions
- No regression in applicable security or quality gates

Additional requirements apply by change type:

| Change | Required evidence |
| --- | --- |
| Database | Migration review, constraints, rollback or compatibility analysis |
| Read path | Query budget and related-object strategy |
| Write path | Explicit transaction boundary, audit/outbox effects, concurrency analysis |
| External API | Schema, error contract, authentication, idempotency where relevant |
| Integration channel | Versioned contract, provenance, replay semantics, durability point, selective-import policy, and failure classification |
| Browser interaction | Full and partial response tests, keyboard and accessibility checks |
| Asynchronous workflow | Idempotency, retry, routing, failure state, and observability |

A milestone is complete when its documented outcome works end to end, its active gates pass, and the documentation describes the implemented system rather than the intended one.

## Suppression Policy

Suppressions are exceptional and visible.

A suppression includes:

- The narrow rule or error code
- The reason the tool cannot model the behaviour correctly
- A tracking reference when the workaround should be removed

Unused type ignores fail the build. Suppression counts are monitored so strictness cannot decay through accumulated exceptions.

## Documentation Governance

Documentation is part of the contract, not a parallel source of speculative scope.

Rules:

1. `ROADMAP.md` is the delivery-sequencing authority.
2. A new design that changes milestone scope must identify that change explicitly and update the roadmap in the same change.
3. New architecture documents are reviewed against the glossary, bounded contexts, current ERD version, and roadmap before acceptance.
4. Planned, deferred, and implemented states remain visibly distinct.
5. Diagrams and documentation are updated when implementation changes a contract or boundary.
6. Superseded documents are removed or marked superseded; two active documents do not own the same concern.
7. No technology or client is moved into an earlier milestone through an incidental design document.
