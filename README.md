# Deploy RHOAI 3.4 + Models-as-a-Service (MaaS) on a fresh OCP 4.20 cluster

End-to-end `oc` walkthrough to stand up Red Hat OpenShift AI 3.4 and
Models-as-a-Service on a clean OpenShift 4.20 cluster, then publish models
(generative via llm-d, embeddings via vLLM), govern them with
subscriptions/quotas, and enable the observability dashboard.

Reference: *Govern LLM access with Models-as-a-Service → Deploy and manage
Models-as-a-Service* (OpenShift AI 3.4 docs).

## Assumptions / starting point

- **OpenShift 4.20** (4.19.9+), cluster-admin, `oc` installed.
- **NVIDIA GPU Operator + NFD already installed** (this guide does not cover
  them). GPU nodes here carry the taint `nvidia.com/gpu=NVIDIA-L40S-PRIVATE:NoSchedule`,
  so model pods need a matching toleration (handled in the model manifests).
- A functional ingress controller with a valid default wildcard cert. Find its
  secret name with:
  ```bash
  oc get ingresscontroller default -n openshift-ingress-operator \
    -o jsonpath='{.spec.defaultCertificate.name}{"\n"}'   # e.g. cert-manager-ingress-cert
  ```

> **Per-cluster values to edit before applying:** the apps domain in
> `maas-gateway.yaml` (the `hostname:`), the default cert secret name if it
> differs, and the PostgreSQL password in `postgres-deployment.yaml` +
> `maas-db-config-secret.yaml` (must match).

## Ordering dependency (important)

The DSC `modelsAsService` component will **not** become Ready until three things
exist, and it reports exactly which are missing in its status:

1. `maas-default-gateway` Gateway in `openshift-ingress`
2. `maas-db-config` Secret in `redhat-ods-applications` (created after the DSC
   makes that namespace)
3. Authorino TLS enabled

So the flow is: install operators → Kuadrant CR → **apply the DSC** (it starts
reconciling and creates `redhat-ods-applications`, then waits) → create the
gateway, DB secret, and Authorino TLS to unblock it.

> **Restart the Kuadrant operator after the DSC settles.** The Connectivity Link
> (Kuadrant) operator is installed early, but its required dependencies —
> Service Mesh 3 (Istio, the Gateway API provider) and the Limitador operator —
> are installed later by the RHOAI DSC reconcile. The Kuadrant operator caches
> "dependencies missing" at startup, so its AuthPolicy / TokenRateLimitPolicy
> CRs never get **Enforced** and **models are served with no auth (HTTP 200
> without a key)**. After the DSC is Ready, restart it (see Phase 5 / Troubleshooting).

---

## Files

Foundation (cluster-setup/, apply in order):

| File | Purpose |
|------|---------|
| `cluster-setup/01-user-workload-monitoring.yaml` | Enables User Workload Monitoring (required, else MaaS is Degraded) |
| `cluster-setup/02-rhoai-operator.yaml` | RHOAI operator, channel `stable-3.4` (`redhat-ods-operator` ns) |
| `cluster-setup/03-connectivity-link-operator.yaml` | Red Hat Connectivity Link / Kuadrant operator (`rhcl-operator`) |
| `cluster-setup/04-kuadrant.yaml` | Kuadrant CR (Authorino + Limitador) with observability enabled |
| `cluster-setup/05-datasciencecluster.yaml` | DataScienceCluster: kserve + modelsAsService + dashboard + llamastack |

MaaS configuration (root):

