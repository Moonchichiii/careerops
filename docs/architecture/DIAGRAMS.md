# Architecture Diagrams

The Mermaid sources in `docs/architecture/diagrams/` are the canonical editable diagrams. The v1 conceptual data model is maintained in DBML at `docs/architecture/erd/careerops.dbml`. Data Bridge persistence is reserved for a reviewed v2 revision.

Each diagram answers one architectural question. Detailed behaviour belongs in the corresponding domain or architecture document rather than in diagram annotations.

## Diagram Index

| Source | Architectural question |
| --- | --- |
| [system-context.mmd](diagrams/system-context.mmd) | Who interacts with CareerOps, and which runtime dependencies and external systems surround it? |
| [bounded-context-map.mmd](diagrams/bounded-context-map.mmd) | Which context owns each responsibility, and in which direction do dependencies flow? |
| [capture-sequence.mmd](diagrams/capture-sequence.mmd) | How does a capture request become an immutable inbound envelope, a job observation, and a completed identity-resolution operation? |
| [observation-state.mmd](diagrams/observation-state.mmd) | Which processing states may a job observation enter? |
| [resolution-state.mmd](diagrams/resolution-state.mmd) | How are append-only identity decisions created and superseded? |
| [resolution-transaction.mmd](diagrams/resolution-transaction.mmd) | What belongs inside the atomic resolution transaction, and what occurs after commit? |
| [application-state.mmd](diagrams/application-state.mmd) | Which application state transitions are valid? |
| [future-rag-boundary.mmd](diagrams/future-rag-boundary.mmd) | Where may evidence-grounded generation assist, and which decisions remain deterministic? |
| [careerops.dbml](erd/careerops.dbml) | Which conceptual entities, relationships, and ownership boundaries support the system? |

## Conventions

- Solid arrows represent synchronous calls or direct dependency.
- Dashed arrows represent events, telemetry, planned paths, or policy boundaries.
- Subgraphs group contexts or execution boundaries, not deployment units.
- Labels ending in `— planned` describe accepted direction that is not implemented.
- Domain entity names use the vocabulary from the [Domain Glossary](../domain/DOMAIN_GLOSSARY.md).

## Diagram Roles

### System context

Use for external boundaries and runtime shape. It does not describe internal class or table design.

### Bounded-context map

Use for ownership and dependency direction. It does not imply microservices.

### Capture sequence

Use for request, transaction, outbox, worker, and operation-status ordering.

### Lifecycle diagrams

Use for valid state transitions. They are normative for transition rules but do not replace service-level validation.

### Resolution transaction

Use for the system's most important consistency boundary: separate aggregates coordinated atomically, with all non-critical work deferred until after commit.

### Future retrieval and generation boundary

Use to show that retrieval and generation remain advisory. Authorization, identity resolution, application transitions, numerical scoring, and direct domain writes remain deterministic.

## Validation

The Mermaid sources have been reviewed for structure and consistency. Final rendering must be confirmed in GitHub after the files are committed because renderer versions and Markdown integration can differ.

The DBML file is parser-validated. Database-specific indexes, constraints, and migration behavior remain implementation concerns.
