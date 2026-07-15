# Product Vision

## Table of Contents

- [Vision](#vision)
- [Problem](#problem)
- [Primary Users](#primary-users)
- [Product Boundary](#product-boundary)
- [Core Journeys](#core-journeys)
- [Product Principles](#product-principles)
- [First Implementation Slice](#first-implementation-slice)
- [Non-Goals](#non-goals)
- [Success Criteria](#success-criteria)

## Vision

CareerOps is a job intelligence and application operations platform that helps candidates turn fragmented job-search information into structured, explainable, and actionable evidence.

The product is intended to make the full search process observable: where opportunities came from, how they were interpreted, which evidence supports a candidate's fit, how applications progressed, and which actions produced interviews or offers.

## Problem

Job-search information is usually distributed across job boards, company sites, recruiter messages, CV versions, notes, calendars, and spreadsheets. That fragmentation creates recurring problems:

- The same opportunity is captured several times without a reliable identity model.
- Source changes overwrite previous information or disappear entirely.
- Match scores are difficult to explain or verify.
- Application history and follow-up commitments become incomplete.
- Candidates cannot reliably connect outcomes to sources, evidence, or decisions.

CareerOps addresses those problems by preserving evidence first, applying versioned interpretation second, and keeping later recommendations traceable to their inputs.

## Primary Users

### Individual candidate

A candidate managing opportunities, evidence, applications, interviews, and follow-ups across multiple sources.

### Career coach

A coach supporting candidates with structured evidence, application review, and outcome analysis.

### Training provider

A university, bootcamp, or employment programme supporting participants through application preparation and job-search operations.

The first product scope is optimized for individual candidates while preserving workspace boundaries for later collaboration.

## Product Boundary

CareerOps owns:

- Job-source capture and immutable source evidence
- Versioned normalization
- Canonical job identity
- Candidate evidence
- Deterministic opportunity assessment
- Application state and transition history
- Follow-ups, contacts, and interview records
- Outcome and conversion analysis
- Evidence-grounded explanations and drafting under human review

CareerOps does not own:

- General job-board publishing
- Automated application submission
- Unsupported professional claims
- Uncontrolled scraping
- Recruitment decisions
- Autonomous changes to domain state by generative systems

## Core Journeys

### Capture and canonicalize a job

A candidate captures a role through the first-party interface, browser extension, or bounded CSV import. CareerOps preserves transport provenance, converts the payload into immutable job evidence, distinguishes replay layers from source revisions, normalizes the content, and resolves whether it represents a new, existing, or ambiguous opportunity.

### Evaluate an opportunity

CareerOps compares structured requirements with candidate evidence. The result separates supported, partially supported, and unsupported requirements and keeps scoring deterministic.

### Prepare an application

The candidate selects an appropriate CV version, supporting evidence, notes, contacts, salary expectations, and follow-up date. Generated text remains attributable to evidence and subject to review.

### Track an application

Applications move through controlled states. Each transition is appended to history rather than replacing the record of what happened.

### Learn from outcomes

CareerOps analyses response rate, interview conversion, source performance, time to response, recurring evidence gaps, and application strategy.

## Product Principles

### Evidence before interpretation

Source evidence is preserved before it is normalized, resolved, scored, summarized, or used for generation.

### Deterministic systems own truth

Authorization, identity resolution, application transitions, validation, and numerical scoring remain deterministic. Retrieval and generation may explain or draft; they do not become the system of record.

### Uncertainty is valid

Ambiguous identity, unknown salary, insufficient evidence, and partial support are valid outcomes. The product does not manufacture certainty to complete a workflow.

### History remains traceable

Source observations are immutable. Normalizations, resolution decisions, canonical updates, and generated claims remain attributable to a versioned input and decision.

### Privacy is the default

Candidate evidence, interview notes, applications, and private source material remain scoped to the authorized workspace.

### Technology must be load-bearing

A technology is accepted only when a real workflow, client, failure mode, or operational constraint requires it.

## First Implementation Slice

The first vertical slice is **Capture and Canonicalize**:

1. Accept a capture through the HTMX interface, browser-extension API, or CSV import.
2. Apply transport idempotency and envelope-replay protection.
3. Persist an immutable inbound envelope and provenance.
4. Translate the payload into a versioned CareerOps capture contract.
5. Apply exact source-replay and source-revision rules when accepting job evidence.
6. Persist the immutable job observation and publish committed work through the transactional outbox.
7. Normalize the observation asynchronously.
8. Resolve canonical identity as existing, new, or ambiguous.
9. Expose operation and import status.
10. Emit logs, metrics, and traces for the workflow.

Candidate evidence, opportunity matching, retrieval, generation, and application operations are outside this slice.

## Non-Goals

CareerOps will not initially:

- Operate as a public job marketplace
- Submit applications automatically
- Replace human review of ambiguous identity decisions
- Use a language model as the numerical match-scoring authority
- Introduce microservices without an operational requirement
- Introduce Kafka, Kubernetes, a warehouse, or a dedicated vector database for portfolio value alone
- Rebuild the primary Django interface as a React SPA

## Success Criteria

CareerOps succeeds when it can demonstrate:

- Reliable capture from more than one real client
- Safe handling of retries, replays, revisions, and canonical identity matches
- Explainable opportunity assessment backed by candidate evidence
- Complete application transition history
- Useful outcome analytics based on real workflows
- Production-quality testing, security, observability, and delivery practices
- Documentation that accurately matches the running system
- A codebase whose important decisions can be explained and defended without relying on the documentation itself
