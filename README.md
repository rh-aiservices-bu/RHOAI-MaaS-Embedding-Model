# Models-as-a-Service (MaaS) Setup — OpenShift AI 3.4

Configuration manifests and steps for deploying and enabling Models-as-a-Service
(MaaS) on Red Hat OpenShift AI Self-Managed 3.4, including the PostgreSQL
backend, API gateway, Authorino TLS, and the observability/monitoring stack.

Reference: *Govern LLM access with Models-as-a-Service → Deploy and manage
Models-as-a-Service* (OpenShift AI 3.4 docs).

## Cluster details

- Apps domain: `apps.cluster-9rcqr.9rcqr.sandbox5187.opentlc.com`
- Default ingress cert secret: `cert-manager-ingress-cert` (in `openshift-ingress`)

## Files

| File | Purpose |
|------|---------|
| `postgres-deployment.yaml` | Self-managed PostgreSQL 16 instance (namespace, credentials, PVC, Deployment, Service) backing MaaS API-key management |
| `maas-db-config-secret.yaml` | `maas-db-config` secret in `redhat-ods-applications` with the PostgreSQL `DB_CONNECTION_URL` |
| `maas-gateway.yaml` | `maas-default-gateway` Gateway in `openshift-ingress` with the required MaaS annotations |
| `configure-maas-tls.sh` | Configures TLS between Authorino and the MaaS API gateway |
| `cluster-observability-operator.yaml` | Subscription for the Cluster Observability Operator (COO) |
| `opentelemetry-operator.yaml` | Subscription for the Red Hat build of OpenTelemetry (required by the ODH monitoring service) |
| `dsci-metrics-storage-patch.yaml` | Enables the monitoring stack by setting `metrics.storage` in DSCInitialization |
| `qwen-3-llminferenceservice.yaml` | Example MaaS model (`qwen-3`) served via llm-d, including the GPU toleration fix |
| `maas-subscription.yaml` | Example MaaS subscription + matching authorization policy granting quota/access for `qwen-3` |
| `embeddings/` | Serving an **embedding** model on MaaS via plain vLLM (llm-d can't route `/v1/embeddings`) — see `embeddings/README.md` |

---

## Steps

### 1. Deploy PostgreSQL and create the database secret

OpenShift AI does not provide a database. MaaS requires a PostgreSQL instance
(version 14+) reachable from the cluster for API-key lifecycle management.

> **Before applying:** replace the placeholder password `ChangeMe-StrongPassword`
> in **both** `postgres-deployment.yaml` and `maas-db-config-secret.yaml` (they
> must match).

```bash
oc apply -f postgres-deployment.yaml
oc apply -f maas-db-config-secret.yaml
```

Verify:

```bash
oc get secret maas-db-config -n redhat-ods-applications
```

**Note on `sslmode`:** `maas-db-config-secret.yaml` uses `sslmode=disable` because
the in-cluster `rhel9/postgresql` image is not configured for TLS. If you front
the DB with TLS or use an external managed PostgreSQL, change this to
`sslmode=require`.

If MaaS (`modelsAsService`) is already `Managed` when you create/update the
secret, restart the API to pick it up:

```bash
oc rollout restart deployment/maas-api -n redhat-ods-applications
```

### 2. Create the MaaS gateway

The Gateway must be named `maas-default-gateway`, live in `openshift-ingress`,
and carry both annotations:

- `opendatahub.io/managed: "false"` — prevents the ODH Model Controller from
  overriding MaaS-managed authorization policies.
- `security.opendatahub.io/authorino-tls-bootstrap: "true"` — enables TLS to
  Authorino (the MaaS controller creates an EnvoyFilter for this).

The listener uses the cluster's default ingress wildcard cert
(`cert-manager-ingress-cert`), which covers the `maas.apps.<domain>` hostname —
no separate cert secret is needed.

> The `openshift-default` GatewayClass (controller
> `openshift.io/gateway-controller/v1`) already exists on this cluster and is
> immutable, so it is **not** defined in the manifest — the Gateway references it
> by name.

```bash
oc apply -f maas-gateway.yaml
```

Verify the Gateway is accepted and programmed:

```bash
oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='Accepted={.status.conditions[?(@.type=="Accepted")].status} Programmed={.status.conditions[?(@.type=="Programmed")].status}{"\n"}'
```

### 3. Configure TLS for Authorino and the MaaS API gateway

Runs the four steps from *Configure TLS for Models-as-a-Service*: annotate the
Authorino service for a serving cert, enable the Authorino TLS listener, set the
service-CA bundle env vars, and (idempotently) re-apply the Gateway
TLS-bootstrap annotation.

```bash
bash configure-maas-tls.sh
oc rollout status deployment/authorino -n kuadrant-system
```

Verify:

```bash
oc get secret authorino-server-cert -n kuadrant-system
oc get authorino authorino -n kuadrant-system -o jsonpath='{.spec.listener.tls.enabled}{"\n"}'
```

### 4. Enable observability / the Observe & Monitor dashboard

The dashboard's observability page requires a backend monitoring stack. Enabling
it has a dependency chain that must be satisfied in order:

#### 4a. Install the Cluster Observability Operator (COO)

> **Namespace matters.** COO **must** be installed into the
> `openshift-cluster-observability-operator` namespace (the manifest creates it
> along with an OperatorGroup). The perses-operator it ships generates a
> NetworkPolicy that only allows the Perses API to be reached from that exact
> namespace. Installing COO into `openshift-operators` instead leaves the
> perses-operator unable to register dashboards, and the Observability dashboard
> shows **"No dashboards found"** even though the backend pods are healthy.

```bash
oc apply -f cluster-observability-operator.yaml
```

If the InstallPlan requires manual approval (this cluster defaults to manual),
approve it:

```bash
oc get installplan -n openshift-cluster-observability-operator   # find the pending plan
oc patch installplan <name> -n openshift-cluster-observability-operator \
  --type=merge -p '{"spec":{"approved":true}}'
```

Wait for the CSV to reach `Succeeded` and the `monitoring.rhobs` CRDs to appear.

#### 4b. Install the Red Hat OpenTelemetry operator

The ODH monitoring service requires the `OpenTelemetryCollector` operator —
without it, `default-monitoring` stays in `Error`
(`OpenTelemetryCollector operator must be installed`).

```bash
oc apply -f opentelemetry-operator.yaml
```

(Approve the InstallPlan the same way if it is manual.)

#### 4c. Configure metrics storage in DSCInitialization

`spec.monitoring.metrics` was empty (`{}`), so no MonitoringStack was provisioned.
This patch sets storage and triggers the full stack:

```bash
oc patch dscinitialization default-dsci --type=merge \
  --patch-file dsci-metrics-storage-patch.yaml
```

#### 4d. Kuadrant observability and Tenant telemetry

These were already enabled on this cluster; verify:

```bash
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.spec.observability.enable}{"\n"}'
oc get tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  -o jsonpath='{.spec.telemetry.enabled}{"\n"}'
```

If either is missing, enable it:

```bash
oc patch kuadrant kuadrant -n kuadrant-system --type=merge \
  -p '{"spec":{"observability":{"enable":true}}}'
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service --type=merge \
  -p '{"spec":{"telemetry":{"enabled":true}}}'
```

#### Verify the monitoring stack

```bash
oc get monitoring default-monitoring \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
oc get pods -n redhat-ods-monitoring
```

Expect `Ready=True` and all pods Running (Perses, Prometheus, Thanos Querier,
OpenTelemetry collector, Alertmanager).

Also confirm the Perses dashboards have registered (this is what the UI lists —
if they are not `Available`, the dashboard shows "No dashboards found"):

```bash
oc get persesdashboard -A
oc get persesdashboard dashboard-3-maas-usage-admin -n redhat-ods-applications \
  -o jsonpath='Available={.status.conditions[?(@.type=="Available")].status}{"\n"}'
```

Expect `Available=True` for each dashboard, including the MaaS usage dashboard
(`dashboard-3-maas-usage-admin`). Then hard-refresh the OpenShift AI dashboard
and reopen the Observe/Monitor page.

> **Note:** `Tempo`/tracing and alerting conditions remain `False` because
> traces/alerting are not configured in the DSCI. These are optional and not
> required for MaaS usage metrics (token consumption, request counts, rate
> limits).

### 5. Deploy and publish a model (llm-d)

Deploy a generative model via the dashboard wizard as a **Generative AI model**
with **Distributed inference with llm-d** (leave *Use legacy deployment method*
unchecked), and select **Publish as MaaS** under Advanced settings. Only the
llm-d / LLMInferenceService path exposes the "Publish as MaaS" option — the
standard KServe path shows "Publish as AI asset endpoint" instead.

`qwen-3-llminferenceservice.yaml` is the resulting resource for the example
model, with one important addition: a **GPU toleration**. The GPU nodes carry the
taint `nvidia.com/gpu=NVIDIA-L40S-PRIVATE:NoSchedule`, so without a toleration
the pods stay `Pending` (`0/N nodes available: had untolerated taint ...`). The
toleration lives on `spec.template.tolerations`:

```yaml
spec:
  template:
    tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
```

```bash
oc apply -f qwen-3-llminferenceservice.yaml
oc get llminferenceservice qwen-3 -n demo-llm \
  -o jsonpath='Ready={.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Each replica consumes one GPU. With 2 replicas on 2 single-GPU nodes the model
uses all GPU capacity, so other GPU workloads will go `Pending`.

### 6. Create a subscription and authorization policy

A model is only consumable once a **subscription** (quota) and a matching
**authorization policy** (gateway access) reference it. You can create these in
the dashboard, or apply `maas-subscription.yaml`:

```bash
oc apply -f maas-subscription.yaml
oc get maassubscription,maasauthpolicy -n models-as-a-service
```

Both should reach `Active`. A user is offered a subscription only if one of its
groups matches the groups in their auth token — see the kube:admin note in
Troubleshooting.

Test end to end with an API key created from the dashboard:

```bash
BASE="https://maas.apps.<domain>/demo-llm/qwen-3"
curl -sS -H "Authorization: Bearer <API_KEY>" "$BASE/v1/models"
curl -sS -H "Authorization: Bearer <API_KEY>" -H "Content-Type: application/json" \
  "$BASE/v1/chat/completions" \
  -d '{"model":"qwen-3","messages":[{"role":"user","content":"hello"}],"max_tokens":32}'
```

A `200` with a token-usage block confirms the full path (key auth → subscription
quota → auth policy → llm-d serving) works.

---

## Troubleshooting

Issues hit during this setup and how they were resolved:

- **Observability dashboard: "Service Unavailable"** — the monitoring backend
  didn't exist. Install COO + OpenTelemetry and set `metrics.storage` (Step 4).

- **Observability dashboard: "No dashboards found"** — COO was installed in
  `openshift-operators`; its perses-operator NetworkPolicy only allows access
  from `openshift-cluster-observability-operator`. Reinstall COO into that
  namespace (Step 4a).

- **MaaS usage dashboard stuck (Perses HTTP 500)** — a corrupt Perses project
  file (`/perses/projects/redhat-ods-applications.yaml` with a stray trailing
  line) made `GET /api/v1/projects` return 500, blocking dashboard registration.
  Fix by truncating the file to valid YAML inside the Perses pod:

  ```bash
  oc exec -n redhat-ods-monitoring data-science-perses-0 -- sh -c \
    'head -n 9 /perses/projects/redhat-ods-applications.yaml > /tmp/f && \
     cp /tmp/f /perses/projects/redhat-ods-applications.yaml'
  ```
  This is a runtime fix (not a manifest); it recurs only if the file is
  regenerated corrupt.

- **Model pods `Pending` — untolerated GPU taint** — add the GPU toleration to
  the LLMInferenceService (Step 5).

- **LLMInferenceService `GatewayPreconditionNotMet` ("AuthPolicy CRD is not
  available")** even though Connectivity Link/Kuadrant is installed — the KServe
  controllers started before the AuthPolicy CRD existed, so their discovery
  caches were stale. Restart them:

  ```bash
  oc rollout restart deployment/llmisvc-controller-manager -n redhat-ods-applications
  oc rollout restart deployment/kserve-controller-manager  -n redhat-ods-applications
  ```

- **Can't see a subscription when creating an API key as kube:admin** —
  `kube:admin` is a virtual user whose token groups are fixed to
  `[system:cluster-admins, system:authenticated]`; it never picks up OpenShift
  `Group` object membership. Either add `system:cluster-admins` to the
  subscription **and** auth policy (as in `maas-subscription.yaml`), or create a
  real OpenShift/OIDC user in a dedicated group. The cluster had no IDP/users, so
  `system:cluster-admins` was used here for testing.

---

## Status

| Component | State |
|-----------|-------|
| PostgreSQL + `maas-db-config` secret | Manifests ready (set password before applying) |
| `maas-default-gateway` | Applied — Accepted & Programmed |
| Authorino + gateway TLS | Configured & verified |
| Cluster Observability Operator | Installed |
| Red Hat OpenTelemetry operator | Installed |
| DSCInitialization metrics storage | Configured (15d / 5Gi) |
| Kuadrant observability | Enabled |
| Tenant telemetry | Enabled |
| `default-monitoring` MonitoringStack | Ready — 9/9 pods Running |
| Perses dashboards (incl. MaaS usage) | All `Available` (after corrupt-project-file fix) |
| Example model `qwen-3` (llm-d) | Ready — 2 replicas on GPU nodes |
| Subscription `test-sub` + policy `test-sub-policy` | Active |
| End-to-end inference with API key | Verified (200 + token usage) |

### Not covered here (verify separately)

DataScienceCluster `kserve: Managed` and `kserve.modelsAsService.managementState: Managed`,
dashboard flags (`modelAsService`, `maasAuthPolicies`, `genAiStudio`,
`observabilityDashboard`), User Workload Monitoring, and llm-d / Connectivity Link
(Kuadrant) install — all confirmed present on this cluster but not managed by
these manifests.
