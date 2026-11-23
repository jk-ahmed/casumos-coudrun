# Deploying Causmos to Cloud Run

Step-by-step guide for deploying this app to Google Cloud Run using
[install_cloudrun.sh](install_cloudrun.sh).

| Setting | Value |
|---|---|
| Project | `celestial-feat-513918-q9` |
| Region | `asia-south1` (Mumbai) |
| Cloud Run service | `causmos-service` |
| Runtime service account | `sa-gads-ai-runner@celestial-feat-513918-q9.iam.gserviceaccount.com` |
| Image bucket | `causmos-adxai-st` (private) |
| Firestore database | `causmos-db` |

These values are set at the top of `install_cloudrun.sh`. Change them there if the target changes.

## How it fits together

- The app is a Flask app run by Gunicorn in the [Dockerfile](Dockerfile). `gcloud run deploy --source .` builds the image with Cloud Build and deploys it.
- Users sign in with Google OAuth. Their own credentials are used to read Google Ads, GA4, Sheets and BigQuery data and to create Slides.
- The service account is used for Secret Manager, Firestore (session storage), and the image bucket.
- Charts exported to Slides are uploaded to the bucket. The Slides API fetches them through a short-lived signed URL, so the bucket does not need to be public.
- `app.yaml` is for App Engine only. It is not used by this deployment.

## 1. Prerequisites

### Tools
- `gcloud` CLI, signed in as an account with the roles below. Check with `gcloud auth list`; switch with `gcloud auth login <account>`.
- Bash (Cloud Shell or Git Bash). The script will not run in `cmd` or PowerShell.

### Roles for the person deploying
Cloud Run Admin, Cloud Build Editor, Artifact Registry Writer/Admin, Service Account User, Secret Manager Admin or Accessor, Cloud Datastore Owner, Storage Admin.

### Roles for the runtime service account
`sa-gads-ai-runner` needs: Secret Manager Secret Accessor, Cloud Datastore User, BigQuery Job User, Service Account Token Creator (used to sign image URLs), and Storage Object Admin or Object User on the bucket.

The script makes no IAM changes. If something is missing, ask a project admin.

### APIs enabled on the project
Cloud Run, Artifact Registry, Cloud Build, Cloud Resource Manager, IAM Credentials, Google Ads, Analytics Admin, Analytics Data, Firestore, Sheets, Slides, Drive, Secret Manager, BigQuery.

Check with `gcloud services list --enabled --project=celestial-feat-513918-q9`. The script tries to enable them but only warns if you lack permission.

## 2. Create the OAuth client

1. Open Google Cloud Console → APIs & Services → Credentials in the project.
2. Configure the OAuth consent screen if prompted.
3. Create credentials → OAuth client ID → **Web application**.
4. Download the JSON. It has a top-level `web` key with `client_id`, `client_secret` and `redirect_uris`.

You add the redirect URI after the first deploy (step 5), because the Cloud Run URL is not known yet.

## 3. Create the secrets

Create these four secrets in Secret Manager. Names are case-sensitive and the script stops if any is missing.

| Secret | Value |
|---|---|
| `flask_secret_key` | A random string. Generate with `openssl rand -hex 32`. |
| `client_secret` | The full OAuth client JSON from step 2 (not a service-account key). |
| `developer_token` | Google Ads developer token (Google Ads → Tools → API Center), as plain text. |
| `image_bucket` | `causmos-adxai-st`, with no `gs://` and no trailing newline. |

From the CLI (the `printf` form avoids a trailing newline):

```bash
openssl rand -hex 32 | gcloud secrets create flask_secret_key --data-file=-
gcloud secrets create client_secret --data-file=client_secret.json
printf '%s' "<ads-developer-token>" | gcloud secrets create developer_token --data-file=-
printf '%s' "causmos-adxai-st"      | gcloud secrets create image_bucket --data-file=-
```

Do not commit `client_secret.json` or any key file to git.

## 4. Deploy

