# Project Guidelines

## Execution Environment
- **Target Host**: All installation scripts (starting from `kubernetes-app-setup`, `./setup-cluster/config-cluster.sh`, or `complete-build`) MUST be executed on the host machine named **hierophant**.
- **Current Environment**: The VM where this code is being edited and this chat session is **NOT** the host machine and is **NOT** responsible for running the installation.
- **Commands**: Commands like `sudo virsh`, `kubectl`, and `talosctl` are intended to run locally on **hierophant**.
- **Paths**: Absolute paths (e.g., `/mnt/hegemon-share/share/code/kubernetes-setup` or `/var/lib/libvirt/images/...`) are relative to the file system of **hierophant**.
  - Paths under `/mnt/hegemon-share` are cross-mounted and consistent between the local environment and **hierophant**. The filesystem is only shared at this mount point (from **hegemon**); other paths (like `/home`) are local to each machine.

## SSH & Remote Access
- **SSH**: SSH commands are intended to be executed from **hierophant** to other machines in the cluster. A user 'junie' has been added to 'hierophant' for this access.
- **Accessing Hierophant**: Use the `enable-junie-hierophant.sh` script to establish an SSH connection to the **hierophant host** if remote execution is needed.
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
- **USE SERVICE NAMES**: Any interservice calls on k8s should use the service names and not the ip addresses.
- **NODE AFFINITY**: When scheduling pods, make certain that all non-inference work that can be done off of the 'inference' nodes is done on the 'worker' nodes.
  - Don't use inference nodes for pods that don't need access to the GPU whenever possible.
  - Use inference nodes for pods that are processing inference requests.
  - Use worker nodes for storage, apm and any external interfacing where possible.
  - Use the role 'storage-node' for identifying nodes available for non-inference work.

## Database Access
- **Database Operations**: Database operations, schema modifications, and queries are intended to be executed on **hierophant** using the postgresql (timescaledb) database.

## Code Management & Versioning
- **Code Management**: If an edit process involves more than 5 lines of code, store the original file in a sub-directory matching its current structure under the **'/mnt/hegemon-share/share/code/_KUBERNETES_BUILD/ai-changes/original'** directory, and create a new file with the edited content.
  - Only store 1 file back; we don't need a full history, just a single file with the latest changes.
- **Versioning**: Maintain a `major.minor.build` versioning scheme starting with `1.0.0`.
  - Increment the `build` number for every service update within an iteration.
  - Increment the `minor` version for each new "Iteration" (e.g., Iteration 5 corresponds to `1.5.0`).
  - Update all image tags and Kubernetes deployment specifications accordingly when versioning up.
- **Change Logs**: Maintain a changelog in the repository to track significant changes and updates to code and configurations.
  - Use a structured JSON format with the datetime stamp and a brief description of the change.
  - The change log should be written to the `/mnt/hegemon-share/share/code/_KUBERNETES_BUILD/ai-changes` directory.
  - The change log should be a single file with the most recent changes at the top.
  - The changes should be recorded at the conclusion of each prompting session when the changes are made.
  - **NOTE**: The changelog does NOT need to be committed to git.
- **Deployment Verification**: Before running tests, ensure that the most recent version of the code is deployed and running.
  - Keep a list of all active services and their respective versions in a centralized location for easy reference.
- **Obfuscation for logs**: When cloaking a username or password, don't just replace characters with asterisks; change the length as well as the character type to avoid pattern recognition.
- **Search Optimization**: Handle local searches better. Use `--exclude-dir={registry-cache,image-source-cache,ai-changes}` or target specific directories (e.g., `grep -r "pattern" scripts/`) to keep searches fast.

## Git Policies
- **Branching Policy**:
  - Create a local git branch every day named `work-YYYY-MM-DD` (e.g., `work-2026-03-02`).
  - Check the date on each change set, determine if a branch exists for today.
  - If there is no branch for today, ensure the latest local branch has been pushed to origin and create a new branch for the day.
- **Commit Policy**:
  - Commit all changes to the local branch in git any time changes are made.
  - **Commit message**: A simple timestamp (e.g., `2026-03-02 08:30`).
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

## Resume Generation Environment
- **Output Resumes and Cover letters**: From the 'Job' directory solution should be generated into the 'working' directory.
- **Initial Generation**: When first generating a new set of documents, output them in markdown. **STOP and wait for user review** of the markdown files before proceeding to PDF generation.
- **Input Qualifications**: Import from the `./working` directory. Ingest the files in `./working` as a basis for the resume and cover letter composition.
- **Targeted Generation**: Ensure that the generated cover letters and resumes are tailored to the specific job requirements and applicant qualifications.
- **Session Edits**: While we are working on a new resume/cover, only update files that are in the 'working' directory.
- **Final Product**: Once the PDF is generated into the 'sent' directory AND the user has confirmed satisfaction, we can remove the 'working' documents and move the original job req to `./JOB-REQS`.
- **Content Authenticity**:
  - The RAG pipeline and related AI stack (Pulsar, Qdrant, Ollama, etc.) are **personal projects**. When addressing them in resumes and cover letters, treat them as such (e.g., under a "Projects" or "Technical Research" section, or explicitly as independent development). Do not attribute personal projects to previous employers unless that work was actually performed there.
  - Do **NOT** add any statements claiming experience, skills, or achievements that are not expressly found in the source documents from the `./working` directory or previous resumes being used as samples.
  - When we discuss language proficiency, ensure that the language is one that the resume subject actually uses.

## Operational Principles
- **CONTEXT**: This document ensures consistency and security by defining the roles and responsibilities of different components.
- **OPERATIONAL INSTRUCTIONS**: Maintain a document `OPERATIONS.md` in the project root to record basic tasks and procedures determined during development (e.g., build/push steps, test execution commands). Whenever project scanning is required to determine the correct procedure for a task, that task must be documented in `OPERATIONS.md` for future reference.
- **TEMPORAL IMPORTANCE**: DO NOT ASSUME that all scripts or other resources described are current. ALWAYS ask before including a new script to make sure it is relevant to the current asks.
- **SERVICE EXPOSURE**: All exposed services must use the `*.hierocracy.home` suffix (e.g., `grafana.rag.hierocracy.home`) for consistent internal routing.
- **Corrections**: If the user indicates that some aspect of the reasoning or implementation needs to be done in a different way, add the requirement to this document.
- **Output Formatting**: 
  - **Copyable Output Requirement**: Any commands, scripts, config blocks, or text the user is expected to copy/paste MUST be output as fenced code blocks.
  - **No Horizontal Scrolling**: Prefer multi-line command formatting with line continuations so code blocks stay readable and easy to copy without horizontal scroll.
  - **No Mixed Formatting for Copy Targets**: Do not place copy/paste content in prose paragraphs or bullet text; use code blocks only.
