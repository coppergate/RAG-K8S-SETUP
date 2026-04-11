# Operational Instructions

This document tracks basic tasks and procedures determined during development to ensure efficiency and avoid redundant logic parsing. These instructions are designed for the **Junie** agent to follow directly.

## 1. Cluster Fundamentals & Infrastructure

### 1.1 Storage Layout on Hierophant
- **Podman storage**: `/mnt/storage/containers/storage` — configured via `~/.config/containers/storage.conf`
- **Registry data**: `/mnt/storage/registry-data` — Docker registry image layers and manifests
- **VM disk images**: `/var/lib/libvirt/images/` — Talos ISOs (symlinked from shared mount)
- **Talos/kubectl configs**: `/home/k8s/kube/` — kubeconfig, kubectl binary
- **Registry TLS/config**: `/mnt/storage/registry-config/` — config.yml, tls.crt, tls.key
- **Pre-pulled LLM models**: `/mnt/storage/ollama-models/` — Ollama model blobs and manifests
- **DO NOT** store large data (container images, registry) on `/home` — it has limited capacity (~143G shared with system)

### 1.2 Host Reboot Recovery (Network & Routing)
If the host (**hierophant**) has been rebooted, the volatile IPTables rules and bridge configurations for external routing are lost. This manifests as a **Connection Timeout** or **No route to host** error when accessing cluster services (like `rag-admin-api`) from external VMs.

To recover the network state:
1. **Initialize Network**: Run the idempotent network initialization script to restore bridges and IPTables.
   ```bash
   # On hierophant:
   sudo /mnt/hegemon-share/share/code/kubernetes-setup/new-setup/00-init-network.sh
   ```
2. **Restore VM Connectivity**: If the network was initialized *after* VMs were already running, their interfaces may be detached from the bridge. Run the restoration script to perform a safe, ordered restart of the cluster.
   ```bash
   # On hierophant:
   sudo /mnt/hegemon-share/share/code/kubernetes-setup/new-setup/05-restore-vms.sh
   ```
   *Note: `05-restore-vms.sh` now automatically calls `00-init-network.sh` at the start.*

#### Prevention (Boot-time Automation)
To prevent routing issues after future reboots, ensure `00-init-network.sh` runs on every boot.
- **Recommended**: Add a `@reboot` entry to the `root` crontab on hierophant:
  ```text
  @reboot /mnt/hegemon-share/share/code/kubernetes-setup/new-setup/00-init-network.sh >> /var/log/network-init.log 2>&1
  ```
- **Alternative**: Create a systemd unit file (e.g., `rag-network-init.service`) that runs the script before `libvirtd.service`.

### 1.3 Cluster Maintenance (Rebooting the Host)
When performing a full host reboot on **hierophant**, use the following procedures to ensure a clean cluster shutdown and graceful recovery.

#### Graceful Shutdown
Before rebooting the host, execute the `cluster-shutdown.sh` script to drain nodes and scale down stateful services (Pulsar, Ceph, DB).

- **Script Location**: `../kubernetes-setup/cluster-shutdown.sh`
- **Execution**: MUST be run on **hierophant**.
```bash
# On hierophant:
cd /mnt/hegemon-share/share/code/kubernetes-setup
bash ./cluster-shutdown.sh
```
- **What it does**:
    0.  **Admission Controller Cleanup**: Deletes the `k8tz` `MutatingWebhookConfiguration` to prevent it from blocking the next cluster startup.
    1.  Scales down all non-system resources in a prioritized order (Apps -> Bus -> Infrastructure).
    2.  Waits for all pods in the scaled namespaces to fully terminate to ensure clean unmounting.
    3.  Quiesces Ceph cluster (sets maintenance flags like `noout`).
    4.  Drains all Kubernetes nodes (control-plane and worker/inference) while storage is still available.
    5.  Scales down Rook-Ceph components (mgr -> others -> osd -> mon).
    6.  Shuts down all cluster VMs via `virsh`.
    7.  Saves the original replica counts to `/home/k8s/kube/cluster-replicas.state`.

#### Rebooting
Once the script confirms all VMs have shut down, you can safely reboot the host.
```bash
sudo reboot
```

