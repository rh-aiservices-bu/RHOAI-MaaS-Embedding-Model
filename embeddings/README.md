# Embedding models on MaaS (vLLM)

How to serve an **embedding** model through Models-as-a-Service. Embedding models
do **not** work on the llm-d path — they need plain vLLM. Verified end-to-end on
this cluster with `BAAI/bge-base-en-v1.5` (768-dim, `/v1/embeddings` → HTTP 200,
token usage metered).

## Why not llm-d

llm-d builds an `InferencePool` + a `router-scheduler` (EPP) and its HTTPRoute
only routes the **generation** endpoints (`/v1/completions`,
`/v1/chat/completions`, `/v1/responses`) to that pool. There is no
`/v1/embeddings` rule and the prefill/decode/scheduler machinery is
generation-only — so embeddings don't route.

## The fix: plain vLLM (no scheduler)

Deploy as an `LLMInferenceService` but **omit `router.scheduler`**. That produces
a single vLLM pod (no InferencePool/scheduler) whose HTTPRoute includes a
**catch-all** `/<ns>/<model>` → Service rule, so `/v1/embeddings` reaches vLLM:

| Path | Backend |
|------|---------|
| `/demo-llm/bge-embed/v1/completions` | Service |
| `/demo-llm/bge-embed/v1/chat/completions` | Service |
| `/demo-llm/bge-embed/v1/responses` | Service |
| `/demo-llm/bge-embed` (catch-all) | Service ← `/v1/embeddings` lands here |

Two more details:
- **Runner flag:** use `--runner pooling` (vLLM 0.18 **removed** `--task embed`).
  For `bge` vLLM would auto-detect pooling, but it is set explicitly. Container
  `args` are appended to `vllm serve … $@` by the base template; the
  `VLLM_ADDITIONAL_ARGS` env var is the other injection point.
- **GPU:** each replica needs a GPU and the same `nvidia.com/gpu` toleration as
  the generative models.

## Files

| File | Purpose |
|------|---------|
| `bge-embed-llminferenceservice.yaml` | The embedding model (vLLM, no scheduler, `--runner pooling`, GPU toleration) |
| `bge-embed-maas.yaml` | `MaaSModelRef` publishing bge-embed + the subscription/policy entries to add |

## Apply

```bash
# GPU note: each replica needs a GPU. Free one first if needed, e.g.:
#   oc patch llminferenceservice qwen-3 -n demo-llm --type=merge -p '{"spec":{"replicas":1}}'

oc apply -f bge-embed-llminferenceservice.yaml
oc apply -f bge-embed-maas.yaml
# then add bge-embed to ../maas-subscription.yaml (see comments in bge-embed-maas.yaml) and:
oc apply -f ../maas-subscription.yaml
```

## Test (through the MaaS gateway)

```bash
BASE="https://maas.apps.<domain>/demo-llm/bge-embed"
curl -sS -H "Authorization: Bearer <API_KEY>" -H "Content-Type: application/json" \
  "$BASE/v1/embeddings" \
  -d '{"model":"bge-embed","input":["the quick brown fox","models as a service"]}'
```

Expect a `200` with `data[].embedding` vectors (dim 768 for bge-base) and a
`usage.prompt_tokens` count — confirming auth, routing, serving, and token
metering all work under MaaS.

## Rule of thumb

- **Generative chat models** → llm-d (`router.scheduler: {}`).
- **Embedding models** → plain vLLM (omit `router.scheduler`, `--runner pooling`).
Both sit behind the same `maas-default-gateway` with the same subscription /
authorization-policy / rate-limit governance.
