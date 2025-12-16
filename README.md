# LangSmith Self-Hosted on AWS — Reference Architecture (P0)

**Status:** P0 Enablement Baseline  
**Audience:** Platform / Infra / MLOps Engineers  
**Goal:** Provide a single, opinionated, supportable path to deploying and operating LangSmith Self-Hosted (SH) on AWS with minimal support intervention.

This document defines the **reference architecture LangChain Enablement stands behind**.  
Alternative approaches may work, but are **out of scope for P0 enablement and future certification**.

---

## 1. What This Architecture Is (and Is Not)

### This *is*:
- A production-capable **baseline deployment**
- Opinionated by design
- Built on **AWS + EKS + Terraform + Helm**
- Designed to surface real operator responsibilities early
- The foundation for future labs and certification

### This is *not*:
- A performance benchmark
- A multi-region or HA architecture
- A guide for custom service meshes or bespoke gateways
- A promise of security guarantees

---

## 2. Deployment Mode

**P0 Default: Full Self-Hosted**

- Control plane and data plane both run in the customer AWS account
- Customer is responsible for:
  - Network exposure
  - Authentication
  - Data persistence
  - Upgrades and backups

> Hybrid (SaaS control plane + SH data plane) is valid but **out of scope for P0 enablement**.

---

## 3. High-Level Architecture

Request flow (top to bottom):

![Request Flow Diagram](diagrams/RequestFlow.png)

Users / CI / SDKs  
→ Route53  
→ Application Load Balancer (ALB) + WAF  
→ Kubernetes Ingress (EKS)  
→ LangSmith application services  

Persistent dependencies:

- PostgreSQL — metadata (projects, orgs, users)
- Redis — cache and job queues
- ClickHouse — traces and analytics
- S3 — large artifacts and payload storage


**Flow Summary**
- Traffic enters via **Route53 → ALB** (with optional WAF).
- ALB forwards to **Kubernetes ingress** inside EKS.
- LangSmith application services run in EKS.
- Persistent state is handled by:
  - **PostgreSQL** (metadata)
  - **Redis** (cache / queues)
  - **ClickHouse** (traces & analytics)
  - **S3** (large artifacts and payloads)

This diagram represents the **minimum supported topology** for the P0 reference architecture.

---

## 4. Network & Ingress

### VPC
- Single VPC
- **Public subnets**: ALB only
- **Private subnets**:
  - EKS worker nodes
  - Data services (RDS, Redis, ClickHouse if in-cluster)

### Ingress
- **Application Load Balancer (ALB)**
- **AWS WAF strongly recommended**
- TLS termination at ALB (end-to-end TLS recommended)
- Optionally:
  - Internal ALB + VPN / PrivateLink for non-public access

### Egress
- Outbound HTTPS access to required LangChain endpoints (if applicable)
- Restrict egress access per organizational policy requirements

---

## 5. Compute: Kubernetes (EKS)

### Cluster
- **Amazon EKS**
- Managed node groups
- Cluster Autoscaler enabled
- Metrics Server enabled

### Baseline Capacity
- Minimum cluster capacity:
  - **16 vCPU / 64 GB RAM** available
- This includes LangSmith services + system overhead

---

## 6. Data Stores

LangSmith SH relies on three core data stores.

### PostgreSQL (Metadata)
- **AWS RDS PostgreSQL or Aurora PostgreSQL**
- PostgreSQL **14+**
- Single AZ for P0 (HA is P1)
- Automated backups enabled

### Redis (Cache / Queues)
- **AWS ElastiCache (Redis OSS)**
- Single node acceptable for P0
- Persistence optional but recommended

## ClickHouse (Traces & Analytics)

ClickHouse is **memory-, I/O-, and concurrency-intensive**. Proper sizing and topology are mandatory for production stability.

### Production Requirements (P0 – Baseline)

**Topology**
- **Minimum of 2 ClickHouse read nodes (replicas) is required for production**
- Single-node ClickHouse is **not supported for production workloads**
- Read and write concurrency must be able to scale independently

**Compute**
- 8 vCPU
- 32 GB RAM

