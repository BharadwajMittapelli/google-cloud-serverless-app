#!/bin/bash
# Upload a real file to GCS and query BigQuery to verify end-to-end integration.
set -eo pipefail

PROJECT_ID=${GCP_PROJECT:-$(gcloud config get-value project 2>/dev/null)}
BUCKET_NAME="$PROJECT_ID-document-ingestion"
DATASET="document_pipeline"
TABLE="metadata"

if [ -z "$PROJECT_ID" ]; then
  echo "Error: GCP_PROJECT is not set and could not auto-detect active gcloud project."
  exit 1
fi

echo "========================================================"
echo "Running Integration Test in Project: $PROJECT_ID"
echo "Target Bucket: gs://$BUCKET_NAME"
echo "========================================================"

# 1. Create a dummy text file
cat <<EOF > test-doc.txt
This is a sample document for testing the event-driven OCR processing pipeline.
It runs on Google Cloud using Cloud Run, Cloud Storage, Pub/Sub, and BigQuery.
We want to extract keywords and calculate word counts.
EOF

echo "Uploading test-doc.txt to GCS..."
gcloud storage cp test-doc.txt "gs://$BUCKET_NAME/test-doc.txt"

echo "Waiting 12 seconds for Pub/Sub triggering, Cloud Run OCR extraction, and BigQuery streaming..."
sleep 12

echo "Querying BigQuery for the processed metadata..."
bq query --use_legacy_sql=false \
  "SELECT filename, date, tags, word_count FROM \`$PROJECT_ID.$DATASET.$TABLE\` WHERE filename = 'test-doc.txt' LIMIT 1"

# Clean up local test file
rm test-doc.txt

echo "========================================================"
echo "Integration Test Complete!"
echo "========================================================"