| File | Purpose |
|------|---------|
| `maas-gateway.yaml` | `maas-default-gateway` + a `maas-gateway-class` GatewayClass |
| `postgres-deployment.yaml` | Self-managed PostgreSQL 16 (API-key store) |
| `maas-db-config-secret.yaml` | `maas-db-config` secret with the PostgreSQL `DB_CONNECTION_URL` |
| `configure-maas-tls.sh` | Configures TLS between Authorino and the MaaS gateway |
| `cluster-observability-operator.yaml` | Cluster Observability Operator (in its own namespace — see note) |
| `opentelemetry-operator.yaml` | Red Hat OpenTelemetry operator (required by the ODH monitoring service) |
| `dsci-metrics-storage-patch.yaml` | Sets `metrics.storage` in DSCInitialization to provision the monitoring stack |
| `qwen-3-llminferenceservice.yaml` | Example generative model (llm-d) with GPU toleration |
| `maas-subscription.yaml` | Example subscription + authorization policy |
| `embeddings/` | Serving an **embedding** model via plain vLLM (llm-d can't route `/v1/embeddings`) — see `embeddings/README.md` |

---

## Phase 1 — Cluster foundation

### 1. User Workload Monitoring + operators

```bash
oc apply -f cluster-setup/01-user-workload-monitoring.yaml
oc apply -f cluster-setup/02-rhoai-operator.yaml
oc apply -f cluster-setup/03-connectivity-link-operator.yaml
```

Wait for both operators to reach `Succeeded` (approve InstallPlans if the cluster
defaults to manual approval):

```bash
oc get csv -n redhat-ods-operator | grep rhods-operator
oc get csv -n openshift-operators | grep -i rhcl
```

### 2. Kuadrant CR

```bash
oc apply -f cluster-setup/04-kuadrant.yaml      # creates kuadrant-system, deploys Authorino + Limitador
```

### 3. DataScienceCluster

The RHOAI operator auto-creates a `default-dsci` (DSCInitialization). Apply the DSC:

```bash
oc apply -f cluster-setup/05-datasciencecluster.yaml
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}'
```

It will sit at `Not Ready` with `ModelsAsServiceReady=False` until the gateway,
DB secret, and Authorino TLS are in place (Phase 2). That's expected.

---

## Phase 2 — MaaS prerequisites (unblock the DSC)

### 4. MaaS gateway

```bash
oc apply -f maas-gateway.yaml      # edit hostname/cert secret first
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='Programmed={.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

> If a GatewayClass with controller `openshift.io/gateway-controller/v1` already
> exists (e.g. `openshift-default` or `data-science-gateway-class`), you can
> reference it and drop the GatewayClass block from the manifest.

### 5. PostgreSQL + database secret

```bash
oc apply -f postgres-deployment.yaml      # set the password first
# redhat-ods-applications now exists (created by the DSC); create the secret there:
oc apply -f maas-db-config-secret.yaml
oc get secret maas-db-config -n redhat-ods-applications
```

`maas-db-config-secret.yaml` uses `sslmode=disable` (the in-cluster image has no
TLS); use `sslmode=require` for an external/TLS-fronted database.

### 6. Authorino TLS

```bash
bash configure-maas-tls.sh
oc rollout status deployment/authorino -n kuadrant-system
```

### 7. Confirm MaaS is Ready

```bash
oc get datasciencecluster default-dsc \
  -o jsonpath='ModelsAsServiceReady={.status.conditions[?(@.type=="ModelsAsServiceReady")].status}{"\n"}'
oc get deploy maas-api -n redhat-ods-applications
oc get tenants.maas.opendatahub.io -n models-as-a-service   # default-tenant -> READY True
```

---

## Phase 3 — Dashboard flags

```bash
oc patch OdhDashboardConfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec":{"dashboardConfig":{
    "modelAsService": true,
    "maasAuthPolicies": true,
    "genAiStudio": true,
    "observabilityDashboard": true,
    "vLLMDeploymentOnMaaS": true
  }}}'
```

- `modelAsService` — MaaS publishing in the deploy wizard
- `maasAuthPolicies` — MaaS admin (Subscriptions/Authorization policies) pages
- `genAiStudio` — Gen AI Studio (needs `llamastackoperator: Managed`)
- `observabilityDashboard` — the Observe & Monitor dashboard
- `vLLMDeploymentOnMaaS` — Tech Preview vLLM runtime option (needed for embeddings)

---

## Phase 4 — Observability (Observe & Monitor dashboard)

The dashboard's observability page needs a monitoring backend. Dependency chain:

```bash
# 4a. Cluster Observability Operator — MUST be in its own namespace (see note)
oc apply -f cluster-observability-operator.yaml
# 4b. Red Hat OpenTelemetry operator (the ODH monitoring service requires it)
oc apply -f opentelemetry-operator.yaml
# (approve InstallPlans if manual; wait for both CSVs to Succeed)

# 4c. Provision the monitoring stack
oc patch dscinitialization default-dsci --type=merge --patch-file dsci-metrics-storage-patch.yaml

# 4d. Tenant telemetry (Kuadrant observability is already on from the Kuadrant CR)
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service --type=merge -p '{
  "spec":{"telemetry":{"enabled":true,"metrics":{"captureOrganization":true,"captureUser":false,"captureGroup":false,"captureModelUsage":true}}}}'
