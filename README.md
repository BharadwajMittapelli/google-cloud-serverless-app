# Serverless Event-Driven Document Processing Pipeline on GCP

This repository contains code to implement a fully serverless, event-driven document OCR and metadata ingestion pipeline on Google Cloud Platform (GCP).

## Architecture

1. **Ingestion**: The user uploads files (images, PDFs, text) to a **Google Cloud Storage (GCS)** bucket.
2. **Event Trigger**: The upload triggers an `OBJECT_FINALIZE` notification, which GCS publishes to a **Pub/Sub Topic**.
3. **Execution**: A **Pub/Sub Push Subscription** triggers a **Cloud Run** service (Python / Flask) via an HTTP POST request.
4. **Processing**: The Cloud Run service downloads the file from GCS, performs simulated OCR (extracting word count and generating tags), and formats the result.
5. **Storage**: The service streams the metadata directly into a **BigQuery** table.

---

## 🖥️ Live Dashboard

You can view the interactive document processing dashboard via the live Cloud Run endpoint:  
👉 **[Live Dashboard URL](https://document-processor-oupkxh5lxa-uc.a.run.app/dashboard)**

---

## Directory Structure

```
google-cloud-serverless-app/
├── src/
│   ├── __init__.py
│   ├── app.py              # Flask application entrypoint & routes
│   ├── processor.py        # OCR metadata extraction engine
│   ├── gcs_helper.py       # Storage helpers to read documents from GCS
│   └── bq_helper.py        # BigQuery helpers to stream metadata
├── requirements.txt         # Python dependencies
├── Dockerfile              # Docker container configuration
├── deploy.sh               # Shell script to build and deploy everything on GCP
├── test_local.sh           # Local test runner (mock Pub/Sub requests)
├── test_cloud.sh           # Integration test runner (uploads test file and queries BQ)
└── README.md               # Documentation
```

---

## Getting Started

### Prerequisites

Ensure you have the following installed and configured locally:
- **Python 3.11+**
- **Docker** (optional, for local container builds)
- **Google Cloud CLI (gcloud)** initialized and authorized:
  ```bash
  gcloud auth login
  gcloud auth application-default login
  ```

### 1. Local Testing

To test the application routing and simulated OCR logic locally:

1. Install local dependencies:
   ```bash
   pip install -r requirements.txt
   ```
2. Run the local mock server and trigger mock events:
   ```bash
   chmod +x test_local.sh
   ./test_local.sh
   ```
   *Note: Because GCS and BigQuery operations are triggered, this local run will print `500 Internal Server Error` outputs if local GCP credentials are missing or do not have access to the target resources, which verifies the pipeline's built-in Pub/Sub error retries.*

### 2. Deploying to Google Cloud

To provision all Google Cloud resources (GCS bucket, BigQuery dataset/table, service accounts, Pub/Sub triggers) and deploy the service to Cloud Run:

1. Configure your target project ID:
   ```bash
   export GCP_PROJECT="your-gcp-project-id"
   export GCP_REGION="us-central1"
   ```
2. Execute the deployment script:
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

### 3. Cloud Integration Testing

Once the deployment finishes, verify the system is fully operational by uploading a document:

```bash
chmod +x test_cloud.sh
./test_cloud.sh
```

This will automatically create a sample document, upload it to your ingestion bucket, wait a few seconds, and query the BigQuery table to display the ingested metadata & markdown file as the result.

---

## Error Handling & Resiliency

- **Pub/Sub Retries**: If the Cloud Run service fails to pull the document from GCS or stream it to BigQuery, it returns a `500 Internal Server Error` response. This prompts the Pub/Sub subscription to retry delivery according to its retry policy.
- **Service Account Privileges**: The Cloud Run service operates under a dedicated Service Account containing only the `storage.objectViewer`, `bigquery.dataEditor`, and `bigquery.jobUser` IAM roles.

---

## Clean Up

To avoid incurring charges on your Google Cloud account, you can remove all the resources created by this project by running the following commands:

```bash
export GCP_PROJECT="your-gcp-project-id"
export GCP_REGION="us-central1"

# 1. Delete Cloud Run service
gcloud run services delete document-processor --region=$GCP_REGION --project=$GCP_PROJECT --quiet

# 2. Delete Pub/Sub subscription and topic
gcloud pubsub subscriptions delete document-processor-subscription --project=$GCP_PROJECT --quiet
gcloud pubsub topics delete document-upload-topic --project=$GCP_PROJECT --quiet

# 3. Delete GCS bucket
gcloud storage rm --recursive gs://$GCP_PROJECT-document-ingestion

# 4. Delete Artifact Registry repository
gcloud artifacts repositories delete document-pipeline --location=$GCP_REGION --project=$GCP_PROJECT --quiet

# 5. Delete BigQuery dataset (and its tables)
bq rm -r -f -d $GCP_PROJECT:document_pipeline

# 6. Delete Service Accounts
gcloud iam service-accounts delete doc-processor-sa@$GCP_PROJECT.iam.gserviceaccount.com --project=$GCP_PROJECT --quiet
gcloud iam service-accounts delete pubsub-invoker-sa@$GCP_PROJECT.iam.gserviceaccount.com --project=$GCP_PROJECT --quiet
```