From the repository root:

```bash
bash install_cloudrun.sh
```

The script, in order:
1. Sets the project and checks billing.
2. Tries to enable the APIs (warns on failure and continues).
3. Verifies the service account exists and the bucket is reachable.
4. Verifies the four secrets exist.
5. Creates the `causmos-db` Firestore database if it does not exist.
6. Builds and deploys `causmos-service` (4Gi memory, 2 CPU, 1–10 instances, 300s timeout), mounting `FLASK_SECRET_KEY` from `flask_secret_key`.
7. Reads the assigned service URL and sets it as the `APP_URL` environment variable.

The first build takes about 10–15 minutes because of TensorFlow. Later builds are faster when `requirements.txt` has not changed.

At the end, the script prints the app URL. `min-instances=1` keeps one instance running, which costs money while idle.

## 5. After the first deploy

1. **Add the redirect URI.** In Credentials, open the OAuth client and add `<APP_URL>/oauth_completed` under Authorized redirect URIs. Without this, Google login fails with `redirect_uri_mismatch`.
2. **Optional Slides template.** To use a default template, set its ID (the part after `/d/` in the Slides URL):
   ```bash
   gcloud run services update causmos-service --region=asia-south1 --update-env-vars=SLIDE_TEMPLATE=<template-id>
   ```
3. **Control who can open the app.** The script deploys with `--allow-unauthenticated`, so anyone with the URL can reach the login page. See Access control below.

## 6. Verify

1. Open the app URL and sign in with Google.
2. Run an analysis with one data source.
3. Export to Slides and confirm the chart appears.
4. Check logs if anything fails: Cloud Console → Cloud Run → `causmos-service` → Logs.

## Access control

If your organization blocks public (`allUsers`) access, `--allow-unauthenticated` is rejected or the service returns 403. Instead:
- Remove `--allow-unauthenticated` from the script, enable IAP on the service, and grant users the **IAP-secured Web App User** role, or
- Keep the service private and grant `roles/run.invoker` to specific users or groups.

## Updating the app later

- **Quick update:** re-run `bash install_cloudrun.sh`. It is safe to repeat.
- **Faster, cached builds:** `gcloud builds submit --config cloudbuild.yaml .` (uses `_SERVICE_NAME=causmos-service`, matching the script). It keeps existing service settings.
- **Rotating a secret:** add a new version, e.g. `printf '%s' "<value>" | gcloud secrets versions add <name> --data-file=-`. The app reads `latest` at request time. For `flask_secret_key`, redeploy or restart, and expect all users to be signed out.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `Secret '<name>' not found` | Create the secret with the exact name from step 3. |
| `permission iam.serviceaccounts.actAs` on deploy | Your account needs Service Account User on `sa-gads-ai-runner`. |
| Build fails pushing to Artifact Registry or reading source | The Cloud Build service account lacks permission. Ask an admin. |
| 403 when opening the URL | Public access is blocked. See Access control. |
| `redirect_uri_mismatch` on login | Add `<APP_URL>/oauth_completed` to the OAuth client (step 5). |
| Login error right after consent | `client_secret` secret has the wrong content. It must be the OAuth client JSON with a `web` key. |
| Chart missing from exported slide; log shows `Could not sign image URL` | The service account needs Service Account Token Creator, and the bucket must exist and be writable by it. |
| Firestore errors in logs | Confirm the `causmos-db` database exists in `asia-south1` and the service account has Cloud Datastore User. Run the `gcloud firestore databases create` command by hand to see the real error. |
| Out-of-memory restarts | Raise `--memory` in the script. |

## Security notes

- A Flask key and an App Engine URL for another project (`adh-na-433204`) were committed to `app.yaml` in the past. The key has been removed from the file but remains in git history, so never reuse it. Tell the owner of that project to rotate it if that deployment is still running.
- The OAuth scopes in `main.py` are broad (full Drive and BigQuery). Review them before opening the app to more users.
