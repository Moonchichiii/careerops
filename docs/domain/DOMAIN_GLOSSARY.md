# Domain Glossary

This glossary is the authoritative vocabulary for CareerOps. Terms are intentionally narrow so that source ingestion, job identity, candidate fit, and application state are not conflated.

## Table of Contents

- [Integrations](#integrations)
- [Job Registry](#job-registry)
- [Duplicate Conditions](#duplicate-conditions)
- [Candidate and Matching](#candidate-and-matching)
- [Application Operations](#application-operations)
- [Shared Platform Terms](#shared-platform-terms)

## Integrations

### Data Bridge

The informal name for the Integrations bounded context at the boundary between CareerOps and external systems.

The Data Bridge proves provenance, safe receipt, contract validity, and delivery state. Domain contexts determine business meaning and state.

### Source connection

An authorized relationship between a workspace and an external provider, including granted scopes, connection status, credential reference, synchronization health, and revocation state.

A source connection exists only for channels that require persistent provider authorization.

### Inbound envelope

Immutable transport evidence for one received payload.

It records where the payload came from, how it arrived, its content type and hash, relevant provider identifiers, timestamps, schema version, payload reference, and processing disposition.

An envelope may be rejected, quarantined, or reprocessed without ever becoming domain evidence.

### External object reference

A provider-neutral mapping between an external object identity and a CareerOps domain record.

It prevents provider-specific identifiers from spreading across domain models.

### Synchronization cursor

A durable checkpoint for incremental pull-based synchronization.

The cursor advances only after the corresponding inbound envelopes have been committed. Domain processing may continue asynchronously from those preserved envelopes.

### Import run

The operational record for one file import or provider synchronization attempt, including received, accepted, replayed, rejected, and failed item counts.

### Versioned integration contract

A provider-neutral, schema-validated message produced by an adapter and consumed by a CareerOps domain boundary.

Provider schemas stop at the adapter. The contract preserves provenance without assigning domain meaning outside the receiving context.

## Job Registry

### Job source

An external or user-controlled origin from which job information is received, such as a company careers page, approved feed, recruiter email, manual form, or browser extension.

### Source adapter

An integration component that communicates with one job source and converts its transport-specific response into an observation request. It does not own normalization, identity resolution, or canonical job state.

### Job observation

A `JobObservation` is immutable evidence received from a job source or capture channel.

The observed fact is immutable:

- Original source payload
- Source identity and external reference
- Original URL
- Payload fingerprint
- Observed timestamp

Processing knowledge about that fact may advance:

- Received
- Normalizing
- Normalized
- Resolving
- Resolved
- Ambiguous
- Failed

A changed source listing creates a new observation revision. It does not modify the previous observation.

### Job normalization

A `JobNormalization` is a versioned interpretation of a `JobObservation`.

It may derive structured fields such as title, company, location, remote policy, employment type, salary, description, and identity signals. A new normalizer version creates a new normalization record. The source observation remains unchanged.

### Job identity resolution

The process of deciding whether a normalized observation represents an existing canonical opportunity, a new opportunity, an ambiguous case, invalid content, or content excluded by policy.

Possible outcomes:

- `matched_existing`
- `created_new`
- `ambiguous`
- `rejected`
- `ignored`

Identity resolution uses source identifiers, canonical URLs, normalized fields, fingerprints, structured signals, thresholds, and human review where required.

It does not assess candidate suitability.

### Job resolution

A `JobResolution` is an append-only identity decision linking an observation and normalization version to an outcome.

A resolution may record:

- Selected or candidate canonical jobs
- Resolution score and evidence
- Algorithm version
- Human decision maker
- The earlier resolution it supersedes

Corrections create a new resolution rather than rewriting the earlier decision.

### Ambiguous resolution

A valid identity-resolution outcome where more than one canonical job is plausible or the available evidence is insufficient for a safe decision.

Ambiguity is not a processing failure. Automatic resolution stops, the observation remains preserved, and further evidence or human review is required.

### Canonical job

A `CanonicalJob` is the workspace's current usable understanding of one job opportunity.

It may be associated with several independent observations and may evolve through controlled enrichment. Each update remains traceable through the canonical version, resolution decision, changed fields, previous and new values, reason, and event schema version.

A canonical job does not replace or own the immutable source evidence.

### Canonical enrichment

A controlled update to a canonical job based on a new observation, manual correction, or approved rule.

Enrichment fills or changes canonical fields according to an explicit precedence policy. It produces a traceable field delta and does not alter the source observation.

## Duplicate Conditions

The word `duplicate` is too broad for system behaviour. CareerOps distinguishes five separate conditions.

### Transport retry

The same client request is submitted again because the original response was lost or the connection failed.

- **Layer:** transport
- **Primary protection:** idempotency key and request fingerprint
- **Outcome:** return the original accepted operation; do not create a second observation

### Envelope replay

The same provider delivery or transport payload is received again after an inbound envelope has already been accepted.

- **Layer:** integration transport
- **Primary protection:** provider delivery identity or envelope fingerprint within the connection or channel
- **Outcome:** reuse the accepted envelope and do not process the same delivery twice

Two distinct envelopes may still translate to the same exact source replay at the Job Registry boundary.

### Exact source replay

The same external listing is received again with the same source identity and content fingerprint.

- **Layer:** source evidence
- **Primary protection:** source identity, external reference, and content hash
- **Outcome:** return or reference the existing observation; do not create another immutable snapshot

### Source revision

The source identity is unchanged but the content fingerprint has changed, for example after a salary, description, location, or deadline update.

- **Layer:** source evidence
- **Outcome:** create a new immutable observation revision and process it independently

### Canonical identity match

Different observations represent the same real job opportunity.

- **Layer:** domain identity
- **Outcome:** preserve each observation independently and resolve them to the same canonical job when the evidence is sufficient

## Candidate and Matching

### Candidate profile

The workspace-scoped record representing the candidate whose evidence, preferences, matches, and applications are being managed.

### Candidate evidence

Attributable information supporting a candidate's experience or knowledge, including CV content, projects, employment history, education, portfolio material, application notes, and interview evidence.

Evidence retains its source, version, and support level. Project evidence is not represented as professional experience.

### Evidence provenance classification

The classification describing what kind of claim an evidence item may support.

CareerOps distinguishes:

- **Professional experience:** work performed in employment or a contracted professional context
- **Project experience:** work demonstrated through a personal, educational, open-source, or portfolio project
- **Education:** formal study, training, or certification
- **Demonstrated knowledge:** implementation, explanation, or assessment evidence that does not imply employment experience
- **User assertion:** a claim supplied by the user without independent supporting evidence
- **Externally verified evidence:** evidence confirmed through an approved external source or verification process

Downstream matching and generation must preserve these distinctions. Project evidence cannot become professional experience, and a user assertion cannot become externally verified evidence.

### Evidence document

A versioned source of candidate evidence, such as a CV, project description, work-history entry, or interview note.

### Evidence chunk

A retrievable section of an evidence document used for precise matching and citation. Chunk-level references make the supporting passage explicit while the parent document remains derivable.

### Job requirement

A structured statement extracted from a canonical job, such as a required skill, preferred skill, responsibility, language, location condition, or experience expectation.

Requirements are versioned against the extraction process that produced them.

### Opportunity matching

The process of comparing candidate evidence with the requirements of a canonical job.

It may produce supported, partially supported, and unsupported requirements together with deterministic score components and traceable explanations.

Opportunity matching does not decide whether two job listings represent the same opportunity.

### Opportunity match

A versioned result of opportunity matching for one candidate profile and canonical job.

The result records the scoring version, total score, component breakdown, and supporting evidence. A later recalculation supersedes rather than silently replaces the earlier result.

## Application Operations

### Application

The workspace-scoped record of a candidate pursuing one canonical job opportunity.

It records the current state for efficient reads while the append-only transition history remains the authoritative record of change.

### Application transition

An immutable event recording a valid move from one application state to another, including the actor, reason, and timestamp.

The current application state and transition event are written in the same transaction.

### Follow-up

A dated action associated with an application, contact, or interview. A follow-up records ownership, due time, completion time, and an optional note.

## Shared Platform Terms

### Workspace

The primary tenant and authorization boundary. Jobs, evidence, applications, integrations, operations, and analytics remain scoped to a workspace unless a later design explicitly introduces a shared projection.

### Workspace membership

The association between a user and workspace, including the user's role and permitted actions.

### Operation

A resource representing the progress and outcome of asynchronous work such as capture, normalization, identity resolution, import, or export.

### Idempotency record

A transport-level record binding a client, principal, idempotency key, and request fingerprint to the original accepted response.

For asynchronous operations, replay returns the original operation reference. The client retrieves the operation for current status.

### Audit event

An append-only record of a security-relevant or business-relevant action, including actor, action, target reference, request identifier, state delta, and metadata.

Audit records may outlive the domain target they describe.

### Outbox event

A versioned event written in the same database transaction as the state change it represents. An outbox dispatcher publishes committed events to asynchronous consumers.

The outbox closes the gap between a successful database commit and durable message publication.
