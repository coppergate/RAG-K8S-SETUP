# Plan — dual V100 32GB as a multi-tenant inference node

Status: **proposal, nothing applied.** Written 2026-09-07, restructured 2026-09-07,
reviewed for internal consistency 2026-09-07 (VRAM budgets reconciled against the
serve flags, §9 aligned with the decided client approach, §2/§10 ordering hazard
documented).

`inference-0` now holds **2× Tesla V100 32GB** and **128 GB of host RAM**. This
plan treats the node as a small multi-tenant inference host rather than a
single-model server, and replaces the GPU Ollama deployments with
[`1CatAI/1Cat-vLLM`](https://github.com/1CatAI/1Cat-vLLM) (Apache-2.0), an
SM70/V100-targeted vLLM fork.

**§0 gates everything else** — it is first in the document for that reason. Do
not start §2 before its questions are answered.

Three separable pieces of work, in order:

1. **Retire the heterogeneous-GPU workaround** (§2). The mixed V100+P4 pool is
   gone, so pin-by-UUID, the `gpu-pool-mixed` inventory labels and
   `ollama.gpu.enabled=false` are dead weight and should be deleted.
   **Read §2.3 first** — done in isolation this step breaks the §10 rollback.
2. **Land the target topology** (§3–§8): one card for the executor, one card
   for the small models the pipeline is currently missing or running on CPU.
3. **Migrate the callers** (§9) and cut over (§10).

Piece 1 is worth doing on its own even if vLLM is deferred.

---

## 0. Verify the hardware first (blocking)

Nothing that follows is safe to start until these are answered. `nvidia-smi`
cannot run on Talos directly, so both probes go through throwaway pods.

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
> (not 900), 16.4 TFLOPS FP32, higher boost, still 250W. If §0 identifies
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
| `configs/GPU-Descriptor` | Regenerate from §0. Two V100 rows, no P4 rows. |
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

### 2.3 ⚠ Removing `gpu-v100-uuid` breaks the Ollama rollback

**Verified in code 2026-09-07 — this is a hard failure, not a risk.**
`complete-build/rag-stack/infrastructure/ollama/ollama.sh:137-144` resolves that
label and exits non-zero without it:

```bash
V100_UUID=$($KUBECTL get node "$GPU_NODE" \
  -o jsonpath='{.metadata.labels.hierocracy\.home/gpu-v100-uuid}' 2>/dev/null || echo "")
if [[ -z "$V100_UUID" ]]; then
  echo "ERROR: node $GPU_NODE has no hierocracy.home/gpu-v100-uuid label." >&2
  exit 1
fi
```

`ollama.sh` runs from `setup-complete.sh` as part of the RAG stack step, so once
§2.2's unset pass strips that label from the live node, **any full install or
standalone `ollama.sh` run dies there** — before Ollama, and therefore before
everything sequenced after it.

That collides directly with §10, which keeps `ollama-qwen32b` as the rollback
path. Scaling an *already-deployed* Deployment back to 1 still works; re-running
the installer to recreate it does not. The rollback is only as good as the
install path that produces it.

**Resolution — pick one and write it down:**

| | Approach | Trade-off |
|---|---|---|
| **1** (preferred) | Move §10 step 6's `ollama.sh` surgery *forward*, into the same change as §2.2 — details below. | Ollama and vLLM then both request the resource properly and cannot double-book. Slightly more work up front; leaves a coherent rollback. |
| **2** | Keep `gpu-v100-uuid` published until §10 completes; drop only the P4 and `pool-mixed` labels in §2.2. | Smallest diff, but carries the accounting hole §2 exists to remove, and someone must remember to finish. |

**Approach 1, concretely** — in `complete-build/rag-stack/infrastructure/ollama/`:

1. `ollama.sh`: delete the UUID-resolve block and the `ollama-gpu-pin-v100`
   ConfigMap (l.113-152).
2. `values.yaml` and `values-qwen32b.yaml`: flip the `ollama.gpu` block to a
   real request and drop `extraEnvFrom` for the deleted ConfigMap —
   ```yaml
   ollama:
     gpu:
       enabled: true
       type: nvidia
       number: 1
   ```
   The block currently carries only `enabled: false`, so `type` and `number`
   have to be added, not edited.
3. **Rewrite the comment above it.** `values-qwen32b.yaml:22-39` is a 17-line
   "Deliberately FALSE — do not re-enable without reading the note below"
   warning whose entire premise is the mixed pool. Left in place it actively
   argues against the correct configuration, which is worse than no comment.
   Replace it with a dated pointer to the §2.0 historical appendix.

Approach 1 also removes the reason §10 step 1 warns that the two cannot
co-reside: with Ollama requesting `nvidia.com/gpu: 1` and vLLM requesting the
other, allocatable 2 covers both and the scheduler keeps them apart. Co-residence
becomes safe rather than something to work around.

**While in `ollama.sh`, two adjacent staleness bugs:**

- The error message above tells the operator to re-run
  `52-install-gpu-operator.sh` in `new-setup-external-gpu`. That script was
  **deleted** in `e1d54a4` (GPU Operator handover). The label now comes from
  `complete-build/infrastructure/nvidia-operator.sh`. Fix the message wherever
  the block survives.
- `ollama.sh:230-231` waits on `deploy/ollama-embed-0` and
  `deploy/ollama-planner-cpu-0`, which l.172 records as **removed**. Harmless
  (`|| true`, and `rollout status` fails fast on a missing object) but it is
  misleading noise in the install log. Delete both lines with the §10 step 6
  cleanup.

---

### 2.4 Verify before moving on

```bash
/home/k8s/kube/kubectl get node inference-0 -o json | python3 -c "
import json,sys
l=json.load(sys.stdin)['metadata']['labels']
for k in sorted(l):
    if 'gpu' in k.lower(): print(f'{k}={l[k]}')"
/home/k8s/kube/kubectl get node inference-0 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

Assert `nvidia.com/gpu: 2`, `gpu.memory=32768`, `gpu.compute.major=7`,
`gpu.count=2`, and no surviving `p4` / `heterogeneous` / `pool-mixed` /
`v100-uuid` labels.

**Record, do not assert, `gpu.product`.** The previous card enumerated as
`Tesla-PG500-216` — a board code, which is what the driver falls back to when it
has no marketing name (§1). Two different cards, or a different driver, may
report something else entirely, and GFD's `nvidia.com/gpu.*` labels have already
proven unreliable on this node. Write down whatever it reports and reconcile it
with the §0 SKU finding; do not gate the step on a specific string.

---

## 3. Target topology

**One card per pod, two pods, `nvidia.com/gpu: 1` each.** No sharing config, no
UUID pinning, no new cluster machinery — allocatable is 2 and both units are
consumed by ordinary requests.

| | Card 0 — `vllm-executor` | Card 1 — `gpu-small-models` |
|---|---|---|
| Request | `nvidia.com/gpu: 1` | `nvidia.com/gpu: 1` |
| Contents | 32B AWQ, TP1 | 2 processes in **one container** |
| | | · planner 8B AWQ (vLLM, :8001) |
| | | · reranker BGE-reranker-v2-m3 (:8002) |

**Embeddings stay on CPU.** An earlier draft placed them on card 1 as a third
process on :8003. That was wrong — see §9.1. They remain on the
`ollama-embed-2..9` worker pods.

VRAM budget (Track A / AWQ figures — NVFP4 shifts these):

| Card 0 | GB | | Card 1 | GB |
|---|---|---|---|---|
| 32B AWQ weights | ~18 | | planner 8B AWQ weights | ~5 |
| KV @ `fp8_e5m2`, 57,344 ctx | ~7 | | planner KV, 16,384 ctx | ~2 |
| activations + CUDA graphs | ~3 | | reranker (568M, fp16) | ~1.5 |
| | | | 2× CUDA context overhead | ~1 |
| **total** | **~28 / 32** | | **total** | **~9.5 / 32** |

Card 1's ~22 GB of headroom is deliberate — it is where a larger planner, a
draft model, or (if §9.1's preconditions are ever met) a **batched** embedding
endpoint goes later.

> **These totals must agree with `--gpu-memory-utilization`, and the earlier
> draft's did not.** vLLM does not accept a KV size; it *derives* KV from
> `(utilization × total) − weights − activations`, then refuses to start if the
> result cannot hold `--max-model-len` tokens for one sequence:
> `The model's max seq len (N) is larger than the maximum number of tokens that
> can be stored in KV cache (M)`.
>
> Card 0 worked example, at the §5.1 rate of 128 KiB/token (8,192 tokens/GiB):
>
> | utilization | budget | − 18 weights − 3 act. | KV tokens | supports 65,536? |
> |---|---|---|---|---|
> | 0.90 | 28.8 GB | 7.8 GiB | ~63,900 | **no — fails at startup** |
> | 0.92 | 29.4 GB | 8.4 GiB | ~68,800 | yes |
>
> So `0.90` + `--max-model-len 65536` is **not a valid pair**. §8.1 uses
> `0.92` with `65536`; the table above quotes the more conservative
> `--max-model-len 57344`, which fits inside `0.90` with room to spare. Pick one
> pair and keep both places in sync. Re-run this arithmetic whenever the weight
> figure changes — an NVFP4 target at ~20.6 GB moves every row.

**Why one container with two processes.** Containers in a pod cannot share a
GPU device allocation (`nvidia.com/gpu: 1` is granted to one container), but
processes inside one container can. Plain CUDA context switching is adequate
here and needs **zero** device-plugin changes. §4 covers splitting them into
separate pods later if independent scaling or restart becomes worth the
machinery.

Note both of these run **per request** — the planner on every query, the
reranker on every query that retrieves. An earlier draft called card 1's tenants
"low-duty-cycle"; that is not true of either, and was one of the reasons
embeddings looked cheap to add there. Two per-request models on one V100 is
already worth measuring (§10.2) before adding a third.

**What this buys over the single-model draft:**

- Planner and executor stop contending for one card — the current documented pain.
- The stack gains a reranker, for ~1.5 GB. This is the largest
  retrieval-quality gain per GB available anywhere in the plan.
- Card 1 keeps ~22 GB free for a larger planner or a draft model.
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

- **Nothing, if §3's default stands.** With no sharing configured, allocatable
  is exactly the two physical devices, so `nvidia.com/gpu: 2` deterministically
  gets both distinct cards. **This is the common case and it is safe** — the
  concern below applies only once §4 Option B or C is in play.
- **Replica aliasing, but only under §4 B/C.** If the plugin is advertising
  replicas per card, a pod requesting 2 units could receive two replicas of the
  *same* physical card and TP2 would try to initialise two ranks on one GPU.
  Whether the plugin spreads across physical devices in that mode is
  **unverified** — test before depending on it. Do not let this deter TP2 under
  the default topology; it is not a risk there.
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
| **B** | per-device time-slicing in `devicePlugin.config` | pure ConfigMap change, no new daemon. `renameByDefault: true` + `sharing.timeSlicing.resources[].devices: [1]` to shard **only** card 1 into `nvidia.com/gpu.shared`. No memory isolation; budget by `--gpu-memory-utilization` convention. **Note this is not the field that failed in §2.0** — see below. |
| **C** | MPS via `devicePlugin.config` `sharing.mps` | best concurrency; Volta is exactly where hardware-isolated MPS begins, so V100 is well suited. Needs the `mps-control-daemon` DaemonSet, **untested on Talos here** — and the operator has already needed a validation-fix DaemonSet on this node (`GPU-OPERATOR-TALOS-NOTES.md`). MPS + CUDA graphs can also be fragile. |

Try in order A → B → C. Do not adopt B or C to reach the §3 target; they are
refinements to it.

**On B's prospects.** §2.0's failure was the plugin's **top-level `resources`**
field, used to advertise a renamed subset of devices — `Customizing the
'resources' field is not yet supported`. Option B uses
`sharing.timeSlicing.resources[]`, a *different* config surface: the list that
time-slicing itself is configured through, with `devices` selecting which
physical cards a given entry applies to. Conflating the two understates B's
chances. Still verify `devices` scoping against the deployed plugin version
before depending on it — but expect it to work, and treat a failure as news.

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
  `--gpu-memory-utilization 0.92`, `--max-num-seqs 4` — see §3 for why `0.90`
  does **not** pair with 65,536, and §8.1 for the canonical flag set. Raise only
  with measurements. The v1.2.1 notes explicitly describe conservative profiles
  "to reduce 32 GB V100 OOM risk".

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
      python3.12 python3.12-venv ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY registry-ca.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates
# Ubuntu 24.04 marks the system interpreter externally-managed (PEP 668), so a
# bare `pip install` fails. Use a venv and put it first on PATH.
RUN python3.12 -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
RUN pip install --no-cache-dir --upgrade pip
RUN pip install --no-cache-dir torch==2.10.0 --index-url https://download.pytorch.org/whl/cu128
COPY 1cat_vllm-1.5.0-cp312-cp312-linux_x86_64.whl /tmp/
RUN pip install --no-cache-dir /tmp/*.whl && rm /tmp/*.whl
ENV HF_HUB_OFFLINE=1 VLLM_ATTENTION_BACKEND=FLASH_ATTN_V100
ENTRYPOINT ["vllm"]
```

Two things the earlier draft got wrong here: `pip install` against the system
interpreter on Ubuntu 24.04 dies with `error: externally-managed-environment`
(the draft installed `python3.12-venv` but never created a venv), and
`python3-pip` is unnecessary once a venv provides its own. Both fixed above.

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
needs only `torch` + `sentence-transformers`, not the vLLM wheel. Build the planner's vLLM process from the image above, or accept one
combined image to avoid maintaining two — decide when writing it.

Publish both the way this cluster already does images: build with podman on
hierophant, push to `hierophant.hierocracy.home:5000`, mirror into the
in-cluster registry with skopeo (see `pull-podman-images.sh`, `seed-images.sh`).
Hierophant has **no sudo over batch SSH**, so build from an interactive session
or rootless.

---

## 7. Get the models onto the cluster

Model targets by role. The two 1Cat-recommended Track B repos and
`BAAI/bge-reranker-v2-m3` were confirmed public and ungated via the HF API
(2026-09-07); the two Track A entries are still unresolved — see open question 4:

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
  --gpu-memory-utilization 0.92 \
  --max-num-seqs 4 \
  --enable-prefix-caching \
  --swap-space 32 \
  --host 0.0.0.0 --port 8000
```

`0.92` is not arbitrary — it is the lowest value whose derived KV cache holds
65,536 tokens against ~18 GB of weights. See the worked table in §3. If the
executor model's weights change, recompute before changing anything else.

### 8.2 `gpu-small-models` — card 1

One container, two processes under a supervisor: planner vLLM on :8001
(`--gpu-memory-utilization 0.28`, `--max-model-len 16384`) and the reranker on
:8002. Two Services so callers address them independently. **Embeddings are not
here** — they stay on the CPU worker pods (§9.1).

**On `0.28`:** utilization is a fraction of the card's *total* memory, not of
what is free, so the planner's budget must cover its own weights. `0.12` × 32 GB
= 3.84 GB, which is **less than the ~5 GB of 8B AWQ weights alone** — vLLM would
fail before it ever allocated KV. `0.28` × 32 GB = 8.96 GB covers ~5 GB weights
+ ~2 GB KV at 16,384 tokens + headroom.

Because these share a card by plain context switching, **the sum of their memory
budgets must be set by convention** — nothing enforces it. Write the §3 budget
into the manifest as a comment.

**Start the planner first.** vLLM profiles free VRAM during initialisation to
size its KV cache. If the reranker is already resident it still fits at `0.28`,
but the ordering makes the profile deterministic and keeps a later utilization
bump from silently colliding with it. A supervisor that starts :8001, waits for
`/health`, then starts :8002 is worth the few extra lines.

**Probes need care: one pod, two ports.** A Kubernetes readiness probe targets a
single port, so probing only :8001 leaves the pod `Ready` while the reranker is
dead. Either expose one aggregate health endpoint that checks both locally and
probe that, or accept the blind spot **explicitly** in the manifest comment. Do not leave it implicit — a silently dead reranker
degrades retrieval quality without failing anything, which is the hardest class
of fault to notice. (Compare `rag-admin-api`'s `/api/health/all`, which
aggregates downstream service health the same way — OPERATIONS.md §5.3.)

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

**Decided approach: replace the Ollama client outright with a single
OpenAI-protocol client.** Not two clients behind an env-var switch — that was an
earlier recommendation in this document and is superseded. The detailed plan
lives in `complete-build/documentation/VLLM-CLIENT-MIGRATION-PLAN.md`; this
section is the summary. (A translating proxy such as LiteLLM was also considered
and rejected: it avoids the Go change but adds a hop, a component to run, and a
second place for timeouts to live.)

**Why one client is sufficient, given the staged order below.** Ollama also
serves an OpenAI-compatible `/v1` surface, and the mirrored image is
`ollama/ollama:0.15.6` — well past the versions that added
`/v1/chat/completions`, `/v1/embeddings` and `/v1/models`. So during the staging,
the *same* client talks to Ollama for the roles that have not moved and to vLLM
for the roles that have; only the URL and model name differ per role. Two
consequences worth being explicit about:

- The migration order below does **not** require keeping an Ollama-native
  client. Every role ends up on vLLM anyway, so a second client would exist only
  for the duration of the staging, and `/v1` already covers that.
- The refactor is **testable against the running cluster before vLLM exists**,
  which decouples the largest non-GPU risk from the hardware work in §0–§8.
  Do this first; it is the one piece here that needs no new node.

Verify `/v1/embeddings` actually answers on 0.15.6 before assuming the embedding
path can move; if it does not, only chat migrates and embeddings stay on `/api`.

**Three things the protocol swap costs or exposes:**

- **`load_duration` is unrecoverable.** OpenAI responses carry a `usage` block
  but none of Ollama's nanosecond timing fields. `ExecutionMetrics.LoadDurationUsec`
  becomes `0`, and `PromptEvalDurationUsec` degrades to time-to-first-token
  (streaming only). This feeds the `model_execution_metrics` hypertable
  (OPERATIONS.md §8.1), so load-duration panels flatline for **all** models, not
  just the executor. Accepted cost — but update the dashboards rather than
  leaving a mystery. Token counts survive, and streaming needs
  `stream_options: {include_usage: true}` to get them.
- **A latent health-check bug gets exposed.** `rag-worker/cmd/worker/main.go:79,90`
  assert the concrete type `client.(*ollama.OllamaClient)` and **return `nil`
  (pass)** for anything else — so a non-Ollama client reports healthy
  unconditionally. Must become an `interface{ Ping() error }` assertion, or the
  cutover has no working health signal at exactly the moment it matters.
- **The reranker does not fit the existing interface.** `ChatClient`
  (`rag-worker/internal/models/interfaces.go:9`) is only
  `Chat`/`ChatStream`/`GetEmbeddings`. A reranker is a new client type *and* a
  new pipeline stage, not a call-site swap — see below.

**The reranker is a new call site, not a migration.** Nothing in the pipeline
calls one today, so `rag-worker` needs a rerank step between the Qdrant search
and the executor call. This is net-new code and should be behind a feature flag
so retrieval quality can be A/B'd against the current path.

**Migration order** — the endpoints are independent, so do them one at a time
with the Ollama pod still running as rollback:

1. Executor → `vllm-executor`. Biggest win, smallest change.
2. Planner → `gpu-small-models`. Frees the last GPU Ollama pod.
3. Reranker — new, flagged off, enabled after A/B.

**Embeddings are NOT in the migration order.** They stay on the CPU worker pods.
See §9.1.

### 9.1 Embeddings stay on CPU — the batching precondition

An earlier draft of this plan moved embeddings to card 1 as step 3, and counted
"~8 embed pods' worth of worker CPU comes back" as a benefit. **That reasoning
was backwards on this cluster**, for one decisive reason:

> **Nothing in the embedding path batches.** `rag-ingestion/service.py:212` is
> `get_ollama_embeddings_with_retry(text: str, ...)` sending `"prompt": text` —
> one text per HTTP request. The Go side is `GetEmbeddings(text string)`
> (`rag-worker/internal/models/interfaces.go:12`), called in a per-sub-query loop
> in `pkg/pipeline/search.go`. `INGEST_BATCH_SIZE=20` is the **Qdrant upsert**
> batch, not an embedding batch.

GPU embedding wins almost entirely through batching. At batch=1 you pay a kernel
launch and a host↔device round trip per item while the GPU idles between
requests. `all-minilm:l6-v2` is 22M parameters — a single forward pass that CPU
SIMD handles well. So on the current code path a GPU endpoint is expected to be
**no faster end-to-end, possibly slower**, while consuming VRAM and SM time that
card 1 needs for the planner and reranker, both of which run per request (§3).

The scarcity is also the wrong way round. Worker CPU is comparatively free — and
`worker-3` in particular has capacity the rest of the stack is not using
(`complete-build` OPERATIONS.md §1.10). GPU is the contended resource. Freeing
CPU by spending GPU is a bad trade here.

**Preconditions to revisit. All of them, not any of them:**

1. **A batched embedding interface exists on both sides** — `GetEmbeddings([]string)`
   in Go and a list-valued `input` in Python. Without this, nothing downstream
   can present the GPU with a batch and the rest is moot.
2. **A measured CPU baseline exists** (§10.2) showing embeddings are actually a
   bottleneck. "The GPU is idle" is not a reason; a p95 that misses a target is.
3. **The batched GPU path beats batched CPU by a margin worth the VRAM** — and is
   compared against *card 1 under realistic planner + reranker load*, not against
   an otherwise-idle card.
4. **Vector equivalence is confirmed** before repointing `rag-ingestion` (below).

If those hold, the natural shape is **split by workload, not by model**: a
batched GPU endpoint used only by `rag-ingestion` for bulk work, with the query
path staying on CPU where batch=1 is inherent. One model, two endpoints, chosen
by caller.

> ⚠ **If embeddings are ever moved, the data hazard applies — and the bar is not
> bit-equality.** GPU and CPU inference of the same model differ in the low-order
> bits: different kernels, different accumulation order, possibly fp16 vs fp32.
> That is expected and harmless. Testing for identical vectors will always
> "fail" and would wrongly condemn the collection to re-ingestion.
>
> The right test is **cosine similarity against a sample of existing collection
> entries**, re-embedded on the GPU path: expect ≥ 0.9999 for the same model and
> pooling. Then confirm what actually matters — that top-k Qdrant results for a
> set of representative queries are unchanged in membership and near-unchanged in
> order. Perturbations at that magnitude do not move ANN neighbours.
>
> Re-ingest only if similarity drops materially (≠ same model, different pooling,
> or a different normalisation convention), or if top-k membership shifts. Note
> `vectors-<dim>` collection naming (OPERATIONS.md §4.3) means a genuine model
> change lands in a *different* collection anyway — the hazard is specifically
> the same-model-different-runtime case.

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
   ConfigMap block from `ollama.sh` (l.113-152 — **or earlier, per §2.3**), and
   trim the GPU chat models from `seed-models.sh` (`llama3.1`,
   `granite3.1-dense:8b`, `qwen2.5:32b`, `qwen3:32b` into `ollama-llama3` /
   `ollama-qwen32b`). Also delete the dead `rollout status` waits on
   `deploy/ollama-embed-0` and `deploy/ollama-planner-cpu-0`
   (`ollama.sh:230-231`; l.172 records both as removed).
7. Revisit §3.1 (executor at TP2) with real latency numbers in hand.

### 10.1 Check the timeout budget before benchmarking

§1 sets the expectation at roughly half the fork's headline throughput, and
first-token latency at 65,536 context with a cold prefix cache will be worse
than the current Ollama setup. Several timeouts sit in that path and a breach
looks like a stack failure rather than a slow model:

- **The Go E2E driver has a known failure mode here** — it returns empty answers
  when the LLM takes longer than ~30s, which reads as a broken pipeline. Run the
  isolated retrieval test (OPERATIONS.md §10.1.1) first to separate storage from
  inference before concluding anything from an E2E run.
- `REQUEST_TIMEOUT` in `llm-gateway` (Pulsar inference wait).
- `HYDRATION_TIMEOUT` (default 5m) and `QDRANT_SEARCH_TIMEOUT` in `rag-worker`
  (`internal/config/config.go`).
- The `startupProbe` budget from §8.3 — ~600s covers weight load plus CUDA graph
  capture, but confirm against the real CephFS read rate rather than assuming.

Raise these *before* step 3's benchmark, not after it produces a confusing
result. A slow first token is a tuning problem; a timeout is a red herring that
costs a day.

---

### 10.2 Timing tests to run once the node is up

**Every test here exists to answer a specific open question.** Numbers gathered
without a decision attached get quoted later as if they meant something. Record
raw output in `/tmp/rag-logs/` on hierophant alongside the date, image tag and
model id — a tok/s figure with no provenance is unusable in three weeks.

| # | Test | Answers | Can run before the node? |
|---|---|---|---|
| T1 | CPU embedding baseline | §9.1 precondition 2 — are embeddings even a bottleneck? | **yes, run now** |
| T2 | GPU embedding at batch=1 | §9.1 precondition 3, cheap half | no |
| T3 | Executor decode + TTFT vs Ollama | §10 step 3 — is vLLM actually better? | baseline half, yes |
| T4 | TP1 vs TP2 | §3.1 — worth the scheduling conflict? | no |
| T5 | Card 1 contention | §3 — do planner and reranker fit one card? | no |
| T6 | `marlin` vs `turbomind` | §8.3 — the fork declares no winner | no |
| T7 | Weight load from CephFS | §8.3 — is the 600s `startupProbe` right? | no |

#### T1 — CPU embedding baseline (run this now, it is the control)

The most useful measurement available before any hardware arrives, and the one
that decides §9.1. Run **on hierophant**, in an interactive session — this is
deliberately a script rather than a one-liner, because nesting `ssh` → `kubectl`
→ `sh -c` → `curl` → JSON needs five levels of quote escaping and will not
survive a copy-paste.

```bash
# On hierophant. Writes results to /tmp/rag-logs/embed-baseline-$(date +%F).txt
export KUBECONFIG=/home/k8s/kube/config/kubeconfig
KUBECTL=/home/k8s/kube/kubectl
OUT=/tmp/rag-logs/embed-baseline-$(date +%F).txt
mkdir -p /tmp/rag-logs

cat > /tmp/embed-bench.sh <<'SCRIPT'
#!/bin/sh
# ~1500-char payload, roughly one CHUNK_SIZE of prose
PROMPT=$(yes "the quick brown fox jumps over the lazy dog " | head -c 1500 | tr -d '\n')
URL=http://ollama-embed.llms-ollama.svc.cluster.local:11434/api/embeddings
for m in all-minilm:l6-v2 nomic-embed-text mxbai-embed-large; do
  for n in $(seq 1 20); do
    printf '{"model":"%s","prompt":"%s"}' "$m" "$PROMPT" > /tmp/body.json
    t=$(curl -s -o /dev/null -w '%{time_total}' "$URL" \
          -H 'Content-Type: application/json' --data @/tmp/body.json)
    echo "$m $t"
  done
done
SCRIPT

# The local shell expands $(cat ...) into ONE argv element, so the script text
# never passes through a second layer of quoting. This is why it works where a
# nested one-liner does not.
$KUBECTL -n llms-ollama run embed-bench --rm -i --restart=Never \
  --image=registry.container-registry.svc.cluster.local:5000/curlimages/curl \
  --overrides='{"spec":{"nodeSelector":{"role":"storage-node"}}}' \
  --command -- sh -c "$(cat /tmp/embed-bench.sh)" | tee "$OUT"

# p50 / p95 per model
awk '{a[$1]=a[$1]" "$2} END {for (m in a) {n=split(a[m],v," "); asort(v);
  printf "%-22s p50=%.3fs p95=%.3fs n=%d\n", m, v[int(n*0.5)+1], v[int(n*0.95)], n}}' "$OUT"
