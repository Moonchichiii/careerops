# Integrations

The Integrations bounded context is CareerOps's controlled boundary with external systems. It receives and delivers data without allowing provider-specific schemas, credentials, or transport behaviour to leak into domain contexts.

The informal term **Data Bridge** refers to this boundary. The formal bounded-context name remains **Integrations**.

## Table of Contents

- [Constitutional Rule](#constitutional-rule)
- [Responsibilities](#responsibilities)
- [Boundary Model](#boundary-model)
- [Core Concepts](#core-concepts)
- [Replay and Duplicate Layers](#replay-and-duplicate-layers)
- [Durability and Cursor Semantics](#durability-and-cursor-semantics)
- [Versioned Contracts](#versioned-contracts)
- [Initial Capture Channels](#initial-capture-channels)
- [Selective Import and Privacy](#selective-import-and-privacy)
- [Candidate Evidence Provenance](#candidate-evidence-provenance)
- [Failure Classification](#failure-classification)
- [Observability](#observability)
- [Deferred Capabilities](#deferred-capabilities)
- [Data Model Status](#data-model-status)

## Constitutional Rule

> External systems communicate with CareerOps only through versioned integration contracts. Provider schemas stop at the adapter boundary. The Data Bridge proves provenance and safe delivery; domain contexts determine meaning and state.

This rule applies to inbound captures, files, feeds, webhooks, connected accounts, and outbound delivery.

## Responsibilities

Integrations owns:

- Provider connections and granted scopes
- Transport authentication and signature verification
- Polling, webhooks, file intake, and explicit user submissions
- Inbound transport evidence and payload provenance
- Provider delivery replay protection
- Import runs and synchronization checkpoints
- Translation from provider schemas to CareerOps contracts
- Outbound provider delivery and retry state
- Provider-specific rate limits and operational health

Integrations does not own:

- Canonical job identity
- Candidate-to-job matching
- Candidate evidence meaning
- Application state transitions
- Workspace authorization policy
- Product analytics conclusions
- Generated claims or recommendations

A provider adapter translates data. It does not decide what the data means inside CareerOps.

## Boundary Model

```text
External source or client
        │
        ▼
Provider or channel adapter
        │
        ▼
InboundEnvelope
        │
        ▼
Versioned CareerOps contract
        │
        ├── Job Registry
        ├── Candidate Evidence
        ├── Application Operations
        └── Notifications
```

The envelope and observation are deliberately separate:

- An `InboundEnvelope` records what arrived, through which channel, and whether it was received safely.
- A `JobObservation` records accepted job-domain evidence.

An envelope may be rejected, quarantined, or retained for reprocessing without ever becoming a job observation. A job observation may later remain unresolved or ambiguous without a canonical job.

## Core Concepts

### Source connection

An authorized relationship between a workspace and an external provider. It records provider identity, granted scopes, connection status, credential reference, synchronization health, and revocation state.

Credentials are stored through an approved secrets mechanism. They are not general-purpose model data and never appear in logs.

A source connection is introduced only when a channel requires persistent provider authorization. Manual capture, browser-extension capture, and local file import do not require one by default.

### Inbound envelope

Immutable transport evidence for one received payload.

An envelope records:

- Workspace and channel
- Provider or capture origin
- External delivery or object reference where available
- Content type and payload hash
- Payload storage reference
- Provider and received timestamps
- Contract or schema version
- Request, correlation, and import-run references
- Acceptance, rejection, or quarantine state

Large payloads belong in object storage. PostgreSQL stores their reference, hash, metadata, and processing state.

### External object reference

A provider-neutral mapping between an external identity and a CareerOps domain record.

It prevents provider identifiers such as `github_id`, `linkedin_id`, or vendor-specific keys from spreading across domain models.

This concept becomes active with the first provider that exposes a stable external identity. It is not required merely to scaffold the Integrations context.

### Synchronization cursor

A checkpoint for incremental pull-based synchronization.

It records the provider, connection, resource type, cursor or checkpoint, and last successful acceptance point. Cursor state is transport coordination, not domain state.

### Import run

The operational record for one batch import or synchronization attempt.

It records:

- Channel and connection where applicable
- Start and completion timestamps
- Received, accepted, replayed, rejected, and failed counts
- Current status and failure summary

A CSV import creates one import run and one inbound envelope for each accepted row or logical record.

## Replay and Duplicate Layers

CareerOps distinguishes five conditions that may otherwise be mislabeled as duplicates.

| Condition | Layer | Primary mechanism | Result |
| --- | --- | --- | --- |
| Transport retry | Client request | Idempotency key and request fingerprint | Replay the original accepted operation |
| Envelope replay | Integration transport | Provider delivery identity or envelope fingerprint | Reuse the accepted envelope; do not process the same delivery twice |
| Exact source replay | Job evidence | Source identity, external reference, and content hash | Reuse the existing job observation |
| Source revision | Job evidence | Same source identity with a changed content hash | Create a new immutable observation revision |
| Canonical identity match | Domain identity | Structured identity signals and resolution policy | Resolve separate observations to the same canonical job |

The layers are independent. An expired transport idempotency record does not weaken source replay protection. Two distinct envelopes may still represent the same source replay. Two different source observations may still represent the same canonical opportunity.

## Durability and Cursor Semantics

For pull-based synchronization, the durability point is successful persistence of the inbound envelope—not creation of a domain record.

The cursor may advance after the corresponding envelopes have been committed because:

- The original payload is durably preserved.
- Contract validation and domain processing can be retried independently.
- A normalization or domain-processing backlog does not stall provider synchronization.
- Rejected or quarantined payloads remain visible for diagnosis and deliberate reprocessing.

A cursor must not advance when envelope persistence fails.

The cursor update and the envelope batch acceptance must be coordinated so that the system cannot acknowledge provider progress while losing the received payloads.

## Versioned Contracts

Every adapter translates provider data into a provider-neutral CareerOps contract.

A contract contains:

- Contract name and version
- Workspace
- Source and channel provenance
- External identity where available
- Payload hash and storage reference
- Actor or connection reference
- Correlation and operation identifiers
- Domain-specific content required by the receiving context

Contract rules:

1. Provider schemas do not enter domain services directly.
2. Contracts are schema-validated before domain processing.
3. Breaking changes create a new contract version.
4. Consumers remain compatible with supported earlier versions.
5. Raw provider content remains untrusted data.
6. Contracts carry provenance but do not assign domain meaning beyond their boundary.

## Initial Capture Channels

The first capture and canonicalization slice supports exactly three channels:

### First-party HTMX capture

An authenticated user submits a URL and approved content through the Django interface.

This proves the same-origin session and CSRF boundary.

### Browser-extension capture

The extension submits an explicit user-selected capture through the versioned DRF API.

This proves cross-origin authentication, idempotency, typed errors, operation status, and client contract compatibility.

### CSV import

An authenticated user uploads a bounded CSV file that creates an import run and one envelope per logical record.

This proves batch validation, partial failure handling, provenance, replay detection, and observable import status.

These channels are sufficient to validate the Data Bridge without introducing a connected-account synchronization engine or native mobile application.

## Selective Import and Privacy

Connected systems use least-privilege scopes and selective import by default.

Examples:

- GitHub imports only repositories explicitly selected by the user.
- Email begins with forwarded or explicitly selected messages, not full-mailbox synchronization.
- Calendar integration begins outbound-first for interview and reminder events.
- Contact import, if introduced, begins with explicit selection rather than full-address-book synchronization.

Connection revocation stops future synchronization without silently deleting already accepted domain evidence. Retention and deletion follow the owning domain's policy.

Raw content, access tokens, authorization headers, and sensitive provider data never enter application logs.

## Candidate Evidence Provenance

Evidence must preserve both its source and the type of claim it can support.

CareerOps distinguishes:

| Classification | Meaning |
| --- | --- |
| Professional experience | Work performed in an employment or contracted professional context |
| Project experience | Work demonstrated through a personal, educational, open-source, or portfolio project |
| Education | Formal study, training, or certification evidence |
| Demonstrated knowledge | Evidence that a concept was implemented, explained, or assessed without implying employment experience |
| User assertion | A claim supplied by the user without independent supporting evidence |
| Externally verified evidence | Evidence confirmed through an approved external source or verification process |

A single item may have both provenance metadata and one primary experience classification. Downstream matching and generation must not translate project experience into professional experience or user assertion into external verification.

## Failure Classification

### Authentication or authorization failure

Examples include revoked credentials, expired connections, or removed scopes.

The connection is paused, the user is notified, and previously accepted data remains intact.

### Provider availability failure

Examples include timeouts, rate limits, and provider outages.

The bridge retries with bounded backoff, preserves cursor state, and records provider health without duplicating accepted envelopes.

### Envelope validation failure

Examples include invalid signatures, unsupported content types, malformed schemas, oversized payloads, and missing transport identity.

The envelope is rejected or quarantined before domain processing.

### Contract validation failure

The payload was received safely but cannot be translated into a supported CareerOps contract.

The envelope remains available for diagnosis or reprocessing after an adapter update.

### Domain ambiguity

Multiple canonical jobs are plausible after a valid job contract reaches the Job Registry.

This is not an integration failure. The Job Registry records an ambiguous resolution and may request human review.

## Observability

Integration workflows carry:

- `request_id`
- `correlation_id`
- `workspace_id`
- `connection_id` where applicable
- `import_run_id` where applicable
- `envelope_id`
- downstream operation and observation identifiers
- `trace_id`

Planned metrics include:

- Envelopes received, accepted, replayed, rejected, and quarantined
- Import duration and item counts
- Provider errors and rate-limit events
- Synchronization lag and cursor age
- Contract-validation failures
- Outbound delivery attempts and terminal failures

Metrics and logs expose identifiers and classifications, not raw sensitive content.

## Deferred Capabilities

The following remain outside the first capture slice:

- Native mobile share-sheet capture
- Email forwarding and connected inboxes
- RSS, Atom, and scheduled provider feeds
- Connected calendars and contacts
- ATS and partner integrations
- Customer-facing outbound webhooks
- Pull-based synchronization and cursor implementation

The native mobile application is the preferred future second DRF consumer. Its share-sheet workflow begins only after the extension has proven the capture API and operation-status contract.

A Rust content worker is considered only after a Python implementation establishes a real processing workload and benchmark baseline. If retained, it processes deterministic content and returns versioned results; it does not write CareerOps domain state directly.

DuckDB remains deferred until an analytical export or offline reporting workflow produces a real dataset and query requirement.

## Data Model Status

The current DBML is the **v1 conceptual ERD** for the accepted Job Registry and downstream product model.

Data Bridge persistence is a **v2 modelling scope**. It will pressure-test the following concepts before they become tables:

- Inbound envelope
- Import run
- Source connection
- Synchronization cursor
- External object reference

Not every concept must become a table in the first integration implementation. Tables are introduced when a real channel requires the lifecycle they represent.
