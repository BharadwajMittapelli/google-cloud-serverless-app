#!/bin/bash
# Enable strict mode
set -eo pipefail

# 1. Configurable variables with defaults
PROJECT_ID=${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}
REGION=${GCP_REGION:-"us-central1"}

if [ -z "$PROJECT_ID" ]; then
  echo "Error: GCP_PROJECT is not set and could not auto-detect active gcloud project."
  echo "Please run: export GCP_PROJECT=your-project-id"
  exit 1
fi

echo "========================================================"
echo "Configuring deployment for GCP Project: $PROJECT_ID"
echo "Region: $REGION"
echo "========================================================"

# Resource Names
BUCKET_NAME="$PROJECT_ID-document-ingestion"
TOPIC_NAME="document-upload-topic"
SUB_NAME="document-processor-subscription"
DATASET="document_pipeline"
TABLE="metadata"
RUN_SA_NAME="doc-processor-sa"
INVOKER_SA_NAME="pubsub-invoker-sa"
REPO_NAME="document-pipeline"
SERVICE_NAME="document-processor"

# 2. Enable APIs
echo "Enabling Google Cloud APIs..."
gcloud services enable \
  run.googleapis.com \
  pubsub.googleapis.com \
  storage.googleapis.com \
  bigquery.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  cloudbuild.googleapis.com \
  --project="$PROJECT_ID"

# 3. Create Artifact Registry Repository
echo "Creating Artifact Registry..."
gcloud artifacts repositories create "$REPO_NAME" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  || echo "Artifact Registry repository already exists or creation skipped."

# 4. Create GCS Ingestion Bucket
echo "Creating GCS Ingestion Bucket: gs://$BUCKET_NAME..."
gcloud storage buckets create "gs://$BUCKET_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  || echo "GCS Bucket already exists."

# 5. Create BigQuery Dataset and Table
echo "Creating BigQuery Dataset and Table..."
# Create Dataset
bq --project_id="$PROJECT_ID" show "$DATASET" >/dev/null 2>&1 || \
  bq --project_id="$PROJECT_ID" mk --location="$REGION" --dataset "$DATASET"

# Create Table with Schema
# Create schema JSON to correctly support REPEATED tags field
cat <<EOF > schema.json
[
  {"name": "filename", "type": "STRING", "mode": "NULLABLE"},
  {"name": "date", "type": "TIMESTAMP", "mode": "NULLABLE"},
  {"name": "tags", "type": "STRING", "mode": "REPEATED"},
  {"name": "word_count", "type": "INTEGER", "mode": "NULLABLE"}
]
EOF

bq --project_id="$PROJECT_ID" show "$DATASET.$TABLE" >/dev/null 2>&1 || \
  bq --project_id="$PROJECT_ID" mk --table \
    --description "OCR metadata table" \
    "$DATASET.$TABLE" \
    schema.json

rm schema.json


# 6. Create Service Account for Cloud Run
echo "Creating Cloud Run execution Service Account: $RUN_SA_NAME..."
gcloud iam service-accounts create "$RUN_SA_NAME" \
  --display-name="Cloud Run Document Processor SA" \
  --project="$PROJECT_ID" \
  || echo "Service account already exists."

echo "Sleeping 5 seconds to allow service account IAM replication..."
sleep 5

# Assign permissions to Run Service Account
# Storage Reader
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer" >/dev/null

# BigQuery Data Editor
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" >/dev/null

# BigQuery Job User
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$RUN_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/bigquery.jobUser" >/dev/null

# 7. Build and Push Container using Cloud Build
IMAGE_TAG="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/processor-service:latest"
echo "Building Docker image: $IMAGE_TAG..."
gcloud builds submit --tag "$IMAGE_TAG" --project="$PROJECT_ID" .

# 8. Deploy to Cloud Run
echo "Deploying to Cloud Run: $SERVICE_NAME..."
gcloud run deploy "$SERVICE_NAME" \
  --image "$IMAGE_TAG" \
  --platform managed \
  --region "$REGION" \
  --service-account "$RUN_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --update-env-vars BQ_DATASET="$DATASET",BQ_TABLE="$TABLE",GCP_PROJECT="$PROJECT_ID" \
  --allow-unauthenticated \
  --project="$PROJECT_ID"

# Get Cloud Run Service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)")

echo "Cloud Run URL: $SERVICE_URL"

# 9. Configure Pub/Sub Triggering
echo "Creating Pub/Sub Topic: $TOPIC_NAME..."
gcloud pubsub topics create "$TOPIC_NAME" --project="$PROJECT_ID" || echo "Topic already exists."

# Authorize GCS to publish to the Pub/Sub topic
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
GCS_SA="service-$PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com"

echo "Granting Pub/Sub Publisher permissions to GCS Service Agent: $GCS_SA"
gcloud pubsub topics add-iam-policy-binding "$TOPIC_NAME" \
  --member="serviceAccount:$GCS_SA" \
  --role="roles/pubsub.publisher" \
  --project="$PROJECT_ID"

# Create Bucket Notification if not already configured
echo "Creating GCS Bucket Notification..."
gcloud storage buckets notifications create "gs://$BUCKET_NAME" \
  --topic="$TOPIC_NAME" \
  --event-types="OBJECT_FINALIZE" \
  --project="$PROJECT_ID" \
  || echo "GCS Bucket Notification already configured."

# Create Service Account for Pub/Sub Invoker
echo "Creating Pub/Sub Invoker Service Account: $INVOKER_SA_NAME..."
gcloud iam service-accounts create "$INVOKER_SA_NAME" \
  --display-name="Pub/Sub Cloud Run Invoker SA" \
  --project="$PROJECT_ID" \
  || echo "Invoker Service account already exists."

echo "Sleeping 5 seconds to allow service account IAM replication..."
sleep 5

# Allow Pub/Sub SA to generate tokens
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project="$PROJECT_ID" >/dev/null

# Allow Invoker SA to invoke Cloud Run Service
gcloud run services add-iam-policy-binding "$SERVICE_NAME" \
  --member="serviceAccount:$INVOKER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/run.invoker" \
  --region="$REGION" \
  --project="$PROJECT_ID" >/dev/null

# Create Pub/Sub Push Subscription
echo "Creating Pub/Sub Push Subscription: $SUB_NAME..."
gcloud pubsub subscriptions create "$SUB_NAME" \
  --topic="$TOPIC_NAME" \
  --push-endpoint="$SERVICE_URL/" \
  --push-auth-service-account="$INVOKER_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --project="$PROJECT_ID" \
  || gcloud pubsub subscriptions update "$SUB_NAME" \
       --push-endpoint="$SERVICE_URL/" \
       --project="$PROJECT_ID"

echo "========================================================"
echo "Deployment Complete!"
echo "Ingestion Bucket: gs://$BUCKET_NAME"
echo "BigQuery Table:   $PROJECT_ID:$DATASET.$TABLE"
echo "Cloud Run Service: $SERVICE_URL"
echo "========================================================"
