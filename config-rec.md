Based on the hardware analysis of **hierophant** and the service architecture defined in `complete-build`, here is the recommended configuration to support the high-performance RAG (Retrieval-Augmented Generation) stack.

#### 1. Hardware Resource Analysis & Optimization
**Host Resources:**
*   **CPU**: 2x Intel Xeon E5-2680 v4 (28 Cores / 56 Threads).
*   **RAM**: 251 GiB.
*   **GPUs**: 2x NVIDIA Tesla P4 (8GB VRAM each).
*   **Disks**: 4x 2TB SATA (Seagate ST2000DM008) + 4x 250GB NVMe SSDs (Netac).

**Recommendations:**
*   **CPU Pinning (NUMA Awareness)**:
    *   The Tesla P4 GPUs are attached to different NUMA nodes. To minimize latency for the **Ollama** inference service, the `inference-0` and `inference-1` VMs should be pinned to the CPUs on the same NUMA node as their respective GPUs.
    *   **Action**: Use `virsh edit` to set `<cpuset>` for these domains.
*   **RAM Overcommit Management**:
    *   Your current allocation is approximately **253GB** (3x3GB CP + 4x42GB Workers + 2x38GB Inference), which exceeds the physical **251GiB** ($\approx$ 269GB) when KVM overhead and Host OS needs (min 16GB) are considered.
    *   **Action**: Reduce Worker RAM to **36GB** and Inference RAM to **32GB**. This remains more than enough for **Qdrant** and **Ollama**, while preventing host-level OOM (Out Of Memory) swaps that would destroy performance.

---

#### 2. Ceph Configuration Best Practices
The RAG stack relies on **Pulsar** (messaging), **TimescaleDB** (relational), and **Qdrant** (vector). These are all IO-sensitive.

**Best Practice Configuration:**
*   **OSDs per Device**:
    *   **Current Setting**: `osdsPerDevice: 3` (in `cluster.yaml`).
    *   **Recommendation**: Change to **`osdsPerDevice: 1`**. 7200RPM SATA disks cannot handle the head thrashing caused by multiple OSDs. A single OSD will provide higher sequential throughput and lower latency for the databases.
*   **BlueStore Metadata Acceleration**:
    *   **Problem**: SATA disks are slow for Ceph's internal metadata (DB/WAL).
    *   **Recommendation**: Since you have 250GB NVMe drives, create a small **20GB virtual disk (qcow2 or partition)** on the NVMe for each worker. Attach it as `/dev/vdc`.
    *   **Rook Config**: Update `cluster.yaml` to use `/dev/vdc` as the `metadataDevice`. This offloads all Ceph metadata writes to NVMe, drastically improving the performance of **TimescaleDB** and **Pulsar**.
*   **Object Storage (RGW)**:
    *   The `rag-web-ui` uses S3 for document storage. Ensure the `object-store.yaml` is configured with a `metadataPool` that has `deviceClass: ssd` if you implement the metadata acceleration above.

---

#### 3. Service-Specific Tuning (Complete-Build Integration)
*   **Ollama (Inference)**:
    *   The Tesla P4 is limited to 8GB VRAM.
    *   **Best Practice**: Use `4-bit` or `5-bit` quantized models (GGUF/EXL2) to ensure the LLM fits entirely on the GPU. Avoid "Partial Offloading" to CPU, as the Pulsar-based async architecture will bottleneck if inference is slow.
*   **Qdrant (Vector DB)**:
    *   Qdrant uses memory-mapped files. High memory is good, but **Disk IOPS** are critical for initial index loading and WAL flushing. The metadata acceleration (Point 2) is the primary driver for Qdrant performance here.
*   **Pulsar (Message Bus)**:
    *   Pulsar's BookKeeper (ledger) is very sensitive to disk latency. Ensure the Ceph StorageClass used by Pulsar has `replicated` set to 3 and that the OSDs are accelerated by NVMe.

#### Summary of Proposed `cluster.yaml` Changes:
```yaml
storage:
  useAllNodes: true
  useAllDevices: false # Transition to explicit device selection for better control
  nodes:
    - name: "worker-0"
      devices:
        - name: "vdb" # The 2TB SATA Disk
          config:
            metadataDevice: "vdc" # The 20GB NVMe slice
            osdsPerDevice: "1"
    # Repeat for other workers
```

This configuration maximizes the high IOPS of your NVMe drives while leveraging the large capacity of the new 2TB SATA drives for the bulk data of the RAG stack.