**Storage**
- SSD-backed persistent storage
- ~7000 IOPS
- ~1000 MiB/s throughput

> ⚠️ CPU and memory alone are not sufficient indicators of health. Query concurrency and disk I/O are often the first bottlenecks.

---

### Suitable for Dev-Only

- 4 vCPU / 16 GB RAM
- Single ClickHouse node
- **Non-production proof-of-concept only**

---

### Blob Storage (Strongly Advised)

Blob storage is **strongly advised** for any production deployment that meets **either** of the following conditions:

- **More than ~10 active tenants**
- **Any of the workload triggers below**

#### Workload Triggers
Enable blob storage if **any** of the following are observed or expected:

- Peak concurrent ClickHouse queries consistently **> 100** (or spikes > 200)
- P95 query latency **> 2 seconds** for trace or run retrieval queries
- P95 ingestion delay (`received_at → inserted_at`) **> 60 seconds**
- One or more tenants producing **large or verbose traces** (e.g., large tool outputs, attachments, or deeply nested spans)

> Without blob storage, large trace payloads are stored inline in ClickHouse. This increases part counts, merge pressure, and read amplification, which can lead to query concurrency collapse and severe trace visibility delays.

---

### Scaling Guidance (P1)

Scale ClickHouse to **16 vCPU / 64 GB RAM** and/or additional replicas when:

- Trace ingestion volume grows
- Concurrent query count increases
- Query latency trends upward
- Insert lag begins to drift

> Scaling ClickHouse without blob storage has diminishing returns at higher write and concurrency levels.

---

## 7. Object Storage

### S3 (Strongly Recommended)
- Store large trace artifacts and payloads
- Reduces DB size and blast radius
- Improves security posture for sensitive inputs/outputs

### Access Pattern
- Use **IAM Roles for Service Accounts (IRSA)** where possible
- No static credentials in Helm values

---

## 8. Secrets & Identity

### Secrets
- **AWS Secrets Manager** (preferred)
- Inject into Kubernetes via:
  - External Secrets
  - CSI driver
  - Secure environment injection

### Identity & Auth
- LangSmith authentication must be configured explicitly
- Supported patterns include:
  - Token-based authentication
  - OIDC / SSO (at least one concrete example recommended for enablement)

> For P0 enablement, select **one authentication pattern** to focus on. Additional patterns may be explored in future enablement tracks.

---

## 9. Observability (Platform-Level)

Minimum required:
- Application logs accessible via CloudWatch
- Kubernetes events visible
- Health endpoints monitored

Optional (P1):
- Prometheus / OpenTelemetry exporters
- Alerting on:
  - Pod restarts
  - DB connectivity
  - Ingestion failures

---

## 10. Security Baseline (Non-Negotiable)

This reference architecture requires **essential security controls** as a baseline.

### MUST
- TLS enabled
- No plaintext secrets
- Least-privilege IAM
- Network isolation (private subnets for data services)
- WAF or equivalent rate limiting at ingress

### SHOULD
- Private access only (VPN / PrivateLink)
- Auth required for all UI and API access
- Regular patching and upgrades

### Explicit Disclaimer
> This reference architecture does **not** guarantee security.  
> Customers are responsible for reviewing and approving deployments with their security teams.

---

## 11. What This Architecture Explicitly Excludes

These are **out of scope for P0 enablement**:
- Multi-region active/active
- Custom gateways or service meshes
- HA ClickHouse clusters
- Custom scaling policies beyond autoscaler defaults
- Performance benchmarking beyond sanity checks

These may appear in P1/P2 enablement or certification tracks.

---

## 12. Why This Exists

This reference architecture exists to:
- Reduce installation failures and complexity
- Provide support teams with a shared baseline
- Create a clear, well-documented enablement path
- Serve as the foundation for:
  - Hands-on labs
  - Operator certification
  - Support playbooks

If you encounter challenges during implementation, these often indicate areas where additional attention or configuration is needed, rather than system defects.

---

## 13. Next Artifacts (Planned)

- Preflight checklist
- Deployment walkthrough
- Known sharp edges
- Failure-mode diagnostics
- Operator mental model

These resources build **on top of this foundation**, providing additional guidance and support as you progress.
