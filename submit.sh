#!/usr/bin/env bash
# Hardened helper for running the remaining IBM Guestbook lab steps in the
# Theia/OpenShift terminal. Run this FROM Theia, not from the local machine —
# it needs a real docker/kubectl/ibmcloud pointed at your cluster.
#
# Usage:
#   chmod +x submit.sh   (first time, on Linux/Theia)
#   export GUESTBOOK_NAMESPACE=sn-labs-rowannepulan
#   ./submit.sh <command>
#
# Commands:
#   crimages      build+push the v1 image, capture -> submissions/crimages
#   hpa           create the HPA (idempotent), capture -> submissions/hpa
#   loadtest      idempotently (re)start the load generator
#   hpa2          watch the HPA scale up, capture -> submissions/hpa2
#   forward       safely port-forward to the guestbook pod
#   upguestbook   verify v2 files, build+push v2 image, verify digest changed
#                 -> submissions/upguestbook
#   deployment    kubectl apply -f deployment.yml -> submissions/deployment
#   rev           capture both rollout-history commands -> submissions/rev
#   rollback      safely roll back one revision (never revision 1)
#   rs            kubectl get rs after rollback -> submissions/rs
#
# Every "real" step tees its actual command output straight into the matching
# submissions/ file. Nothing here fabricates or guesses at output.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# REQUIRED: your real IBM Cloud namespace. Get it with `ibmcloud cr namespace-list`.
# Set it once per shell so it's never silently hardcoded in this script:
#   export GUESTBOOK_NAMESPACE=sn-labs-rowannepulan
NAMESPACE="${GUESTBOOK_NAMESPACE:?Set GUESTBOOK_NAMESPACE first, e.g.: export GUESTBOOK_NAMESPACE=sn-labs-rowannepulan}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
APP_DIR="$REPO_ROOT/v1/guestbook"
SUB_DIR="$REPO_ROOT/submissions"
IMAGE="us.icr.io/${NAMESPACE}/guestbook:v1"
DIGEST_FILE="$REPO_ROOT/.last-digest"

usage() {
    sed -n '2,29p' "$0"
}

# ---------------------------------------------------------------------------
# Step: v1 image build/push (already captured for real — kept for completeness
# and re-runs only if you explicitly ask for it).
# ---------------------------------------------------------------------------
crimages() {
    cd "$APP_DIR"
    docker build . -t "$IMAGE"
    docker push "$IMAGE"
    ibmcloud cr images | tee "$SUB_DIR/crimages"
}

# ---------------------------------------------------------------------------
# Step: HPA creation (idempotent)
# ---------------------------------------------------------------------------
hpa() {
    cd "$APP_DIR"
    if kubectl get hpa guestbook >/dev/null 2>&1; then
        echo "HPA 'guestbook' already exists — skipping creation, just capturing current state." >&2
        kubectl get hpa guestbook | tee "$SUB_DIR/hpa"
        return 0
    fi
    kubectl autoscale deployment guestbook --cpu-percent=5 --min=1 --max=10
    kubectl get hpa guestbook | tee "$SUB_DIR/hpa"
}

# ---------------------------------------------------------------------------
# Step: load generator (idempotent, quota-aware)
# ---------------------------------------------------------------------------
loadtest() {
    cd "$APP_DIR"

    kubectl delete pod load-generator --ignore-not-found --force --grace-period=0

    # Abort if limits.memory (or limits.cpu) is already near its hard cap —
    # launching another pod into an exhausted quota just errors out.
    local quota
    quota="$(kubectl describe resourcequota 2>/dev/null || true)"
    if [ -n "$quota" ]; then
        for resource in "limits.memory" "limits.cpu"; do
            local line used hard pct
            line="$(echo "$quota" | grep -i "^${resource}" || true)"
            if [ -n "$line" ]; then
                used="$(echo "$line" | awk '{print $2}' | tr -dc '0-9')"
                hard="$(echo "$line" | awk '{print $4}' | tr -dc '0-9')"
                if [ -n "$used" ] && [ -n "$hard" ] && [ "$hard" -gt 0 ]; then
                    pct=$((used * 100 / hard))
                    if [ "$pct" -ge 80 ]; then
                        echo "WARNING: ${resource} usage is at ${pct}% of the resource quota hard cap." >&2
                        echo "Aborting load test to avoid a quota error. Free up resources first." >&2
                        return 1
                    fi
                fi
            fi
        done
    fi

    kubectl run load-generator --image=busybox --restart=Never -- \
        /bin/sh -c "while true; do wget -q -O- http://guestbook:3000; done"

    echo "Load generator (re)started. Next: ./submit.sh hpa2"
}

# ---------------------------------------------------------------------------
# Step: watch HPA scale up (Ctrl+C once you see replicas > 0, output is
# captured as it streams)
# ---------------------------------------------------------------------------
hpa2() {
    cd "$APP_DIR"
    kubectl get hpa guestbook --watch | tee "$SUB_DIR/hpa2"
}

