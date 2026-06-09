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

## Rate limiting

The subscription gives `bge-embed` a budget of **5000 tokens / 1h**. Sending a
burst of embedding requests (each batching 4 inputs ≈ 488 input tokens) shows the
limit enforced at the gateway:

```text
req  1: HTTP 200  tokens=488  cumulative=488
...
req 11: HTTP 200  tokens=488  cumulative=5368
req 12: HTTP 429  >> Too Many Requests
```

The limiter allows every request up to and including the one that crosses 5000
(req 11 landed at 5368), then returns **429** for the rest until the 1-hour
sliding window rolls off. Notes:

- **Per-model budgets are independent** — this 5000/1h is separate from qwen-3's
  1000/1h; exhausting one does not affect the other.
- **Embeddings meter input tokens** (`prompt_tokens`); there are no completion
  tokens.
- **Enforced by Kuadrant/Limitador before vLLM runs**, so 429s cost no GPU
  compute and increment `limited_calls` in the observability metrics.

Reproduce with a short loop:

```bash
BASE="https://maas.apps.<domain>/demo-llm/bge-embed"; KEY="<API_KEY>"
TEXT=$(printf 'models as a service governs large language model access %.0s' {1..12})
for i in $(seq 1 12); do
  curl -sS -o /dev/null -w "req $i: %{http_code}\n" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    "$BASE/v1/embeddings" -d "{\"model\":\"bge-embed\",\"input\":[\"$TEXT\",\"$TEXT\",\"$TEXT\",\"$TEXT\"]}"
done
```

(Invalid key → **403**, missing/malformed `Authorization` → **401**, both rejected
at the gateway before reaching vLLM.)

## Rule of thumb

- **Generative chat models** → llm-d (`router.scheduler: {}`).
- **Embedding models** → plain vLLM (omit `router.scheduler`, `--runner pooling`).
Both sit behind the same `maas-default-gateway` with the same subscription /
authorization-policy / rate-limit governance.
