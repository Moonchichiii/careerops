# CareerOps Documentation

This directory contains the product, domain, architecture, engineering, security, and delivery documentation for CareerOps.

The root [README](../README.md) is the project entry point. The documents below are authoritative for their individual concerns.

## Contents

- [Documentation Map](#documentation-map)
- [Source of Truth](#source-of-truth)
- [Status Vocabulary](#status-vocabulary)
- [Recommended Reading Order](#recommended-reading-order)

## Documentation Map

| Area | Document | Purpose |
| --- | --- | --- |
| Product | [Product Vision](product/PRODUCT_VISION.md) | Problem, users, scope, journeys, and non-goals |
| Domain | [Domain Glossary](domain/DOMAIN_GLOSSARY.md) | Authoritative terminology |
| Domain | [Bounded Contexts](domain/BOUNDED_CONTEXTS.md) | Ownership, dependency direction, and rejected boundaries |
| Domain | [Integrations](domain/INTEGRATIONS.md) | Data Bridge contracts, provenance, replay layers, and channel scope |
| Architecture | [Architecture](architecture/ARCHITECTURE.md) | System structure and consistency boundaries |
| Architecture | [Diagrams](architecture/DIAGRAMS.md) | Diagram index and interpretation guide |
| Architecture | [Conceptual ERD](architecture/erd/careerops.dbml) | Conceptual entities and relationships |
| Architecture | [ADR Index](architecture/adr/README.md) | Decision-record process and index |
| Engineering | [Engineering Standards](engineering/ENGINEERING_STANDARDS.md) | Code boundaries, quality gates, and completion criteria |
| Security | [Security Model](security/SECURITY_MODEL.md) | Security boundaries and planned controls |
| Planning | [Roadmap](planning/ROADMAP.md) | Delivery sequence and open decisions |
| Planning | [Technology Decisions](planning/TECHNOLOGY_DECISIONS.md) | Accepted, deferred, and rejected technologies |

## Source of Truth

Each concern has one primary document:

| Concern | Source of truth |
| --- | --- |
| Product boundary | `docs/product/PRODUCT_VISION.md` |
| Terminology | `docs/domain/DOMAIN_GLOSSARY.md` |
| Context ownership | `docs/domain/BOUNDED_CONTEXTS.md` |
| External integration boundary | `docs/domain/INTEGRATIONS.md` |
| System architecture | `docs/architecture/ARCHITECTURE.md` |
| Conceptual data model | `docs/architecture/erd/careerops.dbml` |
| Engineering rules | `docs/engineering/ENGINEERING_STANDARDS.md` |
| Security boundaries | `docs/security/SECURITY_MODEL.md` |
| Delivery order | `docs/planning/ROADMAP.md` |
| Technology status | `docs/planning/TECHNOLOGY_DECISIONS.md` |

The root README summarizes and links to these documents. It does not replace them.

## Status Vocabulary

| Status | Meaning |
| --- | --- |
| Accepted | The design decision is current and may guide implementation |
| Planned | The capability is intended but not implemented |
| Deferred | The decision waits for a concrete consumer or constraint |
| Rejected | The option was considered and is not part of the current design |
| Implemented | The capability exists in the repository |
| Verified | The implementation has passed its defined checks |

## Recommended Reading Order

1. [Product Vision](product/PRODUCT_VISION.md)
2. [Domain Glossary](domain/DOMAIN_GLOSSARY.md)
3. [Bounded Contexts](domain/BOUNDED_CONTEXTS.md)
4. [Integrations](domain/INTEGRATIONS.md)
5. [Architecture](architecture/ARCHITECTURE.md)
6. [Conceptual ERD](architecture/erd/careerops.dbml)
7. [Engineering Standards](engineering/ENGINEERING_STANDARDS.md)
8. [Security Model](security/SECURITY_MODEL.md)
9. [Roadmap](planning/ROADMAP.md)

[Back to project README](../README.md)