#### Graceful Startup
After the host is back up, execute the `cluster-startup.sh` script to restore the cluster state.

- **Script Location**: `../kubernetes-setup/cluster-startup.sh`
- **Execution**: MUST be run on **hierophant**.
```bash
# On hierophant:
cd /mnt/hegemon-share/share/code/kubernetes-setup
bash ./cluster-startup.sh
```
- **What it does**:
    1.  Detaches GPUs from the host PCI bus.
    2.  Starts all cluster VMs.
    3.  Waits for the Kubernetes API and all nodes to be Ready.
    4.  **Admission Controller Cleanup**: Deletes the `k8tz` `MutatingWebhookConfiguration` (if present) as a safeguard to ensure core networking (Flannel) can start without mutation deadlocks.
    5.  Uncordons all nodes.
    6.  Restores Rook-Ceph in order (mon -> osd -> others).
    7.  Unfreezes Ceph state (unsets maintenance flags).
    8.  Restores all other resources from `/home/k8s/kube/cluster-replicas.state` in the correct reverse-shutdown order (Infrastructure -> Bus -> Apps).
    9.  **Admission Controller Restoration**: Reinstalls the `k8tz` admission controller via `helm upgrade --install` once the cluster is stable.

### 1.4 Pulsar Infrastructure & Health
Pulsar is installed by `setup-complete.sh` (Step 1.5.8) — NOT by `setup-all.sh`.
`setup-all.sh` only deploys RAG services and **verifies** that Pulsar is already running.

#### Prerequisites
- **Rook-Ceph**: The `rook-ceph-block` StorageClass must exist (Pulsar PVCs depend on it).
- **cert-manager**: Must be running for Pulsar TLS certificates.
- Both are installed by `setup-01-basic.sh` (Step 1 of `setup-complete.sh`).

#### Installation Flow
1. `setup-complete.sh` → Step 1.5.8 calls `rag-stack/infrastructure/pulsar/install.sh`
2. `install.sh` creates namespace, labels nodes, adds Helm repo, runs `helm upgrade --install` with `--wait --timeout 60m`
3. Post-install verification checks all 4 component types (ZK, BK, Broker, Proxy) are running
4. `setup-complete.sh` → Step 1.5.8.1 calls `init-rag-pulsar.sh` to create tenant `rag-pipeline` and namespaces (`stage`, `data`, `operations`)

#### Standalone Pulsar Install (without full setup)
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "export KUBECONFIG=/home/k8s/kube/config/kubeconfig && \
   bash /mnt/hegemon-share/share/code/complete-build/rag-stack/infrastructure/pulsar/install.sh && \
   bash /mnt/hegemon-share/share/code/complete-build/rag-stack/infrastructure/pulsar/init-rag-pulsar.sh"
```

#### Verifying Pulsar Health
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "export KUBECONFIG=/home/k8s/kube/config/kubeconfig && \
   /home/k8s/kube/kubectl get pods -n apache-pulsar && \
   /home/k8s/kube/kubectl exec -n apache-pulsar pulsar-toolset-0 -- \
     /pulsar/bin/pulsar-admin tenants list"
```

#### Pulsar Initialization (Tenants and Namespaces)
If services fail with `no partitioned metadata for topic` or `Namespace not found`, ensure the RAG tenants and namespaces are provisioned:
1. **Script**: `rag-stack/infrastructure/pulsar/init-rag-pulsar.sh`
2. **Namespaces Created**: `rag-pipeline/stage`, `rag-pipeline/data`, `rag-pipeline/operations`, `rag-pipeline/dlq`.
3. **Run Command**:
   ```bash
   ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
     "bash /mnt/hegemon-share/share/code/complete-build/rag-stack/infrastructure/pulsar/init-rag-pulsar.sh"
   ```

### 1.5 APM Stack (Monitoring & Observability)

#### Grafana Dashboards
The RAG stack uses the following Grafana dashboards for monitoring:
- **RAG Stack Operational Overview** (`uid: rag-operations`): Main dashboard for high-level monitoring.
  - **Prompts & Responses (Rate)**: Monitors incoming user requests and worker completions.
  - **Avg Prompt/Response Size**: Tracks data volume in characters/bytes for prompts and responses.
  - **Pipeline Latency (P95)**: Tracks End-to-End (Gateway) and per-stage (Worker) P95 latency.
  - **Pulsar Bus Health**: Monitors message throughput across the pipeline.
  - **GPU Utilization (%)**: Displays cluster-wide GPU and memory utilization.
  - **System Errors**: Aggregates error rates from Gateway, Worker, DB, and Qdrant.
