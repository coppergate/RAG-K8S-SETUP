# Project Guidelines
## Execution Environment
- **Target Host**: All installation scripts (starting from `kubernetes-app-setup`, `./setup-cluster/config-cluster.sh`, or `complete-build`) MUST be executed on the host machine named **hierophant**.
- **Current Environment**: The VM where this code is being edited and this chat session is **NOT** the host machine and is **NOT** responsible for running the installation.
- **Commands**: Commands like `sudo virsh`, `kubectl`, and `talosctl` are intended to run locally on **hierophant**.
- **Paths**: Absolute paths (e.g., `/mnt/hegemon-share/share/code/kubernetes-setup` or `/var/lib/libvirt/images/...`) are relative to the file system of **hierophant**.
  - Paths under `/mnt/hegemon-share` are cross-mounted and consistent between the local environment and **hierophant**. The filesystem is only shared at this mount point (from **hegemon**); other paths (like `/home`) are local to each machine.
## SSH & Remote Access
- **SSH**: SSH commands are intended to be executed from **hierophant** to other machines in the cluster. A user 'junie' has been added to 'hierophant' for this access.
- **Accessing Hierophant**: Use the `enable-junie-hierophant.sh` script to establish an SSH connection to the **hierophant** host if remote execution is needed.
  - When accessing **hierophant** from this environment, ALWAYS use the private key `~/.ssh/id_hierophant_access` and the user `junie`.
- **Non-Interactive Operations**: For any future remote actions or automated scripts, use non-interactive SSH/Kubernetes patterns (e.g., `ssh -o BatchMode=yes`, reasonable timeouts, `kubectl --request-timeout`) to avoid hangs on password prompts or interactive requests.
  - Scripts MUST NOT use interactive `read` prompts. Use environment variables (e.g., `FRESH_INSTALL=true`) for configuration.
- **Temporary Files & Journals**: When running scripts that need to write persistent state or logs (like journals), use `/tmp` or the user's home directory (`/home/junie`) to avoid permission issues on the shared `/mnt/hegemon-share` mount.
## Kubernetes (kubectl)
- **Plugin usage**: Use the Krew `rook-ceph` kubectl plugin when available (`kubectl rook-ceph ceph -n rook-ceph <cmd>`), with a safe fallback to `kubectl exec` if the plugin is not present.
- **Specific Paths on Hierophant**: When running `kubectl` commands on **hierophant**, you MUST use the following paths:
  - **Executable**: `/home/k8s/kube/kubectl`
  - **Kubeconfig**: `/home/k8s/kube/config/kubeconfig`
  - Example: `ssh -i ~/.ssh/id_hierophant_access junie@hierophant "export KUBECONFIG=/home/k8s/kube/config/kubeconfig && /home/k8s/kube/kubectl get pods"`
- ** USE SERVICE NAMES **: any interservice calls on k8s should use the service names and not the ip addresses.
## Database Access
- **Database Operations**: Database operations, schema modifications, and queries are intended to be executed on **hierophant** using the postgresql (timescaledb) database.
## Code Management & Versioning
- **Code Management**: If an edit process involves more than 5 lines of code, store the original file in a sub-directory matching its current structure under the **'/mnt/hegemon-share/share/code/ai-changes/original'** directory, and create a new file with the edited content.
  - Only store 1 file back; we don't need a full history, just a single file with the latest changes.
- **Versioning**: When repeatedly pushing images into the local cluster repository, version subsequent images with a major.minor.build number version starting with 1.0.0.
- **Git Branching Policy**:
  - Create a local git branch every day named 'work-YYYY-MM-DD' (e.g., work-2026-03-02).
  - Check the date on each change set, determine if a branch exists for today.
  - If there is no branch for today, ensure the latest local branch has been pushed to origin and create a new branch for the day.
- **Git Commit Policy**:
  - Commit all changes to the local branch in git any time changes are made.
  - **Commit message**: A simple timestamp (e.g., 2026-03-02 08:30).
  - **File Size Limit**: Do not commit any files larger than 1MB without asking first.
  - **Clean History (Rebase & Squash)**:
    - Mark fixup commits with `git commit --fixup <commit-hash>` when making small changes.
    - Rebase with autosquash: Run `git rebase -i --autosquash main` before pushing. This ensures commits are squashed before pushing.
    - Push safely: Use `git push --force-with-lease origin <branch>` if the branch was already pushed.
- **Daily Push**: Every day, make a new push to GIT with the current committed code.
## Document Processing (PDF)
- **PDF Generation**: Use `paps` for converting text files to PDF.
  - Example: `paps --format=pdf --paper=letter --font="Monospace 10" input.txt -o output.pdf`
- **PDF Parsing**: Use `pdftotext` (from `poppler-utils`) to extract text from PDF files for analysis.
  - Example: `pdftotext input.pdf output.txt`
## Operational Principles
- **CONTEXT**: This document ensures consistency and security by defining the roles and responsibilities of different components.
- **TEMPORAL IMPORTANCE**: DO NOT ASSUME that all scripts or other resources described are current. ALWAYS ask before including a new script to make sure it is relevant to the current asks.
- **SERVICE EXPOSURE**: All exposed services must use the `*.hierocracy.home` suffix (e.g., `grafana.rag.hierocracy.home`) for consistent internal routing.
- **Corrections**: If the user indicates that some aspect of the reasoning or implementation needs to be done in a different way, add the requirement to this document.
## pay attention