# ---------------------------------------------------------------------------
# Step: safe port-forward
# ---------------------------------------------------------------------------
forward() {
    cd "$APP_DIR"
    pkill -f "port-forward" || true
    kubectl wait --for=condition=Ready pod -l app=guestbook --timeout=120s
    kubectl port-forward deployment/guestbook 3000:3000
}

# ---------------------------------------------------------------------------
# Step: verify local v2 files before ever building against them
# ---------------------------------------------------------------------------
verify_v2_files() {
    cd "$APP_DIR"

    if ! grep -q "<title>Guestbook - v2</title>" public/index.html \
        || ! grep -q "<h1>Guestbook - v2</h1>" public/index.html; then
        echo "ABORT: public/index.html does not contain the expected v2 title/h1." >&2
        grep -n "<title>\|<h1>" public/index.html >&2 || true
        return 1
    fi

    if ! grep -q "cpu: 5m" deployment.yml || ! grep -q "cpu: 2m" deployment.yml; then
        echo "ABORT: deployment.yml does not have the expected 5m/2m CPU values." >&2
        return 1
    fi

    if grep -q "REPLACE_NAMESPACE" deployment.yml; then
        echo "NOTE: deployment.yml still has the REPLACE_NAMESPACE placeholder." >&2
        echo "That's fine for the docker build (image tag isn't read from the yaml)," >&2
        echo "but remember to substitute it before 'kubectl apply'." >&2
    fi

    echo "Verified: index.html and deployment.yml contain the expected v2 changes."
}

# ---------------------------------------------------------------------------
# Step: v2 image build/push, with pre- and post-build verification
# ---------------------------------------------------------------------------
upguestbook() {
    cd "$APP_DIR"
    verify_v2_files

    docker build . -t "$IMAGE" | tee "$SUB_DIR/upguestbook"

    local push_output
    push_output="$(docker push "$IMAGE" | tee -a "$SUB_DIR/upguestbook")"

    local new_digest
    new_digest="$(echo "$push_output" | grep -oE 'sha256:[0-9a-f]{64}' | tail -1)"

    if [ -z "$new_digest" ]; then
        echo "WARNING: could not parse a digest from push output — check submissions/upguestbook by hand." >&2
        return 0
    fi

    if [ -f "$DIGEST_FILE" ]; then
        local old_digest
        old_digest="$(cat "$DIGEST_FILE")"
        if [ "$new_digest" = "$old_digest" ]; then
            echo "############################################################" >&2
            echo "WARNING: pushed digest is IDENTICAL to the last recorded one:" >&2
            echo "  $new_digest" >&2
            echo "Your file edits almost certainly did NOT reach this image —" >&2
            echo "check for CACHED layers above, and re-run 'verify_v2_files'." >&2
            echo "############################################################" >&2
        else
            echo "Digest changed: $old_digest -> $new_digest (edits took effect)."
        fi
    else
        echo "No prior digest on record. Recording $new_digest as the baseline."
    fi
    echo "$new_digest" > "$DIGEST_FILE"
}

# ---------------------------------------------------------------------------
# Step: apply the updated deployment.yml
# ---------------------------------------------------------------------------
deployment() {
    cd "$APP_DIR"
    if grep -q "REPLACE_NAMESPACE" deployment.yml; then
        echo "ABORT: deployment.yml still has the REPLACE_NAMESPACE placeholder." >&2
        echo "Substitute your real namespace in the image line before applying." >&2
        return 1
    fi
    kubectl apply -f deployment.yml | tee "$SUB_DIR/deployment"
    if grep -q "unchanged" "$SUB_DIR/deployment"; then
        echo "WARNING: kubectl apply reported 'unchanged' — nothing was actually updated." >&2
    fi
}

# ---------------------------------------------------------------------------
# Step: rollout history
# ---------------------------------------------------------------------------
rev() {
    cd "$APP_DIR"
    {
        echo "=== kubectl rollout history deployment/guestbook ==="
        kubectl rollout history deployment/guestbook
        echo
        echo "=== kubectl rollout history deployments guestbook --revision=2 ==="
        kubectl rollout history deployments guestbook --revision=2
    } | tee "$SUB_DIR/rev"
}

# ---------------------------------------------------------------------------
# Step: safe rollback — one step back, never a hardcoded revision, never rev 1
# ---------------------------------------------------------------------------
rollback() {
    cd "$APP_DIR"
    kubectl rollout undo deployment/guestbook
    kubectl rollout status deployment/guestbook
}

# ---------------------------------------------------------------------------
# Step: replica sets after rollback
# ---------------------------------------------------------------------------
rs() {
    cd "$APP_DIR"
    kubectl get rs | tee "$SUB_DIR/rs"
}

# ---------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    case "$cmd" in
        crimages|hpa|loadtest|hpa2|forward|upguestbook|deployment|rev|rollback|rs)
            "$cmd"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