- **RAG Stack Performance Overview** (`uid: rag-performance`): Detailed performance and error metrics per service.
- **RAG Stack Logs & Errors** (`uid: rag-logs`): Loki-based dashboard for real-time log analysis and error tracking.

#### Custom Metrics
New metrics introduced in Iteration 9 for operational tracking:
- `gateway_prompt_size_bytes`: Histogram of incoming prompt sizes in `llm-gateway`.
- `worker_response_size_bytes`: Histogram of outgoing response sizes in `rag-worker`.

#### APM Stack TLS Configuration
As of version `2.2.11`, the APM stack is configured with TLS for internal communication:
1.  **Loki & Mimir (Gateways)**:
    -   Exposed on port **443** (HTTPS) via their respective gateway services.
    -   Gateways use NGINX with SSL enabled on port **8443**.
    -   Alloy and Grafana connect via `https://loki-gateway.monitoring.svc.cluster.local` and `https://mimir-gateway.monitoring.svc.cluster.local`.
    -   Trust is managed via the `registry-ca-cm` ConfigMap (mounted as `/etc/ssl/certs/ca.crt`).
2.  **Tempo**:
    -   **Push API (OTLP)**: Exposed on port **4318** (HTTPS). Alloy pushes traces securely.
    -   **Query API (REST)**: Exposed on port **3200** (HTTP). Grafana queries traces via plain HTTP to avoid handshake issues.
3.  **Grafana**:
    -   The `central-grafana` instance trusts the internal CA by mounting the `registry-ca-cm`.
    -   Datasources for Loki and Prometheus/Mimir use `https` with `tlsSkipVerify: true`.
    -   Datasource for Tempo uses `http://tempo.monitoring.svc.cluster.local:3200`.
4.  **Tempo Metrics Generator**:
    -   **Enabled**: As of version `2.2.13`, Tempo's `metrics_generator` is enabled to support TraceQL features like `rate()`.
    -   **Storage**: Uses `/var/tempo/generator/wal` on the `storage` volume.
    -   **Remote Write**: Pushes generated metrics back to Mimir via `https://mimir-gateway.monitoring.svc.cluster.local/api/v1/push`.

#### Alloy Scraping Strategy (Out-of-Order Prevention)
As of version `2.2.11`, Alloy (DaemonSet) uses **local pod discovery** for cluster-wide services (Pulsar, DCGM) to avoid `err-mimir-sample-out-of-order` errors.
-   **Mechanism**: Uses `discovery.kubernetes` with `role = "pod"`.
-   **Filter**: Relabels targets to `keep` only those where `__meta_kubernetes_pod_node_name` matches the local node (using `sys.env("HOSTNAME")`).
-   **Effect**: Each Alloy instance only scrapes pods on its own node, preventing duplicate series from being pushed to Mimir from multiple nodes.

### 1.6 TLS and Security
1.  **Management Guide**: Refer to [TLS-GUIDE.md](TLS-GUIDE.md) for step-by-step instructions on creating certificates, adding SANs, and managing trust.
2.  **Architecture**: Refer to [TLS-SECURITY.md](TLS-SECURITY.md) for the end-to-end security architecture.
3.  **Trust Distribution**: The combined CA certificate is managed via the `registry-ca-cm` ConfigMap in target namespaces.
4.  **Client Configuration**: Ensure applications use the `SSL_CERT_FILE` environment variable (set to `/etc/ssl/certs/ca-certificates.crt`).
5.  **Verification**: Use `kubectl get certificate -A` to verify certificate status.
6.  **Service TLS**: All RAG services (adapters, gateway, admin-api) now use TLS for their REST APIs (port 8080 or 443).
    -   Certificates and keys are mounted from secrets named `<service>-tls`.
    -   Probes use `scheme: HTTPS`.