```

If `awk` lacks `asort` (mawk), pipe per-model values through `sort -n` instead.

Record, per model:

- **p50 / p95 single-text latency** at a realistic chunk size (~1500 chars, i.e.
  roughly `CHUNK_SIZE`), not a three-word string. Short inputs flatter CPU.
- **Throughput under concurrency** — the fan-out is 8 pods, so drive 8, 16 and 32
  concurrent requests and find where latency knees.
- **Ingestion-path throughput in chunks/sec**, measured end to end on a real
  file rather than synthesised — that is the number that matters for bulk work.
- **Query-path contribution**: sub-queries per request × p95, as a fraction of
  total request latency. If embedding is 2% of a RAG request, the whole GPU
  question is closed regardless of what T2 says.

**Decision rule:** if embedding is a small fraction of query latency *and*
ingestion throughput is acceptable, §9.1 stays closed and T2 is not worth
running.

#### T2 — GPU embedding at batch=1

Only if T1 shows a real bottleneck. Measure the *same* models on card 1 via a
throwaway pod, at batch=1, **and** with the planner and reranker under load —
comparing against an idle card is the mistake that makes GPU look good. Expect
GPU to lose or draw at batch=1; the point is to quantify by how much, and to
size what batching would have to buy to be worth the interface change.

#### T3 — Executor: Ollama baseline vs vLLM TP1

Capture the baseline **before** touching anything, since `ollama-qwen32b` gets
scaled to 0 during cutover (§10 step 1):

- **Decode tok/s**, sustained, at a fixed output length.
- **Time to first token** at ~1k, ~16k and ~65k prompt tokens. TTFT at long
  context is the number that breaks §10.1's timeouts, and it is the one most
  likely to regress.
- **Cold vs warm prefix cache** — RAG requests share long system and
  retrieved-context prefixes, so `--enable-prefix-caching` should show a large
  gap. If it does not, prefix caching is not working and §3.2's main
  justification for the 128 GB of host RAM is unproven.
- Same prompts, same output lengths, both engines. Do not compare a vLLM run
  against a remembered Ollama number.

**Expectation to hold yourself to:** §1 predicts roughly half the fork's headline
throughput, and that headline was a 4-card figure. A TP1-on-one-card result in
that region is a success, not a disappointment.

#### T4 — TP1 vs TP2

Only after Track A serves. §3.1's claim is that TP2 halves per-card weight bytes
read per token and so is worth up to ~2× on bandwidth-bound decode, minus
all-reduce. Measure decode tok/s and TTFT both ways at the same context length.
Fold in §0's NVLink-vs-PCIe finding when interpreting: `SYS` in `nvidia-smi
topo -m` means the all-reduce crosses sockets and the ceiling is much lower.

Remember TP2 consumes both cards, so this test requires taking card 1 down —
schedule it, do not stumble into it.

#### T5 — Card 1 contention

Two per-request models sharing one V100 by CUDA context switching (§3). Measure
planner p95 alone, reranker p95 alone, then both under concurrent load. If
either degrades badly, that is the trigger for §4 Option B or C — and the
evidence needed to justify the machinery.

#### T6 — `marlin` vs `turbomind`

`VLLM_SM70_QUANT_BACKEND` accepts both and the fork picks no winner. Same
prompts, same output length, decode tok/s each way. Cheap to run, one env var,
and worth doing once rather than guessing forever.

#### T7 — Weight load from CephFS

Time from container start to the first successful `/health`, for the ~18 GB
executor. This validates or corrects §8.3's ~600s `startupProbe` budget. Measure
twice — the second run benefits from host page cache (§3.2), so the **cold**
number is the one the probe must survive. A pod that restarts during a CephFS
degradation gets the cold path.

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
2. **Which V100 SKU, and NVLink or PCIe?** (§0.) Sets throughput
   expectations and whether §3.1 is worth pursuing.
3. **Driver version vs the CUDA 12.8 floor.** (§0.) Potential reinstall.
4. **Exact HF repo ids** for the Track A executor AWQ model and the 8B planner.
5. **Does v1.5.0 support TP2 for the QUASAR NVFP4 target,** or is TP4 a hard
   gate? (PR #445; DFlash2 PRs #426/#427.) Gates Track B only.
6. **Is the workload really single-stream?** The current config says yes
   (`OLLAMA_NUM_PARALLEL=1`, `max_num_seqs=1`). If concurrency is expected to
   rise, revisit §3.1 — at high concurrency two independent TP1 replicas beat
   one TP2 instance.
7. ~~Are GPU embeddings equivalent to the CPU vectors?~~ **CLOSED 2026-09-07 —
   embeddings stay on CPU** (§9.1). Nothing in the embedding path batches, so a
   GPU endpoint would be no faster and possibly slower while spending VRAM and
   SM time card 1 needs. The equivalence question only reopens if §9.1's four
   preconditions are met.
8. **Which §2.3 resolution?** Approach 1 (bring the `ollama.sh` pinning removal
   forward, so Ollama requests `nvidia.com/gpu: 1` properly) or Approach 2 (keep
   `gpu-v100-uuid` until §10 finishes). Approach 1 is preferred and also makes
   Ollama and vLLM safely co-resident. **Answer before starting §2** — it
   changes what §2.2 does.
9. **One image or two?** (§6.) The `gpu-small-models` container needs only
   `torch` + `sentence-transformers` for the reranker, but its planner process
   needs the vLLM wheel. One combined image is simpler to maintain; two are
   smaller and decouple rebuilds.

---

## Open items deliberately left unresolved

These are judgement calls that want measurements, not more analysis. Listed so
they are not mistaken for oversights:

- **TP1 vs TP2 for the executor** (§3.1) — decide from §10's latency numbers.
- **Track B** (NVFP4 + DFlash2 drafter, §5) — attempt only after Track A serves.
- **Appendix A** (122B MoE with expert offload) — experiment, not a target.
- **`marlin` vs `turbomind`** for `VLLM_SM70_QUANT_BACKEND` (§8.3) — the fork
  exposes both and declares no winner; benchmark on this hardware.
- **§4 Option A vs B vs C** for card 1 — start at A, escalate only if T5 shows
  planner/reranker contention, or independent restart becomes a real requirement.
- **Whether embeddings ever move to GPU** (§9.1) — closed for now; reopening
  needs a batched interface on both sides *and* T1 showing embeddings are
  actually a bottleneck. Run **T1 now**: it is the only test in §10.2 that does
  not need the new node, and it is the control for everything else.