```

> **COO namespace matters.** `cluster-observability-operator.yaml` installs COO
> into `openshift-cluster-observability-operator`. Its perses-operator generates
> a NetworkPolicy that only allows the Perses API from that exact namespace —
> installing COO into `openshift-operators` leaves the Observability dashboard
> showing **"No dashboards found"** even though the pods are healthy.

Verify:

```bash
oc get monitoring default-monitoring -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get pods -n redhat-ods-monitoring        # Perses, Prometheus, Thanos, OTel collector, Alertmanager
oc get persesdashboard -A                   # each should be Available=True
```

---

## Phase 5 — Deploy models, subscriptions, and test

- **Generative model (llm-d):** `qwen-3-llminferenceservice.yaml` — deploy as a
  Generative AI model via llm-d (GPU toleration included). Each replica needs a GPU.
- **Subscription + auth policy:** `maas-subscription.yaml` — quota + gateway
  access (both required to consume a model).
- **Embedding model (vLLM):** see `embeddings/` — llm-d can't route
  `/v1/embeddings`; deploy plain vLLM (no `router.scheduler`, `--runner pooling`).

```bash
oc apply -f qwen-3-llminferenceservice.yaml
oc apply -f maas-subscription.yaml
```

**Then restart the Kuadrant operator** so it picks up Service Mesh + Limitador and
actually enforces the generated policies (otherwise the model is open — 200 with
no key, and the subscription/auth-policy show `Degraded`):

```bash
oc delete pod -n openshift-operators -l control-plane=controller-manager   # restarts kuadrant/limitador operators
# wait for: kuadrant Ready=True and the AuthPolicy Enforced=True
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get maassubscription,maasauthpolicy -n models-as-a-service     # both -> Active
```

```bash
# create an API key from the dashboard, then:
BASE="https://maas.apps.<domain>/demo-llm/qwen-3"
curl -sS -H "Authorization: Bearer <API_KEY>" -H "Content-Type: application/json" \
  "$BASE/v1/chat/completions" \
  -d '{"model":"qwen-3","messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

Access control behaves as: invalid key → **403**, missing/malformed auth → **401**,
token budget exhausted → **429** (all enforced at the gateway before the model runs).
Verified on this cluster: `no key → 401`, `invalid key → 403` once the Kuadrant
operator was restarted (see below).

---

## Troubleshooting

- **DSC stuck `ModelsAsServiceReady=False`** — read its message; it names exactly
  what's missing (gateway / `maas-db-config` secret / Authorino TLS). Create them.
- **Model served with no auth (200 without a key); subscription/auth-policy
  `Degraded`** — the Kuadrant operator started before its deps (Service Mesh 3 /
  Istio + Limitador operator) were installed by the DSC, so it cached
  `MissingDependency` and never enforced its AuthPolicy/TokenRateLimitPolicy.
  Restart it (deps are already present):
  ```bash
  oc delete pod -n openshift-operators -l control-plane=controller-manager
  # Kuadrant -> Ready=True, AuthPolicy -> Enforced=True, model -> 401/403 without a valid key
  ```
- **Observability "Service Unavailable"** — monitoring backend not installed
  (Phase 4: COO + OTel + `metrics.storage`).
- **Observability "No dashboards found"** — COO installed in the wrong namespace
  (must be `openshift-cluster-observability-operator`).
- **MaaS usage dashboard stuck (Perses HTTP 500)** — a corrupt Perses project
  file makes `GET /api/v1/projects` 500. Fix inside the Perses pod:
  ```bash
  oc exec -n redhat-ods-monitoring data-science-perses-0 -- sh -c \
    'head -n 9 /perses/projects/redhat-ods-applications.yaml > /tmp/f && \
     cp /tmp/f /perses/projects/redhat-ods-applications.yaml'
  ```
- **Model pods `Pending` — untolerated GPU taint** — add the `nvidia.com/gpu`
  toleration (in the model manifests).
- **LLMInferenceService `GatewayPreconditionNotMet` ("AuthPolicy CRD not
  available")** even though Kuadrant is installed — KServe controllers cached CRD
  discovery before the CRD existed; restart them:
  ```bash
  oc rollout restart deployment/llmisvc-controller-manager -n redhat-ods-applications
  oc rollout restart deployment/kserve-controller-manager  -n redhat-ods-applications
  ```
- **kube:admin can't see a subscription when creating an API key** — kube:admin's
  token groups are fixed to `[system:cluster-admins, system:authenticated]` and it
  ignores OpenShift `Group` membership. Add `system:cluster-admins` to the
  subscription + auth policy, or use a real OpenShift/OIDC user.

---

## Verified state on this cluster (OCP 4.20.23)

| Component | State |
|-----------|-------|
| RHOAI 3.4 operator + Connectivity Link | Installed (Succeeded) |
| DataScienceCluster `default-dsc` | Ready |
| Kuadrant (Authorino + Limitador) | Deployed, observability enabled |
| `maas-default-gateway` | Programmed |
| PostgreSQL + `maas-db-config` | Running / created |
| Authorino TLS | Enabled |
| `maas-api` + Tenant `default-tenant` | 1/1 / Ready (Reconciled) |
| Dashboard flags | modelAsService, maasAuthPolicies, genAiStudio, observabilityDashboard, vLLMDeploymentOnMaaS |
| COO + OpenTelemetry + metrics storage | Installed |
| `default-monitoring` MonitoringStack | Ready — 9/9 pods Running |
| Example model `qwen-3` (llm-d) | Ready — 2 replicas on GPU nodes |
| Subscription `test-sub` + policy `test-sub-policy` | Active (after Kuadrant operator restart) |
| Gateway auth enforcement | Verified — no key → 401, invalid key → 403 |
