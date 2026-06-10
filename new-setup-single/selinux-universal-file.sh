#!/usr/bin/env bash
# Creates a custom SELinux policy to grant unrestricted access to a single file.
# Target: /data/usr/share/code/complete-build/CURRENT_VERSION

set -euo pipefail

TARGET_FILE="/data/usr/share/code/complete-build/CURRENT_VERSION"
TARGET_DIR="$(dirname "$TARGET_FILE")"
MODULE_NAME="universal_file"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "Working in $WORK_DIR"

# --- Step 1: Create the Type Enforcement file ---
cat > "$WORK_DIR/${MODULE_NAME}.te" <<'EOF'
policy_module(universal_file, 1.0)

require {
    attribute domain;
}

type universal_file_t;
files_type(universal_file_t)

allow domain universal_file_t:file manage_file_perms;
allow domain universal_file_t:file relabel_file_perms;
EOF

# --- Step 2: Create the File Contexts file ---
# Escape any regex special chars in the path for the fc file
ESCAPED_PATH="$(printf '%s' "$TARGET_FILE" | sed 's|[.+?{}()|[\^$]|\\&|g')"
cat > "$WORK_DIR/${MODULE_NAME}.fc" <<EOF
${ESCAPED_PATH}    --    gen_context(system_u:object_r:universal_file_t,s0)
EOF

# --- Step 3: Compile and load the policy module ---

# Ensure selinux-policy-devel is installed (provides the Makefile)
if [[ ! -f /usr/share/selinux/devel/Makefile ]]; then
    echo "Installing selinux-policy-devel..."
    dnf install -y selinux-policy-devel
fi

cd "$WORK_DIR"
make -f /usr/share/selinux/devel/Makefile "${MODULE_NAME}.pp"
semodule -i "${MODULE_NAME}.pp"
echo "SELinux policy module '${MODULE_NAME}' loaded."

# --- Step 4: Ensure the target file exists, then apply the context ---
if [[ ! -f "$TARGET_FILE" ]]; then
    echo "WARNING: $TARGET_FILE does not exist yet. Creating parent directory and empty file."
    mkdir -p "$TARGET_DIR"
    touch "$TARGET_FILE"
fi

restorecon -v "$TARGET_FILE"
echo "SELinux context applied to $TARGET_FILE."

# --- Standard DAC permissions ---
chmod 666 "$TARGET_FILE"
echo "chmod 666 applied (read/write for all, no execute needed for a version file)."

echo "Done. Current context:"
ls -lZ "$TARGET_FILE"
