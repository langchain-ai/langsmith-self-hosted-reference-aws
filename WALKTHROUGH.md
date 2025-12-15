# LangSmith Self-Hosted on AWS — Deployment Walkthrough (P0)

**Goal:** Get from zero → running LangSmith SH → first successful trace → basic health validation.  
**Assumption:** You passed [`PREFLIGHT.md`](./PREFLIGHT.md). If not, stop and do that first.

This walkthrough is intentionally opinionated and linear. Following it step-by-step ensures you stay on the reference path and can receive full support.

---

## 0. Inputs You Must Decide Up Front

Pick these *before* you touch Terraform:

- **AWS Region:** `us-west-2` (example — pick one and stick to it)
- **Environment name:** `dev` / `staging` / `prod` (do not share resources across envs)
- **DNS name:** `langsmith.<your-domain>`
- **Exposure model:** Public (ALB) or Private-only (VPN/PrivateLink)
- **Auth model:** Token-based (P0) or OIDC/SSO (P1 unless already standard internally)
- **Data store model:**
  - Postgres: RDS/Aurora (recommended)
  - Redis: ElastiCache (recommended)
  - ClickHouse: Externally managed (preferred) or in-cluster (allowed)

Write these in a `deploy/ENV.md` file for your own sanity.

---

## 1. Clone Repos and Pin Versions

You are building an enablement path. That means **pinning** matters.

- Clone:
  - `https://github.com/langchain-ai/terraform`
  - `https://github.com/langchain-ai/helm`
- Record:
  - Terraform repo commit SHA
  - Helm repo commit SHA or chart version
- Do not “float” versions for the reference deployment.

> Reproducibility is essential for effective enablement. If you cannot reproduce a deployment later, the enablement process has not been fully captured.

---

## 2. Terraform: Provision AWS Infrastructure

### 2.1 Configure Terraform State
- Use S3 backend + DynamoDB lock (recommended).
- Ensure state is **unique per environment**.

### 2.2 Apply Infrastructure
Provision (at minimum):
- VPC + subnets (public for ALB, private for nodes/data)
- EKS cluster + managed node groups
- RDS Postgres (14+)
- ElastiCache Redis
- S3 bucket for artifacts
- Security groups and IAM roles/policies
- (Optional) Route53 hosted zone / record scaffolding

**Hard requirement:** Ensure the EKS node groups provide at least:
- **16 vCPU / 64GB RAM** allocatable capacity total
- **ClickHouse capacity** if in-cluster:
  - One node with **8 vCPU / 32GB RAM** allocatable

### 2.3 Terraform Verification Gates (Stop if any fail)
- [ ] `aws eks describe-cluster` shows `ACTIVE`
- [ ] Worker nodes in private subnets can reach the internet (NAT)
- [ ] RDS reachable from EKS subnets/security groups
- [ ] Redis reachable from EKS subnets/security groups
- [ ] S3 bucket exists and IAM access path is defined (IRSA preferred)

---

## 3. Kubernetes: Connect and Validate the Cluster

### 3.1 Connect to the Cluster
- Update kubeconfig:
  - `aws eks update-kubeconfig --region <REGION> --name <CLUSTER_NAME>`
- Confirm:
  - `kubectl get nodes`

### 3.2 Install/Validate Required Add-ons
You must have:
- Metrics Server
- Cluster Autoscaler

Verification:
- `kubectl top nodes` returns metrics
- Autoscaler is running and has permissions

### 3.3 Create a Namespace
Create a dedicated namespace, e.g.:
- `langsmith`

## 3.4 Ingress Gate — Prove ALB Works Before Installing LangSmith

Complete this validation **before** Helm-installing LangSmith. Many deployment issues initially attributed to LangSmith are actually ingress, controller, or subnet-tagging configuration problems.

### 3.4.1 Deploy a tiny test app
Deploy any minimal HTTP echo service into a test namespace (or the `langsmith` namespace). Confirm:
- `kubectl get pods` shows it running
- `kubectl get svc` shows endpoints

### 3.4.2 Create a test Ingress that provisions an ALB
Create an Ingress pointing at the test service.

Your success criteria are binary:
- [ ] An **ALB** is created
- [ ] A target group is created
- [ ] Targets become **healthy**
- [ ] You can hit the endpoint and get a response over **HTTPS**

### 3.4.3 If this fails, stop
Do not proceed to LangSmith until this gate passes.

When it fails, the first places to look are:
- Kubernetes events on the Ingress
- AWS Load Balancer Controller logs
- ALB target group health reasons in the AWS console

> If you are not using ALB for ingress, you are operating outside the P0 reference path.

---

## 4. Prepare Dependencies and Secrets

### 4.1 Collect Required Connection Info
You need:
- Postgres host/port/db/user/password
- Redis host/port (and auth if enabled)
- ClickHouse endpoint/user/password (or in-cluster config)
- S3 bucket name and region

### 4.2 Store Secrets (Do Not Put in Git)
Preferred: AWS Secrets Manager + External Secrets integration.

