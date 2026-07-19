#!/bin/bash
# journal-helper.sh - Helper functions for journaling installation steps
# Goal:
# - Avoid permission issues and collisions between different scripts with the same name (e.g., install.sh)
# - Prefer per-user writable location, overridable via INSTALL_JOURNAL_DIR

# Determine journal directory (override with INSTALL_JOURNAL_DIR, else per-user dir)
JOURNAL_FILE_DIR="${INSTALL_JOURNAL_DIR:-$HOME/.kubernetes-setup/journal}"
# Determine a safe temporary directory for the user (override with INSTALL_TMP_DIR)
SAFE_TMP_DIR="${INSTALL_TMP_DIR:-$HOME/.kubernetes-setup/tmp}"
export SAFE_TMP_DIR
export TMPDIR="$SAFE_TMP_DIR"

# Ensure directory exists and is private to the user
mkdir -p "$JOURNAL_FILE_DIR" "$SAFE_TMP_DIR"
chmod 700 "$JOURNAL_FILE_DIR" "$SAFE_TMP_DIR" 2>/dev/null || true

# Resolve the calling script path for uniqueness (works when sourced)
# BASH_SOURCE[0] = this file, BASH_SOURCE[1] = caller when sourced; fall back to $0
__caller_ref="${BASH_SOURCE[1]:-${0}}"
# Try to canonicalize the path; if not possible, keep as-is
if command -v readlink >/dev/null 2>&1; then
  __caller_abs="$(readlink -f "${__caller_ref}" 2>/dev/null || echo "${__caller_ref}")"
else
  __caller_abs="${__caller_ref}"
fi
__script_name="$(basename "${__caller_abs}")"
# Short unique suffix from the absolute path to avoid collisions across identically named scripts
__script_id="$(echo -n "${__caller_abs}" | sha256sum 2>/dev/null | cut -c1-12)"
JOURNAL_FILE="${JOURNAL_FILE_DIR}/${__script_name}-${__script_id}.journal"

function init_journal() {
    if [[ -f "$JOURNAL_FILE" ]]; then
        echo "Journal file '$JOURNAL_FILE' exists from a previous run."
        if [[ "${FRESH_INSTALL:-false}" == "true" ]]; then
            rm -f "$JOURNAL_FILE"
            echo "FRESH_INSTALL=true detected. Starting fresh..."
        else
            echo "Continuing from last failure (Set FRESH_INSTALL=true to start fresh)..."
        fi
    fi
    echo "Using journal: $JOURNAL_FILE"
}

function is_step_done() {
    local step_name="$1"
    if [[ -f "$JOURNAL_FILE" ]] && grep -q "^$step_name$" "$JOURNAL_FILE"; then
        echo "Skipping already completed step: $step_name"
        return 0
    fi
    return 1
}

function mark_step_done() {
    local step_name="$1"
    # Ensure file exists with user-only write perms to avoid future removal prompts
    touch "$JOURNAL_FILE"
    chmod 600 "$JOURNAL_FILE" 2>/dev/null || true
    echo "$step_name" >> "$JOURNAL_FILE"
    echo "Completed step: $step_name"
}

function clear_journal() {
    if [[ -f "$JOURNAL_FILE" ]]; then
        rm -f "$JOURNAL_FILE"
        echo "Installation complete. Journal cleared."
    fi
}
