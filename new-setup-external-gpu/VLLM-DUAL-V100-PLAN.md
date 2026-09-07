# Plan — dual V100 32GB as a multi-tenant inference node

Status: **proposal, nothing applied.** Written 2026-09-07, restructured 2026-09-07.

`inference-0` now holds **2× Tesla V100 32GB** and **128 GB of host RAM**. This
plan treats the node as a small multi-tenant inference host rather than a
single-model server, and replaces the GPU Ollama deployments with
[`1CatAI/1Cat-vLLM`](https://github.com/1CatAI/1Cat-vLLM) (Apache-2.0), an
SM70/V100-targeted vLLM fork.

Three separable pieces of work, in order:

1. **Retire the heterogeneous-GPU workaround** (§2). The mixed V100+P4 pool is
   gone, so pin-by-UUID, the `gpu-pool-mixed` inventory labels and
   `ollama.gpu.enabled=false` are dead weight and should be deleted.
2. **Land the target topology** (§3–§8): one card for the executor, one card
   for the small models the pipeline is currently missing or running on CPU.
3. **Migrate the callers** (§9) and cut over (§10).

Piece 1 is worth doing on its own even if vLLM is deferred.

---

## 1. Why the topology, not just the model

The obvious reading of "replace Ollama with vLLM" is *one big model across both
cards at TP2*. That was the first draft of this plan and it is the weaker
target. Three reasons:

**The pipeline is the bottleneck, not the generator.** Today the planner
(`granite3.1-dense:8b`) and the executor (`qwen3:32b`) are **both pinned to the
same single V100**, with an explicit VRAM-contention warning in
`values-qwen32b.yaml` and `OLLAMA_MAX_LOADED_MODELS=1` to manage it. Embeddings
run on CPU across `ollama-embed-2..9`. And there is **no reranker anywhere in
the stack** — which is normally the largest retrieval-quality gain available per
GB of VRAM. A second card fixes the contention for free and creates room for
the two things that are missing.

**Total VRAM is a red herring against the fork's reference hardware.** Every
headline configuration in 1Cat-vLLM is 4× or 8× V100 16GB:

| | 1Cat's 4× V100 16GB | this node's 2× V100 32GB |
|---|---|---|
| Total VRAM | 64 GB | 64 GB |
| Aggregate FP16 tensor | ~500 TFLOPS | ~250 TFLOPS |
| Aggregate HBM2 bandwidth | ~3.6 TB/s | ~1.8 TB/s |

Same capacity, **half the compute and half the memory bandwidth.** A 27B model
that fits on their rig also fits here — but with half the hardware to push it
through. Decode is bandwidth-bound, so ~half throughput is the right
first-order expectation, independent of any software tuning.

**The 16GB and 32GB V100 are the same silicon.** Same GV100 die, 80 SMs, 5120
CUDA cores, 640 tensor cores, `sm_70`, 4096-bit HBM2 at 900 GB/s, same NVLink
2.0 on SXM2. The 32GB part uses 8-high HBM2 stacks instead of 4-high; there is
no ISA difference and no `cp.async`/FP8/FP4 on either. So every SM70 kernel in
the fork behaves identically, and the extra memory buys **capacity only, not
speed per card**.

> One exception: the **V100S PCIe 32GB** exists only at 32GB and runs 1134 GB/s
> (not 900), 16.4 TFLOPS FP32, higher boost, still 250W. If Phase 0 identifies
> V100S, expect ~26% better decode than the table above. Establish which SKU
> these are — the existing card enumerates as `Tesla PG500-216`, which means the
> driver had no marketing name for the board, so neither the SKU nor the form
> factor is currently known.

---

## 2. Retire the heterogeneous workaround

### 2.0 What it was

Old inventory (`configs/GPU-Descriptor`, verified 2026-08-09): 1× V100 32GB
(`sm_70`, `0000:05:00.0`) + 2× Tesla P4 8GB (`sm_61`, `0000:81:00.0`,
`0000:82:00.0`). `nvidia.com/gpu` was **3 and untyped** — GFD models a mixed
node as one product/memory/compute triple, so a pod requesting the resource
could be handed 8 GB and `sm_61`. Two attempts to advertise only the V100 both
failed (see `EXTERNAL-NODE-SETUP.md`): `NVIDIA_VISIBLE_DEVICES` on the operator
DaemonSets had no effect because they run privileged and NVML enumerates
everything; device-plugin named `resources` is unimplemented in v0.19.3
(`Customizing the 'resources' field is not yet supported`). So workloads pinned
a card by UUID and deliberately did **not** request `nvidia.com/gpu`, which
bypasses scheduler accounting entirely.

With two identical 32 GB `sm_70` cards the pool is uniform, GFD tells the truth,
and ordinary resource requests work. The whole workaround goes.

### 2.1 `kubernetes-setup` (this repo)

| File | Change |
|---|---|
| `configs/GPU-Descriptor` | Regenerate from Phase 0. Two V100 rows, no P4 rows. |
| `new-setup-external-gpu/configs/patch-inference-0.yaml` | `nodeLabels` keeps `gpu: "true"` and `role: inference-node` — both are node identity and must exist before the operator runs. Only the mixed-pool commentary changes. Confirm no `machine.install.extraKernelArgs: vfio-pci.ids=10de:1bb3` was ever applied; documented as untested, and meaningless with the P4s gone. |
| `new-setup-external-gpu/EXTERNAL-NODE-SETUP.md` | Rewrite § "Heterogeneous GPUs", § "Targeting a specific GPU", § "Which card for which job", § "GPU smoke test". |
| `new-setup-external-gpu/45-enroll-external-node.sh` (~l.268) | Closing echo says the operator publishes labels "that Ollama pins against" — restate as vLLM + `nvidia.com/gpu`. |
| `new-setup-external-gpu/config-cluster.sh` (~l.147) | Same wording fix. |

On the docs: this repo's house style keeps failure findings with dates
(`# WHY (failure observed 2026-08-22)`, the two rejected approaches). Keep that.
Move the heterogeneous material to a dated **appendix** — "Historical: the mixed
V100+P4 pool (through 2026-09)" — rather than deleting it. The device-plugin
`resources` limitation and the privileged-DaemonSet/NVML interaction are still
true, still non-obvious, and will cost a day to rediscover.

### 2.2 `complete-build/infrastructure/nvidia-operator.sh`

This is where the logic lives, and it has a trap in it.

- **Delete** `GPU_UUID_P4_0` / `GPU_UUID_P4_1` (l.53-54) and the `Tesla P4`
  discovery `mapfile` (l.225, l.232-233).
- **Rewrite the label block** (l.246, l.256-264):
  - `gpu-count=3` → `2`, `gpu-total-count=3` → `2`, `gpu-v100-count=1` → `2`
  - **remove** `gpu-p4-count`, `gpu-heterogeneous`, `gpu-pool-mixed`,
    `gpu-p4-0-uuid`, `gpu-p4-1-uuid`
  - **remove** `gpu-v100-uuid`. With a uniform pool, pin-by-UUID is a
    regression: it bypasses scheduler accounting and lets two pods double-book a
    card. The target topology in §3 uses ordinary requests.
  - Dropping a label from the script does **not** remove it from a live Node.
    Add an explicit unset pass or the stale claims outlive the hardware:
    ```bash
    "$KUBECTL" label node "$GPU_NODE" \
      hierocracy.home/gpu-p4-count- \
      hierocracy.home/gpu-p4-0-uuid- \
      hierocracy.home/gpu-p4-1-uuid- \
      hierocracy.home/gpu-heterogeneous- \
      hierocracy.home/gpu-pool-mixed- \
      hierocracy.home/gpu-v100-uuid- 2>/dev/null || true
    ```
- **⚠ The idempotency guard will skip this step.** l.203 reads
  `is_step_done "nvidia-gpu-labels" ... get node -l hierocracy.home/gpu-v100-uuid`.
  On the already-labelled node that predicate is *true*, so the rewritten block
  never runs and the node keeps its old labels forever. Bump the sentinel
  (`nvidia-gpu-labels-v2`) or invert the predicate onto a new label.
- **Keep `mig.strategy=none`** (l.301, l.105) but rewrite the comment. The
  reason changes from "stop GFD collapsing a mixed node onto one product" to
  simply "V100 does not support MIG". Keep the mechanism note — the plugin
  resolves `MIG_STRATEGY` **env above its config file**, so it must be the Helm
  value, not `migStrategy` in the ConfigMap.
- **Keep `DEVICE_PLUGIN_ENABLED=true`** (l.38) and delete the l.30 note saying
  nothing should request `nvidia.com/gpu`. That inverts.
- Trim the "DO NOT add a `resources:` block" warning (l.114-120) to a pointer at
  the historical appendix.

### 2.3 Verify before moving on

```bash
/home/k8s/kube/kubectl get node inference-0 -o json | python3 -c "
import json,sys
l=json.load(sys.stdin)['metadata']['labels']
for k in sorted(l):
    if 'gpu' in k.lower(): print(f'{k}={l[k]}')"
/home/k8s/kube/kubectl get node inference-0 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Expect `nvidia.com/gpu: 2`, `gpu.product=Tesla-PG500-216`, `gpu.memory=32768`,
`gpu.compute.major=7`, `gpu.count=2`, and no surviving `p4` /
`heterogeneous` / `pool-mixed` / `v100-uuid` labels.

---

## 3. Target topology

**One card per pod, two pods, `nvidia.com/gpu: 1` each.** No sharing config, no
UUID pinning, no new cluster machinery — allocatable is 2 and both units are
consumed by ordinary requests.

| | Card 0 — `vllm-executor` | Card 1 — `gpu-small-models` |
|---|---|---|
| Request | `nvidia.com/gpu: 1` | `nvidia.com/gpu: 1` |
| Contents | 32B AWQ, TP1 | 3 processes in **one container** |
| | | · planner 8B AWQ (vLLM, :8001) |
| | | · reranker BGE-reranker-v2-m3 (:8002) |
| | | · embeddings — all-minilm / nomic / mxbai (:8003) |

VRAM budget (Track A / AWQ figures — NVFP4 shifts these):

| Card 0 | GB | | Card 1 | GB |
|---|---|---|---|---|
| 32B AWQ weights | ~18 | | planner 8B AWQ weights | ~5 |
| KV @ `fp8_e5m2`, 65,536 ctx | ~8 | | planner KV, 16,384 ctx | ~3 |
| activations + CUDA graphs | ~3 | | reranker (568M, fp16) | ~1.5 |
| | | | embeddings (3 models, fp16) | ~1.5 |
| | | | 3× CUDA context overhead | ~1.5 |
| **total** | **~29 / 32** | | **total** | **~12.5 / 32** |

Card 1's ~19 GB of headroom is deliberate — it is where a larger planner, a
second embedding replica, or a draft model goes later.

**Why one container with three processes.** Containers in a pod cannot share a
GPU device allocation (`nvidia.com/gpu: 1` is granted to one container), but
processes inside one container can. These three models are small and
low-duty-cycle, so plain CUDA context switching is adequate and this needs
**zero** device-plugin changes. §4 covers splitting them into separate pods
later if independent scaling or restart becomes worth the machinery.

**What this buys over the single-model draft:**

- Planner and executor stop contending for one card — the current documented pain.
- ~8 embed pods' worth of worker CPU comes back (`all-minilm:l6-v2` is 22M
  params, `nomic-embed-text` 137M, `mxbai-embed-large` 335M; a V100 serves all
  three from ~1.5 GB).
- The stack gains a reranker, for ~1.5 GB.
- No tensor parallelism at all: no all-reduce, no NVLink dependency, and none of
  the fork's TP2 operator fallbacks (§5).

### 3.1 Variant: executor at TP2 (faster, but not free)

Your current config is effectively single-stream — `OLLAMA_NUM_PARALLEL=1`,
`OLLAMA_MAX_LOADED_MODELS=1`, and the fork's own profiles use `max_num_seqs=1`.
At low concurrency, **latency** is what matters, and TP2 halves the per-card
weight bytes read per token. Since decode is bandwidth-bound that is worth up to
~2× tok/s, minus all-reduce.

It is not the default here because of a scheduling conflict: **a TP2 job needs
exclusive whole-GPU access to both cards**, which leaves nothing for card 1's
tenants. Getting both requires one of:

- **Verified spread allocation.** If the device plugin is configured to
  advertise replicas per card, a pod requesting 2 units could receive two
  replicas of the *same* physical card, and TP2 would try to initialise two
  ranks on one GPU. Whether the plugin spreads across physical devices is
  **unverified** — test it before depending on it.
- **UUID-pinning the executor only** while the small models use ordinary
  requests. Functional, but reintroduces exactly the accounting hole §2 removes.

Decide this after §10 measures the TP1 executor. Do not block the migration on it.

### 3.2 Using the 128 GB of host RAM

- **Do:** `--enable-prefix-caching` with a generous `--swap-space` (32 GB+).
  RAG requests share long system prompts and retrieved-context prefixes, so
  prefix reuse is the highest-leverage use of host RAM on this workload. Host
  RAM also page-caches the ~20 GB of weights so restarts stop hitting CephFS.
- **Don't:** `--cpu-offload-gb` for weights. PCIe 3.0 x16 is ~16 GB/s;
  offloaded decode lands around 1–3 tok/s. Not interactive. (One exception, in
  Appendix A.)

---

## 4. Optional: splitting card 1 into separate pods

Only needed if the three small models must scale or restart independently. All
three options are documented because this cluster has a history of
device-plugin features that parse but do nothing — see §2.0.

| Option | Mechanism | Cost / risk |
|---|---|---|
| **A** (default, §3) | one container, 3 processes | none; but all three restart together |
| **B** | per-device time-slicing in `devicePlugin.config` | pure ConfigMap change, no new daemon. `renameByDefault: true` + `resources[].devices: [1]` to shard **only** card 1 into `nvidia.com/gpu.shared`. **Verify the `devices` scoping is implemented in plugin v0.19.3** — the sibling `resources` field is not. No memory isolation; budget by `--gpu-memory-utilization` convention. |
| **C** | MPS via `devicePlugin.config` `sharing.mps` | best concurrency; Volta is exactly where hardware-isolated MPS begins, so V100 is well suited. Needs the `mps-control-daemon` DaemonSet, **untested on Talos here** — and the operator has already needed a validation-fix DaemonSet on this node (`GPU-OPERATOR-TALOS-NOTES.md`). MPS + CUDA graphs can also be fragile. |

Try in order A → B → C. Do not adopt B or C to reach the §3 target; they are
refinements to it.

---

## 5. Model selection, and the honest TP2/TP4 problem

Read this before committing to a model. The fork is tuned for TP4; TP2 and TP1
are secondary paths.

Geometry of the flagship NVFP4 target
(`QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4/config.json`, `model_type: qwen3_5`):

| | value | ÷2 |
|---|---|---|
| `num_attention_heads` | 24 | 12 ✓ |
| `num_key_value_heads` | 4 | 2 ✓ |
| `intermediate_size` | 17408 | 8704 ✓ |
| `num_hidden_layers` | 64 | — |
| `head_dim` | 256 | — |
| `max_position_embeddings` | 262144 | — |

It shards cleanly. The problem is what the project gates:

- v1.2.2 support matrix lists **Qwen3.5-27B NVFP4 as TP4-only**. Qwen3.6-27B in
  **AWQ and FP8 is listed at TP 2/4** with FP8 KV and MTP4.
- v1.5.0 notes gate `Qwen3.8-27B-QUASAR-NVFP4` on "fresh-wheel TP4".
- Two DFlash2 operators are not general: the **compact LM-head rerank is
  TP4-specific**, the **one-pass grouped attention operator is E5M2-specific**.
  DFlash2 stays active at other TP degrees but *falls back* for those.

**Two tracks. The executor must not depend on the speculative one.**

- **Track A (primary, ship this):** a 27B–32B **AWQ / W4A16** target at TP1 on
  card 0, no speculative decoding, `--attention-backend FLASH_ATTN_V100`,
  `--kv-cache-dtype fp8_e5m2`.
- **Track B (stretch):** `Qwen3.8-27B-QUASAR-NVFP4` + the DFlash2 drafter.
  Attempt only after A serves, and resolve the TP gating first — read PR #445
  and #426/#427, or open an issue asking directly.

### 5.1 KV arithmetic

Per-token KV = `2 (K,V) × 64 layers × 4 kv_heads × 256 head_dim` = **131,072
units/token**. (Qwen2.5-32B lands on the same figure: 64 layers × 8 kv_heads ×
128 head_dim.)

| KV dtype | per token | per GB | 65,536 ctx | 262,144 ctx |
|---|---|---|---|---|
| `fp8_e5m2` | 128 KiB | 8,192 tok | **8 GiB** | 32 GiB |
| `fp16` | 256 KiB | 4,096 tok | 16 GiB | 64 GiB |

- **`fp8_e5m2` is mandatory, not a tuning choice** — it is also the dtype the
  one-pass grouped attention fast path requires.
- On one 32 GB card with ~18 GB of AWQ weights, ~8 GB of KV (65,536 tokens) is
  the practical ceiling. Start there: `--max-model-len 65536`,
  `--gpu-memory-utilization 0.90`, `--max-num-seqs 4`. Raise only with
  measurements. The v1.2.1 notes explicitly describe conservative profiles "to
  reduce 32 GB V100 OOM risk".

---

## 6. Build the container image

**Use the released wheel; do not build from source.** ~18k commits with custom
CUDA extensions (FlashAttention-V100, paged-KV utils, TurboMind SM70,
FlashQLA); a source build is multi-hour and needs a toolkit matching the PyTorch
CUDA ABI exactly.

Releases are all `cp312 / linux_x86_64`:

| Tag | Date | Note |
|---|---|---|
| **v1.5.0** | 2026-09-02 | latest; DFlash2 1.5.0 serving; RC-grade by the authors' own description, not called a tagged Release |
| v1.3.0 | 2026-08-17 | `1cat_vllm-1.3.0-cp312-cp312-linux_x86_64.whl`, SHA256 `2bdb14a9c44f83ee6a766d88ed0d85b11390d6f5d65747e8dbe80a8e2d5d63e0` |

Pin **v1.5.0**, verify, keep v1.3.0 as fallback — it is the newest tag with a
published asset checksum, which matters for an air-gapped rebuild. There are
**no published Docker images**, and `docker/Dockerfile` in the repo is the
upstream multi-stage *source* build — do not use it.

```dockerfile
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3-pip ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY registry-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
RUN pip install --no-cache-dir torch==2.10.0 --index-url https://download.pytorch.org/whl/cu128
COPY 1cat_vllm-1.5.0-cp312-cp312-linux_x86_64.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && rm /tmp/*.whl
ENV HF_HUB_OFFLINE=1 VLLM_ATTENTION_BACKEND=FLASH_ATTN_V100
ENTRYPOINT ["vllm"]
```

Run the project's own verification snippet **inside the image on the node** — an
import failure is the signal to drop to v1.3.0:

```bash
python - <<'PY'
import sys, torch, vllm, flash_attn_v100
from flash_attn_v100 import flash_attn_v100_cuda, paged_kv_utils
from flash_attn_v100 import flash_attn_grouped_verify_max_query_tokens
print("Torch:", torch.__version__, "CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name(0), "arch:", torch.cuda.get_arch_list())
print("vLLM:", vllm.__version__, "flash_attn_v100:", flash_attn_v100.__version__)
print("DFlash2 grouped verify max Q:", flash_attn_grouped_verify_max_query_tokens())
PY
```

`torch.cuda.get_arch_list()` must contain `sm_70`.

The `gpu-small-models` container is a **separate, smaller image**: the reranker
and embedding servers need only `torch` + `sentence-transformers`, not the vLLM
wheel. Build the planner's vLLM process from the image above, or accept one
combined image to avoid maintaining two — decide when writing it.

Publish both the way this cluster already does images: build with podman on
hierophant, push to `hierophant.hierocracy.home:5000`, mirror into the
in-cluster registry with skopeo (see `pull-podman-images.sh`, `seed-images.sh`).
Hierophant has **no sudo over batch SSH**, so build from an interactive session
or rootless.

---

## 7. Get the models onto the cluster

All three 1Cat-recommended repos are public and ungated (verified via the HF
API, 2026-09-07):

| Repo | Size | Role |
|---|---|---|
| *(TBD)* Qwen3.6-27B AWQ or Qwen 32B AWQ | ~16–18 GB | **Track A executor** |
| *(TBD)* 8B AWQ instruct | ~5 GB | **planner** |
| `BAAI/bge-reranker-v2-m3` | ~1.2 GB | **reranker** (new capability) |
| `QUASAR-QAT/Qwen3.8-27B-QUASAR-NVFP4` | 20.58 GB | Track B target |
| `incoai/Qwen3.8-27B-DFlash2` | 3.85 GB | Track B drafter — pin revision `dedf8df68adfb1afeaf7b7480c0a0243108177b4` |

The NVFP4 card claims it "requires an NVIDIA GPU with FP4 support (Blackwell,
compute capability 10.0+)". That is the *upstream* requirement — the fork's
ModelOpt-NVFP4 SM70 path is exactly what makes it runnable on Volta. It also
means the model card's own serve flags do not apply here; use the fork's.

Delivery, mirroring `pre-pull-models.sh` → registry → `seed-models.sh` but for
plain files rather than Ollama blobs:

1. Download on hierophant to `/mnt/storage/hf-models/<repo>` with
   `huggingface-cli download --revision <sha> --local-dir ...`. **Pin the
   revision for every model**, not just the drafter.
2. Create a `vllm-models` PVC — `rook-cephfs`, `ReadWriteMany`, **150Gi**.
3. Seed with a one-shot Job copying from a hostPath on hierophant. **Do not bake
   20+ GB of weights into an image.**
4. Mount read-only at `/models`, serve by local path, `HF_HUB_OFFLINE=1`, so no
   pod reaches the internet.

The NVFP4 target's `config.json` declares `Qwen3_5ForConditionalGeneration` and
the repo is tagged `image-text-to-text`, so `--trust-remote-code` is required
and the image may need multimodal preprocessing deps even for text-only use.
Budget a build iteration for that.

---

## 8. The deployments

New namespace `llms-vllm`. Plain Deployments, **not** the `otwld/ollama` chart.

### 8.1 `vllm-executor` — card 0

```
vllm serve /models/qwen-32b-awq \
  --served-model-name qwen-executor \
  --trust-remote-code \
  --tensor-parallel-size 1 \
  --attention-backend FLASH_ATTN_V100 \
  --kv-cache-dtype fp8_e5m2 \
  --max-model-len 65536 \
  --gpu-memory-utilization 0.90 \
  --max-num-seqs 4 \
  --enable-prefix-caching \
  --swap-space 32 \
  --host 0.0.0.0 --port 8000
```

### 8.2 `gpu-small-models` — card 1

One container, three processes under a supervisor: planner vLLM on :8001
(`--gpu-memory-utilization 0.12`, `--max-model-len 16384`), reranker on :8002,
embeddings on :8003. Three Services so callers address them independently.

Because these share a card by plain context switching, **the sum of their
memory budgets must be set by convention** — nothing enforces it. Write the
budget from §3 into the manifest as a comment.

### 8.3 Pod details that are easy to get wrong

- `resources.limits: {nvidia.com/gpu: 1}` on each pod — real requests, no UUID
  pinning.
- `runtimeClassName: nvidia`; `nodeSelector: {role: inference-node}`; toleration
  for `nvidia.com/gpu=present:NoSchedule` (the node is tainted by
  `scripts/setup-node-labels.sh`; the selector states intent, the toleration is
  what gets past the taint — both are needed).
- **`/dev/shm`**: `emptyDir` with `medium: Memory`, `sizeLimit: 4Gi`, mounted at
  `/dev/shm`. The 64 MB default breaks NCCL and is the classic
  silent-hang-at-startup failure. Required now for the multi-process pod, and
  required later if the executor moves to TP2.
- Probes hit **`/health`**, not `/` (the Ollama values files use `/`). Use a
  `startupProbe` with ~600s of budget to cover loading ~18 GB off CephFS plus
  CUDA graph capture — not a long `livenessProbe` delay.
- Env: `VLLM_ATTENTION_BACKEND=FLASH_ATTN_V100`,
  `VLLM_SM70_ENABLE_LM_HEAD_FASTPATH=1`, and benchmark
  `VLLM_SM70_QUANT_BACKEND=marlin` against `=turbomind` — the fork exposes both
  and does not declare a winner.
- **TLS is finally possible.** `values.yaml` carries a standing note that
  "Ollama does not honor OLLAMA_TLS_CERT/KEY … will be revisited when migrating
  to vLLM", and the TLS volumes were stripped for that reason. vLLM supports
  `--ssl-keyfile` / `--ssl-certfile`, and the callers in
  `rag-worker/internal/config/config.go` already default to `https://`. Reuse
  `ollama-tls-certificate.yaml` and close this out.
- Insert the install into `setup-complete.sh` after Step 1.9
  (nvidia-operator) — same position and reason Ollama had: it needs the GPU node
  labels to exist first.

---

## 9. Client-side migration (largest non-GPU risk)

**vLLM does not speak the Ollama API.** Every current caller uses Ollama-native
routes that do not exist in vLLM:

| Caller | Routes used | vLLM equivalent |
|---|---|---|
| `rag-worker/internal/ollama/client.go` | `/api/chat` (l.120, l.174), `/api/embeddings` (l.271), `/api/tags` (l.305) | `/v1/chat/completions`, `/v1/embeddings`, `/v1/models` |
| `rag-ingestion/service.py` | `/api/embeddings` (l.214), `/api/show` (l.237), `/api/tags` (l.832) | `/v1/embeddings`, `/v1/models`, — |
| `rag-stack/tests/*.py` | `/api/embeddings`, `/api/tags` | as above |

Model identifiers change too: `EXECUTOR_MODEL` defaults to `qwen2.5:32b`
(`rag-worker/internal/config/config.go:109`) and `PLANNER_MODEL` to
`granite3.1-dense:8b` (l.106); both become whatever `--served-model-name` is set
to.

**Recommended:** add an OpenAI-protocol client alongside the existing Ollama one
in `rag-worker`, selected by env var, behind the same interface. One new file,
contained blast radius, no extra hop, and the Ollama path stays intact for
rollback. (A translating proxy such as LiteLLM avoids the Go change but adds a
hop, a component to run, and a second place for timeouts to live.)

**The reranker is a new call site, not a migration.** Nothing in the pipeline
calls one today, so `rag-worker` needs a rerank step between the Qdrant search
and the executor call. This is net-new code and should be behind a feature flag
so retrieval quality can be A/B'd against the current path.

**Migration order** — the endpoints are independent, so do them one at a time
with the Ollama pod still running as rollback:

1. Executor → `vllm-executor`. Biggest win, smallest change.
2. Planner → `gpu-small-models`. Frees the last GPU Ollama pod.
3. Embeddings → `gpu-small-models`. Retires `ollama-embed-2..9` and returns
   worker CPU. Verify embedding vectors match the CPU path before repointing
   `rag-ingestion`, or previously-ingested Qdrant vectors become incomparable.
4. Reranker — new, flagged off, enabled after A/B.

> ⚠ Step 3 is the one with a data hazard. Same model + same pooling should give
> identical vectors, but confirm empirically against a sample of existing
> collection entries. If they differ, the collection needs re-ingestion.

---

## 10. Cutover and rollback

1. Bring `vllm-executor` up alongside the running `ollama-qwen32b`. Scale
   `ollama-qwen32b` to 0 for the smoke test rather than trying to co-reside —
   it pins a card by UUID and does no accounting, so it will contend.
2. Smoke test directly: `/v1/models`, a short `/v1/chat/completions`, then a
   request at the full `--max-model-len`.
3. Benchmark against the Ollama baseline (`qwen3:32b` Q4_K_M on one V100) before
   switching traffic. The fork's ~260 tok/s figure is a 4-card demo number and
   is not a TP1-on-one-card expectation — see §1.
4. Repoint `EXECUTOR_URL` / `EXECUTOR_MODEL` in
   `rag-worker/k8s/deployment.yaml`. Keep `ollama-qwen32b` at 0 rather than
   deleted — scaling back to 1 and reverting two env vars is the rollback.
5. Repeat 1–4 for the planner, then embeddings, then the reranker (§9).
6. Only once stable under real load: delete the GPU Ollama deployments, drop
   `values.yaml` / `values-qwen32b.yaml`, remove the `ollama-gpu-pin-v100`
   ConfigMap block from `ollama.sh` (l.113-152), and trim the GPU chat models
   from `seed-models.sh` (`llama3.1`, `granite3.1-dense:8b`, `qwen2.5:32b`,
   `qwen3:32b` into `ollama-llama3` / `ollama-qwen32b`).
7. Revisit §3.1 (executor at TP2) with real latency numbers in hand.

---

## Phase 0 — verify the hardware first

Nothing above is safe to start until these are answered. `nvidia-smi` cannot run
on Talos directly, so both go through throwaway pods.

```bash
# PCI inventory — regenerates configs/GPU-Descriptor
${TALOS_ROOT}/talosctl --talosconfig "${TALOSCONFIG}" \
  --nodes 192.168.5.31 --endpoints "${CP_VIP}" \
  get pcidevices -o wide | grep -i nvidia

# UUIDs, memory, arch, SKU, driver, and interconnect topology
/home/k8s/kube/kubectl run gpu-probe --restart=Never --rm -i \
  --image=hierophant.hierocracy.home:5000/nvcr.io/nvidia/k8s-device-plugin:v0.18.1 \
  --overrides='{"spec":{"nodeName":"inference-0"}}' \
  --env=NVIDIA_VISIBLE_DEVICES=all \
  --env=NVIDIA_DRIVER_CAPABILITIES=utility \
  -- bash -c 'nvidia-smi --query-gpu=index,uuid,name,memory.total,compute_cap,driver_version,pci.bus_id --format=csv; echo; nvidia-smi -q | grep -iE "Product Name|Board|Bus Type"; echo; nvidia-smi topo -m'
```

Record:

- **Are the P4s physically gone?** If still seated, the pool is *still* mixed
  and §2 must not be applied as written.
- **SKU** — V100 PCIe, V100S PCIe, SXM2, or SXM3. Sets the bandwidth expectation
  in §1.
- **NVLink or PCIe** — `NV1`/`NV2` in `topo -m` means NVLink; `PHB`/`SYS` means
  the interconnect runs over PCIe, possibly cross-socket. Only matters if §3.1
  is adopted, but `SYS` is worth fixing by reseating regardless.
- **Driver version.** 1Cat-vLLM wheels target **CUDA 12.8 / PyTorch 2.10 /
  Python 3.12**. CUDA 12.x minor-version compatibility needs **R525+**; the
  practical floor for a 12.8 runtime is **R570** unless forward-compat libs ship
  in the image. The driver comes from the `siderolabs/nonfree-kmod-nvidia`
  extension baked into
  `hierophant.hierocracy.home:5000/siderolabs/installer-gpu:v1.12.4`. **If it is
  below the floor, a new Image Factory schematic and a node reinstall are
  prerequisites for §6 onward** — a reboot-window item, so find out now.

---

## Appendix A — the ambitious swing

The fork lists **Qwen3.5-122B-A10B-AWQ** (their profile: TP4, 256K context). At
4-bit that is roughly 61–68 GB of weights against 64 GB of VRAM — so it needs a
few GB of cold-expert offload, which 128 GB of host RAM makes viable. Only ~10B
params activate per token, so decode cost is 32B-class while quality sits well
above it. This is the one case where the RAM upgrade unlocks a different tier of
model, and the only case where CPU offload is defensible (§3.2).

It is also two gambles stacked — 122B at TP2 when the fork profiles it at TP4,
plus MoE expert offload — and it consumes both cards entirely, so it is
incompatible with §3's topology. Treat it as an experiment to run after Track A
is in production, not as a target.

---

## Open questions blocking a start

1. **Are the P4s physically removed?** If not, §2 is wrong as written.
2. **Which V100 SKU, and NVLink or PCIe?** (Phase 0.) Sets throughput
   expectations and whether §3.1 is worth pursuing.
3. **Driver version vs the CUDA 12.8 floor.** (Phase 0.) Potential reinstall.
4. **Exact HF repo ids** for the Track A executor AWQ model and the 8B planner.
5. **Does v1.5.0 support TP2 for the QUASAR NVFP4 target,** or is TP4 a hard
   gate? (PR #445; DFlash2 PRs #426/#427.) Gates Track B only.
6. **Is the workload really single-stream?** The current config says yes
   (`OLLAMA_NUM_PARALLEL=1`, `max_num_seqs=1`). If concurrency is expected to
   rise, revisit §3.1 — at high concurrency two independent TP1 replicas beat
   one TP2 instance.
7. **Do GPU embeddings reproduce the CPU vectors bit-for-bit?** (§9 step 3.)
   Determines whether the Qdrant collection needs re-ingestion.
