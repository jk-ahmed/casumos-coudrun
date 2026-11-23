# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

COLOR='\033[0;36m' # Cyan
RED='\033[0;31m'   # Red
NC='\033[0m'       # No Color

PROJECT_ID=celestial-feat-513918-q9
IMAGE_BUCKET=causmos-adxai-st
gcloud config set project $PROJECT_ID --quiet
USER_EMAIL=$(gcloud config get-value account 2> /dev/null)
SERVICE_NAME=causmos-service   # matches _SERVICE_NAME in cloudbuild.yaml
REGION=asia-south1
SERVICE_ACCOUNT=sa-gads-ai-runner@$PROJECT_ID.iam.gserviceaccount.com   # existing SA, not created here

# Check billing
BILLING_ENABLED=$(gcloud beta billing projects describe $PROJECT_ID --format="csv(billingEnabled)" | tail -n 1)
if [[ "$BILLING_ENABLED" = 'False' ]]; then
  echo -e "${RED}Billing not enabled on $PROJECT_ID. Please activate billing.${NC}"
  exit 1
fi

# APIs are NOT enabled by this script, only checked.
echo -e "${COLOR}Checking required APIs are enabled...${NC}"
REQUIRED_APIS="run artifactregistry cloudbuild cloudresourcemanager iamcredentials googleads analyticsadmin analyticsdata firestore sheets slides drive secretmanager bigquery"
if ENABLED_APIS=$(gcloud services list --enabled --format="value(config.name)" 2>/dev/null) && [[ -n "$ENABLED_APIS" ]]; then
  for API in $REQUIRED_APIS; do
    if echo "$ENABLED_APIS" | grep -qx "$API.googleapis.com"; then
      echo "  OK       $API.googleapis.com"
    else
      echo -e "  ${RED}MISSING  $API.googleapis.com${NC}"
      MISSING_API=1
    fi
  done
  if [[ -n "$MISSING_API" ]]; then
    echo -e "${RED}Ask an admin to enable the missing APIs, then re-run.${NC}"
    exit 1
  fi
else
  echo -e "${RED}Could not list enabled APIs (no permission). Skipping the check.${NC}"
fi

echo -e "${COLOR}Verifying service account $SERVICE_ACCOUNT...${NC}"
gcloud iam service-accounts describe $SERVICE_ACCOUNT >/dev/null || {
  echo -e "${RED}Service account $SERVICE_ACCOUNT not found.${NC}"; exit 1; }

# NOTE: no IAM changes are made by this script. Ask a project admin to ensure
# $SERVICE_ACCOUNT has: secretmanager.secretAccessor, datastore.user,
# bigquery.jobUser, iam.serviceAccountTokenCreator, and storage objectUser on
# gs://$IMAGE_BUCKET, that the SA has iam.serviceAccountTokenCreator ON ITSELF
# (needed to sign image URLs; bucket stays private), and that you have
# iam.serviceAccountUser on the service account.
gcloud storage buckets describe gs://$IMAGE_BUCKET >/dev/null 2>&1 || \
  echo -e "${RED}Bucket gs://$IMAGE_BUCKET not found or not accessible.${NC}"

# Secrets are created manually in Secret Manager; just verify they exist.
echo -e "${COLOR}Checking secrets...${NC}"
for S in flask_secret_key client_secret developer_token image_bucket; do
  gcloud secrets describe "$S" >/dev/null 2>&1 || {
    echo -e "${RED}Secret '$S' not found in $PROJECT_ID. Create it before deploying.${NC}"; exit 1; }
done

# Create named Firestore Native database used by the app (before first deploy)
echo -e "${COLOR}Creating Firestore database causmos-db (skipped if already exists)...${NC}"
gcloud firestore databases create \
  --database=causmos-db \
  --location=$REGION \
  --type=firestore-native 2>/dev/null || \
  echo "Firestore database causmos-db already exists."

# How the container image is built (override: BUILD_MODE=sa bash install_cloudrun.sh)
#   local - build with docker in this shell as YOUR user, push to Artifact Registry.
#           Needs docker (Cloud Shell has it) and Artifact Registry Writer. No Cloud Build.
#   sa    - Cloud Build runs as $SERVICE_ACCOUNT. The SA needs: read on the source
#           bucket, Artifact Registry Writer, and Logs Writer.
BUILD_MODE=${BUILD_MODE:-local}
AR_REPO=cloud-run-source-deploy

if [[ "$BUILD_MODE" = "local" ]]; then
  IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/$SERVICE_NAME:$(date +%Y%m%d%H%M%S)"
  echo -e "${COLOR}Building image locally as $USER_EMAIL: $IMAGE${NC}"
  gcloud artifacts repositories describe $AR_REPO --location=$REGION >/dev/null 2>&1 || \
    gcloud artifacts repositories create $AR_REPO --repository-format=docker --location=$REGION --quiet || \
    { echo -e "${RED}Cannot find or create Artifact Registry repo $AR_REPO.${NC}"; exit 1; }
  gcloud auth configure-docker $REGION-docker.pkg.dev --quiet
  docker build -t "$IMAGE" . && docker push "$IMAGE" || \
    { echo -e "${RED}Image build/push failed.${NC}"; exit 1; }
  SOURCE_ARGS=(--image "$IMAGE")
else
  SOURCE_ARGS=(--source . --build-service-account "projects/$PROJECT_ID/serviceAccounts/$SERVICE_ACCOUNT")
fi

# Step 1: initial deploy to obtain the service URL
echo -e "${COLOR}Deploying to Cloud Run (step 1/2, BUILD_MODE=$BUILD_MODE)...${NC}"
gcloud run deploy $SERVICE_NAME \
  "${SOURCE_ARGS[@]}" \
  --region $REGION \
  --service-account=$SERVICE_ACCOUNT \
  --memory=4Gi \
  --cpu=2 \
  --min-instances=1 \
  --max-instances=10 \
  --timeout=300s \
  --allow-unauthenticated \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$PROJECT_ID,SLIDE_TEMPLATE=" \
  --set-secrets="FLASK_SECRET_KEY=flask_secret_key:latest" \
  --quiet || { echo -e "${RED}Deploy failed. Fix the error above and re-run.${NC}"; exit 1; }

# Capture the URL assigned by Cloud Run
APP_URL=$(gcloud run services describe $SERVICE_NAME \
  --region=$REGION \
  --format="value(status.url)")

echo -e "${COLOR}Service URL: $APP_URL${NC}"

# Step 2: inject APP_URL so OAuth redirect URI resolves correctly
echo -e "${COLOR}Updating APP_URL env var (step 2/2)...${NC}"
gcloud run services update $SERVICE_NAME \
  --region=$REGION \
  --update-env-vars="APP_URL=$APP_URL" \
  --quiet || { echo -e "${RED}Could not set APP_URL.${NC}"; exit 1; }

echo -e "\n${COLOR}Deployment complete!${NC}"
echo -e "${COLOR}App URL: $APP_URL${NC}"
echo ""
echo -e "${RED}IMPORTANT — manual steps required before OAuth works:${NC}"
echo -e "  1. Go to GCP Console > APIs & Services > Credentials"
echo -e "     Open your OAuth 2.0 client and add this to Authorized redirect URIs:"
echo -e "     ${COLOR}$APP_URL/oauth_completed${NC}"
echo -e "  2. If SLIDE_TEMPLATE is needed, update the env var:"
echo -e "     gcloud run services update $SERVICE_NAME --region=$REGION --update-env-vars=SLIDE_TEMPLATE=<your-template-id>"