### 1.7 Timezone (k8tz) Configuration
The cluster uses `k8tz` to inject the `Europe/London` (BST) timezone into all pods.
-   **Injection**: Pods receive a `k8tz` init container and a `TZ` environment variable.
-   **Inclusion**: All namespaces except `k8tz` itself are included (including `kube-system`).
-   **Verification**: `date` inside pods should show `BST`.

## 2. Operational Procedures & Session Management

### 2.1 Session Establishment (Operational Context)
Every new session for the **Junie** agent MUST establish the operational context by following these steps:
1.  **Branch Check**: Ensure the local git branch `work-YYYY-MM-DD` exists for the current date. If not, create it.
2.  **Versioning**: The single source of truth for the project version is the `CURRENT_VERSION` JSON file at the root of the project. 
    - Verify the current project version in `CURRENT_VERSION`.
    - Scripts like `build.sh` and `setup-all.sh` will read from this file by default.
    - `build.sh` performs automatic version incrementing when code changes are detected via hashing.
3.  **Changelog**: Add an initialization entry to `/mnt/hegemon-share/share/code/_KUBERNETES_BUILD/ai-changes/changelog.json` with the current datetime and "Environment initialization" description.
4.  **Operational Review**: Read `guidelines.md` and `OPERATIONS.md`.

### 2.2 Current Focus (Iteration 9)
As of version 2.5.5, the project is focusing on **Iteration 9 (Ingestion & Observability)**.
1.  **Ingestion Pipeline**: Prefix-based browsing, knowledge tags, targeted ingestion, and multi-file upload.
2.  **Prompt Aggregation**: Session-specific Pulsar topics to eliminate linear scanning.
3.  **Observability**: Custom metrics and Grafana dashboards for tracking health and GPU utilization.
4.  **Build System Optimization**: Shared context and parallel Kaniko builds.
5.  **Stability**: Resolved `k8tz` admission controller deadlocks and Rook-Ceph IO hangs.

### 2.3 Change Logs
- **Location**: `/mnt/hegemon-share/share/code/_KUBERNETES_BUILD/ai-changes/changelog.json`
- **Frequency**: Update at the conclusion of each prompting session when changes are made.
- **Format**: Structured JSON with datetime stamp and brief description (most recent at the top).
- **Git Policy**: The changelog does NOT need to be committed to git.

### 2.4 Journaling and Permissions
To avoid `Permission denied` errors on the shared `/mnt/hegemon-share` mount:
1.  **Log/State Storage**: Redirect any script that writes state files, locks, or persistent journals to local storage on **hierophant**.
2.  **Preferred Paths**: Use `/tmp` (for transient state) or `/home/junie` (for persistent user state).
3.  **Implementation**: Pass environment variables like `JOURNAL_DIR` or use `sh -c` to set context before running the target script.

## 3. Build & Deployment System

### 3.1 Cluster-Native Build Pipeline (Kaniko)
All RAG service image builds MUST go through the in-cluster Kaniko build pipeline. Do NOT use `podman build` or `docker build` on the host to build service images except for bootstrapping.

#### How the Build Pipeline Works
1. `build-all-on-cluster.sh` packages the `services/` directory into a tarball.
2. The tarball is uploaded to the Ceph S3 object store.
3. Build tasks (JSON messages) are published to the Pulsar `build-tasks` topic.
4. The `build-orchestrator` launches Kaniko `Job` resources.
5. Kaniko pulls the source, builds the image, and pushes it to the in-cluster registry.

#### Triggering a Build
1.  **Access Hierophant**: Use `./run-on-hierophant.sh` or SSH.
2.  **Versioning**: The version is read from `CURRENT_VERSION` at the project root.
3.  **Command**: Run `rag-stack/build.sh` (defaults to cluster-mode).
4.  **Wait Mode**: Use the `--wait` flag to wait for build completion.
5.  **Example Command**:
    ```bash
    ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
      "cd /mnt/hegemon-share/share/code/complete-build && \
       bash ./rag-stack/build.sh --mode cluster --wait"
    ```

### 3.2 Build Monitoring & Registry Maintenance

#### Monitoring Builds
- **Jobs**: Check Kaniko job status in the `build-pipeline` namespace: `kubectl get jobs -n build-pipeline`
- **Logs**: `kubectl logs -n build-pipeline deploy/build-orchestrator --tail=100`
- **Build Status Dashboard**: SSE-based live updates on port **8080**.

