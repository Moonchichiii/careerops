# Technology Decisions

Technologies are evaluated against a concrete responsibility, consumer, failure mode, and activation point. A tool is not accepted solely because it appears in job descriptions.

## Accepted Direction

| Technology | Responsibility | Real consumer | Activation |
| --- | --- | --- | --- |
| Django | Domain application, ORM, templates, sessions, security primitives | First-party web application | Repository engineering |
| HTMX | Server-driven partial interaction | First-party web application | First real browser journey |
| TypeScript | Browser-specific complexity and typed external clients | Browser extension, selected UI components, and a deferred native client | Asset foundation; extension first |
| Django REST Framework | Versioned external API contracts | Browser extension first; native mobile after the API is proven | First capture API endpoint |
| PostgreSQL | System of record, constraints, search, locking, outbox | All domain contexts | Repository engineering |
| Celery | Durable asynchronous execution | Normalization, resolution, exports, delivery | Capture slice |
| RabbitMQ | Durable task delivery | Celery workers | Capture slice |
| Redis | Cache, rate limits, short-lived coordination | Web and API runtime | When the first concrete use appears |
| Prometheus | Operational metrics and service indicators | Engineering operations | First observable workflow |
| Grafana | Dashboards and alerts | Engineering operations | First observable workflow |
| OpenTelemetry | Trace propagation across requests and tasks | Capture workflow | First asynchronous workflow |
| Docker | Reproducible development and runtime environment | Developers and CI | Repository engineering |
| GitHub Actions | Merge and delivery gates | Repository workflow | Repository engineering |
| uv | Python version, dependencies, lockfile, and execution | Developers and CI | Repository engineering |
| Ruff | Formatting and linting | Developers and CI | Repository engineering |
| mypy and django-stubs | Type completeness | Developers and CI | Repository engineering |
| pytest | Unit and integration tests | Developers and CI | Repository engineering |

## Deferred

| Technology | Reason for deferral | Activation condition |
| --- | --- | --- |
| pgvector | Semantic retrieval is not required for capture or deterministic matching | Retrieval evaluation shows value beyond full-text search |
| Expo and React Native | Native mobile would duplicate delivery work before the external API is proven | Extension capture and operation-status contracts are stable |
| Rust content worker | No measured content-processing bottleneck exists | Python baseline shows a material throughput, memory, latency, or isolation benefit |
| Evidence-grounded generation | Requires trustworthy evidence, deterministic matching, and evaluation data | Matching and retrieval foundations are complete |
| PostHog | No current product question requires behavioural instrumentation | A defined funnel, retention, or experiment decision exists |
| Terraform | No deployment target has been selected | Cloud architecture is accepted |
| Kubernetes and Helm | No orchestration constraint exists | Operational scale or deployment topology justifies it |
| OpenSearch | PostgreSQL search is sufficient for the planned scale | Search requirements exceed measured PostgreSQL capability |
| DuckDB | No analytical export or offline dataset exists | A real Parquet or offline reporting workflow appears |
| dbt | No analytical warehouse or transformation estate exists | A real warehouse modelling workflow appears |

## Rejected for the Initial System

| Option | Reason |
| --- | --- |
| Microservices | Adds deployment, consistency, and operational cost without a proven boundary requiring independent release or scale |
| Kafka | No event volume, replay, or consumer-topology requirement justifies it |
| React SPA for the primary UI | Duplicates server state and business rules where Django templates and HTMX are sufficient |
| JWT for the first-party web application | Secure Django sessions better match the same-origin interface |
| Redis as the Celery broker and authoritative state store | RabbitMQ provides the durable broker role; PostgreSQL remains authoritative |
| Dedicated vector database | PostgreSQL and optional pgvector keep retrieval close to tenant and metadata filtering |
| Generative scoring | Numerical opportunity matching must remain deterministic and inspectable |

## Review Rule

A deferred or rejected technology may be reconsidered when a measurable constraint appears. The decision record must identify the consumer, expected benefit, operational cost, failure impact, and simpler alternatives.
