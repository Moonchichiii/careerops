# Roadmap

The roadmap is ordered by dependency and reversibility cost. It is the authority for delivery sequencing. A design that changes milestone scope must identify and update that scope explicitly rather than introducing it through another document.

## Milestones

### 0 — Documentation baseline

**Outcome:** stable vocabulary, context boundaries, architecture diagrams, conceptual data ownership, and a concise public README.

**Status:** current documentation package prepared.

### 1 — Repository engineering foundation

**Status:** in progress.

**Outcome:** executable Django scaffold with reproducible dependencies and enforceable quality checks.

Planned work:

- [x] Python 3.14 and Django 6 project metadata managed with `uv`
- [x] Settings separation
- [x] PostgreSQL local development environment
- [x] PostgreSQL-backed GitHub test service
- [x] Ruff, mypy, django-stubs, and pytest configuration
- [ ] Tailwind, HTMX, and TypeScript asset foundation
- [ ] Docker development and production images
- [x] GitHub Actions for the Python gates applicable to the scaffold
- [x] Health and readiness endpoints
- [x] Baseline security headers and structured logging
- [x] Generate and commit `uv.lock` in a Python 3.14 environment

No CareerOps domain feature is required to complete this milestone.

### 2 — Capture and canonicalize

**Outcome:** one complete vertical slice from capture request to identity-resolution result.

Scope:

- First-party HTMX capture
- Browser-extension capture API and explicit user-triggered client
- CSV batch import
- Inbound envelope persistence and provenance
- Import-run status for batch capture
- Transport idempotency
- Envelope-replay protection
- Exact source-replay detection
- Immutable observations
- Versioned normalization
- Transactional outbox
- Celery and RabbitMQ workflow
- Existing, new, ambiguous, rejected, and failed outcomes
- Operation status
- Logs, metrics, traces, and failure tests

Candidate matching is outside this milestone.

### 3 — Candidate evidence

**Outcome:** versioned, attributable evidence suitable for deterministic matching and later retrieval.

Scope:

- Candidate profiles
- Evidence documents and versions
- Evidence chunks and provenance
- Project, employment, education, CV, and note distinctions
- Export and deletion boundaries

### 4 — Deterministic opportunity matching

**Outcome:** inspectable requirement coverage and scoring.

Scope:

- Versioned job requirements
- Rule-based score components
- Supported, partial, unsupported, and insufficient-evidence outcomes
- Match evidence at chunk level
- Recalculation and supersession
- Evaluation fixtures

### 5 — Retrieval and evidence-grounded generation

**Outcome:** semantic retrieval and attributable explanations after a labelled evaluation set exists.

Scope:

- PostgreSQL full-text retrieval
- pgvector only if semantic retrieval demonstrates value
- Workspace and metadata filtering
- Retrieval evaluation
- Claim-level citations
- Unsupported-claim detection
- Human review

Generation explains or drafts; it does not become the scoring or decision authority.

### 6 — Application operations

**Outcome:** controlled application lifecycle with complete transition history.

Scope:

- Applications
- Valid state transitions
- Interviews, contacts, and follow-ups
- CV and evidence version used
- Offer and rejection outcomes

### 7 — Observability, analytics, and production readiness

**Outcome:** operational objectives and career-outcome analysis based on real workflows, followed by a production deployment with exercised smoke tests and rollback.

Scope:

- Initial deployment-target decision
- Service-level indicators
- Alert rules
- Grafana dashboards
- Source and application conversion analysis
- Match and evidence-gap analysis
- Production deployment with smoke tests and rollback
- Production security hardening
- Product analytics only where a concrete product decision requires it

## Deferred Delivery Tracks

These tracks are planned possibilities, not hidden additions to the numbered milestones.

| Track | Entry condition | First meaningful capability |
| --- | --- | --- |
| Native mobile client | Browser-extension API and operation-status contracts are stable | Share-sheet job capture with secure storage and offline-safe retry |
| Rust content processor | Python baseline demonstrates a measurable CPU, memory, or isolation constraint | Deterministic extraction and fingerprinting behind versioned messages |
| DuckDB analytical exports | PostgreSQL export data and a real offline analytical query exist | Reproducible Parquet-based workspace report |

## Open Decisions

| Decision | Current position | Resolution point |
| --- | --- | --- |
| Second DRF consumer | Native mobile is the preferred future consumer; it is not part of the first capture slice | After the extension proves the capture and operation-status contracts |
| Company identity | Workspace-scoped in the initial model | Before cross-workspace analytics |
| Data Bridge channels beyond Slice 1 | Mobile share sheet, email forwarding, feeds, connected accounts, calendars, contacts, ATS, and partner webhooks are deferred | After the three-channel capture contract is stable |
| Rust content worker | Deferred and benchmark-gated against a Python baseline | After a real content-processing workload exists |
| DuckDB analytics | Deferred until an analytical export or offline report has a real dataset | Analytics milestone |
| Idempotency expiry | Expired transport keys may create a new operation; source replay protection remains independent | Capture-slice implementation |
| Evidence chunk size | Conceptual only | Candidate-evidence retrieval tests |
| Deployment target | No cloud platform selected | Milestone 7 entry, before production deployment |
| Kubernetes | Deferred | Only after a real orchestration constraint exists |
| Product analytics | Deferred | When a specific behavioural decision requires it |

## Deliberately Deferred Documentation

The following documents become useful only after a running environment exists:

- Incident response
- Backup and restore runbook
- Disaster recovery plan
- Capacity plan
- Kubernetes operations
- Production deployment runbook
- Incident postmortem examples

Deferring them prevents operational documentation from becoming speculative fiction.