#### Registry Maintenance (Pruning)
To keep the registry clean, use the `registry-prune.sh` script to remove old image versions.
```bash
# On hierophant:
bash scripts/registry-prune.sh
```
After pruning, run garbage collection on the in-cluster registry pod:
```bash
/home/k8s/kube/kubectl exec -n container-registry deployment/registry -- registry garbage-collect /etc/docker/registry/config.yml
```

#### Verifying Images in Registry
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "for svc in rag-worker llm-gateway db-adapter qdrant-adapter \
              rag-ingestion rag-web-ui object-store-mgr rag-test-runner \
              rag-admin-api memory-controller; do \
     echo \"\$svc: \$(curl -sk https://registry.hierocracy.home:5000/v2/\$svc/tags/list)\"; \
   done"
```

### 3.3 Host-Based Bootstrap Build
Use this only for bootstrapping or when the cluster-native pipeline is unavailable.
1.  **Script**: `rag-stack/build-and-push.sh`.
2.  **Journaling**: Use `/home/junie/rag-build-journals` or `/tmp/.rag-build`.
3.  **Example Command**:
    ```bash
    ./run-on-hierophant.sh "cd /mnt/hegemon-share/share/code/complete-build/rag-stack && VERSION=X.Y.Z FORCE_BUILD=true ./build-and-push.sh"
    ```

### 3.4 Pre-deployment Go Dependency Check
To ensure all Go services compile correctly before launching a cluster-native build:
```bash
for svc in rag-stack/services/*; do
  if [ -d "$svc" ] && [ -f "$svc/go.mod" ]; then
    echo "--- Checking $svc ---"
    (cd "$svc" && go mod tidy && go build ./...)
  fi
done
```

## 4. Data & Model Management

### 4.1 Database Migrations & Secrets (TimescaleDB)
Manual schema updates should be applied from **hierophant** using the provided SQL files.
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "export KUBECONFIG=/home/k8s/kube/config/kubeconfig && \
   export DB_PASS=\$(/home/k8s/kube/kubectl get secret timescaledb-app -n timescaledb -o jsonpath='{.data.password}' | base64 -d) && \
   /home/k8s/kube/kubectl exec -it -n timescaledb timescaledb-rw-0 -- \
   env PGPASSWORD=\$DB_PASS psql -U app -d app -f /mnt/hegemon-share/share/code/complete-build/rag-stack/infrastructure/timescaledb/iteration-7-phase1-memory.sql"
```

#### TimescaleDB Secret
The `timescaledb-secret` in rag-system is created dynamically during install by `setup-all.sh`.
It fetches the real password from the `timescaledb-app` secret. **Do NOT use the hardcoded template file**.

### 4.2 Ent ORM Management (Shared)
Centralized in the **common** module.
1.  **Schema Definition**: `rag-stack/services/common/ent/schema/`.
2.  **Code Generation**: `go run -mod=mod entgo.io/ent/cmd/ent generate --feature sql/upsert ./ent/schema`
3.  **Service Integration**: Use client from `app-builds/common/ent`.

### 4.3 Storage and Collection Naming
- **Base Name**: Use `vectors`.
- **Dimension-Based**: Collections are named `vectors-<dim>` (e.g., `vectors-384`).
- **Isolation**: Tag-based filtering uses strict `must` match with UUID `tag_ids`.

### 4.4 LLM Model Management (Ollama)

#### Pre-Pulling and Caching Models
Models are cached at `/mnt/storage/ollama-models/` and pushed to the local registry.
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "cd /mnt/hegemon-share/share/code/complete-build/rag-stack/infrastructure/ollama && \
   bash ./push-models-to-cluster.sh"
```

#### Model Seeding (During Install)
`seed-models.sh` creates temporary seeder pods that pull models from the local registry into the PVCs. This is automatic if models are in the registry.

## 5. RAG Stack Architecture & Services

### 5.1 Service Configuration (Externalized Values)
- **RAG Ingestion**: `QDRANT_COLLECTION`, `INGEST_BATCH_SIZE`, `CHUNK_SIZE`, `CHUNK_OVERLAP`.
- **RAG Worker**: `QDRANT_COLLECTION`, `QDRANT_SEARCH_LIMIT`, `RECURSION_BUDGET`.
- **LLM Gateway**: `REQUEST_TIMEOUT` (Pulsar inference).

### 5.2 Prompt Aggregation (Session Topics)
Migrated to session-specific Pulsar topics to eliminate linear scanning.
- **Session Topics**: `persistent://rag-pipeline/sessions/<correlation_id>`
- **LLM Gateway**: Subscribes to the session topic for streaming.
- **RAG Worker**: Produces `StreamChunk` messages to the session topic.
- **Prompt Aggregator**: Aggregates all chunks from the session topic after completion.
- **Pulsar Namespace**: `rag-pipeline/sessions` (policies: 5m deletion, 30m TTL).

### 5.3 Health and Readiness Checks
All RAG services implement standardized endpoints:
-   `/healthz` (Liveness): Returns `200 OK` if the process is running.
-   `/readyz` (Readiness): Returns `200 OK` only if downstream dependencies are reachable.
-   `/api/health/all` (Admin API): Aggregates results from all services into a single JSON report.

#### Manual Verification
```bash
ssh -i ~/.ssh/id_hierophant_access junie@hierophant \
  "export KUBECONFIG=/home/k8s/kube/config/kubeconfig && \
   /home/k8s/kube/kubectl exec -n rag-system deploy/rag-admin-api -- \
   curl -sk https://localhost:8080/api/health/all"
```

### 5.4 Adding Support for New LLMs (Rag-Worker)
1.  Define implementation in `internal/models/<newmodel>`.
2.  Implement `Planner` and `Executor` interfaces.
3.  Update factory logic in `cmd/worker/main.go`.
4.  Set `PLANNER_MODEL`/`EXECUTOR_MODEL` environment variables.

## 6. Frontend Development (RAG Explorer)

### 6.1 Features and Routing
The RAG Explorer is the Flutter-based web application for managing the cluster.
- **Session Management**: Friendly names, selective chat.
- **LLM Interaction**: Waiting indicators, streaming chunks.
- **System Logging**: Flyout log panel with real-time feedback and source location propagation.
- **BFF Connectivity**: Proxied via `rag-admin-api` with standardized root-relative paths.

### 6.2 Local Development & Troubleshooting

#### Environment Setup (Fedora)
```bash
bash scripts/setup-flutter-linux.sh
```

#### Running Locally
```bash
cd rag-stack/services/rag-explorer
flutter run -d linux # Desktop app
flutter run -d chrome # Web browser
```

#### Troubleshooting (Flutter)
- **CMake Error**: Run `flutter clean` to resolve stale `CMAKE_INSTALL_PREFIX` issues.
- **Code Generation**: `flutter pub run build_runner build --delete-conflicting-outputs`

### 6.3 Cluster Deployment
1. **Build**: Trigger Kaniko build on hierophant.
2. **Deploy**: UI is deployed by `setup-all.sh`.
3. **Verification**: `https://rag-explorer.rag.hierocracy.home`

## 7. Testing & Verification

### 7.1 End-to-End Testing (E2E)
Full RAG stack E2E test suite.
```bash
./run-on-hierophant.sh "export VERSION=X.Y.Z && bash /mnt/hegemon-share/share/code/complete-build/rag-stack/tests/run-e2e-on-hierophant.sh"
```
The script performs connectivity checks, refreshes ConfigMaps, and launches the `rag-integration-test` Kubernetes Job.

### 7.2 Cross-Model Verification
Verifies multiple LLM model combinations (e.g., Llama + Granite).
```bash
./run-on-hierophant.sh "export VERSION=X.Y.Z && cd /mnt/hegemon-share/share/code/complete-build/rag-stack/tests && bash ./run-cross-model-tests.sh"
```

### 7.3 Unit and Integration Tests
- **Unit Tests**: `go test ./...` in the respective service directory.
- **Integration Tests**: `cd rag-stack/tests && VERSION=x.y.z bash ./run-tests.sh` (on hierophant).
- **Manual Verification**: Use `kubectl exec` and `curl` to check `/healthz` and `/readyz` endpoints.
