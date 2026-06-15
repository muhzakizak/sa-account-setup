#!/usr/bin/env bash
# Onboarding — create a dedicated GCP project, enable APIs, and grant the SaaS
# service account access to it. Runs in the client's Cloud Shell (auth'd as them).
set -euo pipefail

# ---- EDIT THESE for your SaaS (or inject when generating the link) ----
SAAS_SA_EMAIL="${byosa-setup-service-account@test-byosa-setup-project.iam.gserviceaccount.com}"
# Minimum roles so YOUR backend can later enable APIs + create/operate the workload SA.
# Keep this list tight — this is privileged, consented, revocable access (not a hidden backdoor).
#   serviceAccountCreator  -> create SAs only (narrower than serviceAccountAdmin)
#   serviceAccountTokenCreator -> keyless: mint SHORT-LIVED tokens by impersonation (preferred)
#   (swap to roles/iam.serviceAccountKeyAdmin only if you must create downloadable key files)
ROLES="${ROLES:-roles/serviceusage.serviceUsageAdmin roles/iam.serviceAccountCreator roles/iam.serviceAccountTokenCreator}"
# APIs needed just so the grant + your backend calls work:
APIS="${APIS:-cloudresourcemanager.googleapis.com serviceusage.googleapis.com iam.googleapis.com}"
# ----------------------------------------------------------------------

# Pick an existing project: $1 if given, else single available project, else prompt.
choose_existing_project() {
  mapfile -t PROJS < <(gcloud projects list --format="value(projectId)" 2>/dev/null)
  if [[ ${#PROJS[@]} -eq 0 ]]; then
    echo "    No existing projects available either." >&2
    echo "    Ask a Google Cloud admin to grant you 'Project Creator', or to create" >&2
    echo "    a project for Test, then click the setup link again." >&2
    exit 1
  elif [[ ${#PROJS[@]} -eq 1 ]]; then
    PROJECT_ID="${PROJS[0]}"
    echo "    Using your existing project: ${PROJECT_ID}"
  else
    echo "    Choose an existing project to use:"
    select p in "${PROJS[@]}"; do [[ -n "${p:-}" ]] && { PROJECT_ID="$p"; break; }; done
  fi
}

# Pass an existing project ID as $1 to reuse it; otherwise try to create a new one.
PROJECT_ID="${1:-}"

if [[ -z "${PROJECT_ID}" ]]; then
  # NAME is a display name — does NOT need to be unique.
  # ID must be globally unique across all of Google Cloud and is permanent (lowercase, no spaces).
  PROJECT_NAME="Test Saas Backup $(date +%s)"
  NEW_ID="test-backup-$(date +%s)"   # epoch keeps the ID globally unique
  echo "==> Creating project: ${PROJECT_NAME}  (id: ${NEW_ID})"
  if gcloud projects create "${NEW_ID}" --name="${PROJECT_NAME}" 2>/tmp/createerr; then
    PROJECT_ID="${NEW_ID}"
  else
    echo "⚠️  Couldn't create a new project (likely no permission/quota in your org):"
    sed 's/^/      /' /tmp/createerr >&2
    echo "    Falling back to an existing project..."
    choose_existing_project
  fi
fi
gcloud config set project "${PROJECT_ID}" >/dev/null 2>&1 || true

echo "==> Project:        ${PROJECT_ID}"
echo "==> Granting:       ${SAAS_SA_EMAIL}"
echo "==> Roles:          ${ROLES}"
echo "==> Enabling APIs:  ${APIS}"
echo

echo "==> Enabling required APIs..."
if ! gcloud services enable ${APIS} --project="${PROJECT_ID}" 2>/tmp/apierr; then
  if grep -qi "billing" /tmp/apierr; then
    echo "⚠️  This project has no billing account linked, which is blocking API enablement." >&2
    echo "    Link one (Billing → Link a billing account) or re-run and pick a project" >&2
    echo "    that already has billing enabled." >&2
    sed 's/^/      /' /tmp/apierr >&2
    exit 2
  fi
  cat /tmp/apierr >&2; exit 1
fi

echo "==> Adding IAM bindings..."
for ROLE in ${ROLES}; do
  echo "    - ${ROLE}"
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SAAS_SA_EMAIL}" \
    --role="${ROLE}" \
    --condition=None >/dev/null
done

echo
echo "✅ Done. ${SAAS_SA_EMAIL} can now provision ${PROJECT_ID}."
echo "   Return to the dashboard — setup continues automatically."