At minimum for P0 enablement:
- Keep secrets out of repo
- Inject into Kubernetes securely (ExternalSecrets/CSI/secure env)

**Stop condition:** Never commit passwords or secrets into `values.yaml` or version control. Use a secrets management solution instead.

---

## 5. Helm: Install LangSmith

### 5.1 Choose the Values Strategy
You should have:
- `values.yaml` (non-secret config)
- `secrets.yaml` OR external secrets (secret values only, not committed)

### 5.2 Configure Required Values
Your Helm values must define:
- External Postgres connection
- External Redis connection
- ClickHouse configuration (external or in-cluster)
- S3 artifact storage (strongly recommended)
- Ingress configuration (ALB + TLS)

### 5.3 Install/Upgrade
- Install the chart into the `langsmith` namespace.
- Use `helm upgrade --install` (idempotent).

### 5.4 Helm Verification Gates (Stop if any fail)
- [ ] All pods in `langsmith` namespace reach `Running` or expected steady state
- [ ] No CrashLoopBackOff
- [ ] Services have endpoints
- [ ] Ingress is created and gets an ALB hostname/address

Commands you should run (conceptually):
- `kubectl get pods -n langsmith`
- `kubectl describe pod <...> -n langsmith`
- `kubectl get svc -n langsmith`
- `kubectl get ingress -n langsmith` (or equivalent ingress resource)

---

## 6. Ingress + DNS: Make It Reachable

### 6.1 TLS
- Ensure the ALB listener is HTTPS
- Ensure cert is valid (ACM recommended)

### 6.2 DNS
- Create a Route53 record:
  - `langsmith.<domain>` → ALB DNS name

### 6.3 Reachability Gate
- [ ] You can load the LangSmith UI at `https://langsmith.<domain>`
- [ ] Auth behaves as intended (token login or SSO)

---

## 7. “First Successful Trace” (The Real Success Condition)

A deployment is not “done” until traces flow.

### 7.1 Create an API Key / Token (if applicable)
- Create the token per your configured auth model.
- Store it securely.

### 7.2 Send a Minimal Trace
From a laptop or CI runner with egress to the endpoint:
- Configure `LANGSMITH_ENDPOINT`
- Configure auth (`LANGSMITH_API_KEY` or equivalent)
- Run a minimal trace-producing script (LangChain example or direct API).

### 7.3 Trace Gate (Stop if fails)
- [ ] A trace appears in the LangSmith UI
- [ ] Trace includes at least one run/span
- [ ] No ingestion errors in logs

If this fails, do not proceed to operational tasks. Fix ingestion first to ensure the system is functioning correctly.

---

## 8. Basic Health Validation (P0 Ops Readiness)

### 8.1 What “Healthy” Means (Minimum)
- UI loads reliably
- API responds
- DB connections stable
- No sustained error logs
- ClickHouse writes succeed
- Redis queues not stuck

### 8.2 Validate Logs
Check:
- LangSmith app logs for errors
- ClickHouse logs for disk/memory pressure
- Ingress/ALB logs (4xx/5xx spikes)

### 8.3 Validate Resource Pressure
- `kubectl top pods -n langsmith`
- Look for:
  - OOMKills
  - CPU throttling
  - Persistent volume saturation

---

## 9. Backup & Restore (P0 Expectations)

For P0 enablement, you must at least:
- Confirm RDS backups are enabled
- Confirm ClickHouse persistence strategy is defined
- Confirm S3 bucket lifecycle/versioning policy is intentional

You do not need to execute a restore yet, but you must document how it would be done.

---

## 10. Common Failure Points (Fast Triage)

If deployment fails, the usual culprits are:

1. **Networking / Security Groups**
   - EKS can’t reach Postgres/Redis/ClickHouse
2. **ClickHouse undersized or slow disk**
   - OOM, high latency, ingestion failures
3. **Ingress misconfiguration**
   - ALB created but no healthy targets
4. **Auth mismatch**
   - UI loads but API calls fail
5. **Secrets handling**
   - Bad credentials injected, pods loop

When something breaks: capture
- `kubectl describe`
- pod logs
- DB connection test results
- ALB target health

This data becomes your failure-mode catalog later.

---

## 11. “Done” Definition (P0)

You are done only when:

- [ ] Terraform applied cleanly and is reproducible
- [ ] Helm install is idempotent (`upgrade --install` works)
- [ ] UI reachable via HTTPS on your chosen DNS
- [ ] First successful trace appears in the UI
- [ ] Basic health checks are green (no crash loops, stable DB connectivity)

If any box isn't checked, continue working through the checklist until all items are complete to ensure a fully functional reference deployment.

---

## Appendix: What to Capture During Your First Real Deployment

As you run this the first time, log:
- Where you hesitated
- What you had to guess
- What you looked up
- What failed and how you fixed it

Those are the inputs for:
- `TROUBLESHOOTING.md`
- “Top failure modes”
- Future certification labs
