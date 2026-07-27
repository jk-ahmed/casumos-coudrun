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

PROJECT_ID=$(gcloud config get-value project 2> /dev/null)
USER_EMAIL=$(gcloud config get-value account 2> /dev/null)
SERVICE_NAME=causmos
REGION=asia-south1
SERVICE_ACCOUNT_NAME=causmos-sa
SERVICE_ACCOUNT=$SERVICE_ACCOUNT_NAME@$PROJECT_ID.iam.gserviceaccount.com

# Check billing
BILLING_ENABLED=$(gcloud beta billing projects describe $PROJECT_ID --format="csv(billingEnabled)" | tail -n 1)
if [[ "$BILLING_ENABLED" = 'False' ]]; then
  echo -e "${RED}Billing not enabled on $PROJECT_ID. Please activate billing.${NC}"
  exit 1
fi

echo -e "${COLOR}Enabling APIs...${NC}"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iamcredentials.googleapis.com \
  googleads.googleapis.com \
  analyticsadmin.googleapis.com \
  analyticsdata.googleapis.com \
  firestore.googleapis.com \
  sheets.googleapis.com \
  slides.googleapis.com \
  drive.googleapis.com \
  secretmanager.googleapis.com \
  bigquery.googleapis.com

echo -e "${COLOR}Creating service account...${NC}"
gcloud iam service-accounts create $SERVICE_ACCOUNT_NAME \
  --display-name="Causmos Cloud Run SA" 2>/dev/null || true

echo -e "${COLOR}Granting IAM roles to service account...${NC}"
for ROLE in \
  roles/iam.serviceAccountTokenCreator \
  roles/secretmanager.secretAccessor \
  roles/datastore.user \
  roles/bigquery.jobUser \
  roles/storage.objectAdmin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SERVICE_ACCOUNT" \
    --role=$ROLE --quiet
done

# Step 1: initial deploy to obtain the service URL
echo -e "${COLOR}Deploying to Cloud Run (step 1/2 — initial build)...${NC}"
gcloud run deploy $SERVICE_NAME \
  --source . \
  --region $REGION \
  --service-account=$SERVICE_ACCOUNT \
  --memory=2Gi \
  --cpu=2 \
  --min-instances=1 \
  --max-instances=10 \
  --timeout=300s \
  --allow-unauthenticated \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=$PROJECT_ID,SLIDE_TEMPLATE=" \
  --quiet

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
  --quiet

# Create named Firestore Native database used by the app
echo -e "${COLOR}Creating Firestore database causmos-db (skipped if already exists)...${NC}"
gcloud firestore databases create \
  --database=causmos-db \
  --location=$REGION \
  --type=firestore-native 2>/dev/null || \
  echo "Firestore database causmos-db already exists."

echo -e "\n${COLOR}Deployment complete!${NC}"
echo -e "${COLOR}App URL: $APP_URL${NC}"
echo ""
echo -e "${RED}IMPORTANT — manual steps required before OAuth works:${NC}"
echo -e "  1. Go to GCP Console > APIs & Services > Credentials"
echo -e "     Open your OAuth 2.0 client and add this to Authorized redirect URIs:"
echo -e "     ${COLOR}$APP_URL/oauth_completed${NC}"
echo -e "  2. If SLIDE_TEMPLATE is needed, update the env var:"
echo -e "     gcloud run services update $SERVICE_NAME --region=$REGION --update-env-vars=SLIDE_TEMPLATE=<your-template-id>"
