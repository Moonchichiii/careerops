# Architecture Decision Records

Architecture Decision Records capture decisions that have entered implementation or materially constrain it. Planning notes and unresolved options do not become ADRs.

No individual ADRs have been committed yet. The first records will be created during the repository-engineering and capture-slice milestones.

## When an ADR Is Appropriate

Create an ADR when a decision:

- Has meaningful alternatives
- Is costly to reverse
- Affects several modules or operational concerns
- Establishes a long-lived security, data, or integration boundary
- Needs context that cannot be recovered from code alone

Do not create an ADR for routine implementation choices or untested future possibilities.

## Statuses

| Status | Meaning |
| --- | --- |
| Proposed | Under active review |
| Accepted | Current decision |
| Superseded | Replaced by a later ADR |
| Rejected | Considered and not selected |
| Deferred | Waiting for a concrete requirement |

## Template

```markdown
# ADR-NNNN: Decision title

- Status: Proposed
- Date: YYYY-MM-DD

## Context

## Decision

## Alternatives Considered

## Consequences

### Positive

### Negative

### Operational

### Security

## Reversal Strategy

## Related Decisions
```

## Expected Initial Records

The first implementation is likely to require records for:

- Modular monolith and context boundaries
- First-party HTMX interface and external DRF clients
- PostgreSQL as the system of record
- RabbitMQ and Redis responsibilities
- Immutable observations and canonical identity
- Transactional outbox
- Browser security and self-hosted assets

Titles and numbering will be assigned when those decisions are implemented, not before.
