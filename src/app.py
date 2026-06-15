import base64
import json
import logging
import os
from flask import Flask, request, render_template
from google.cloud import bigquery

# Import helpers (src directory is in the PYTHONPATH or local directory)
from gcs_helper import read_gcs_file
from processor import process_document
from bq_helper import write_metadata_to_bq

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)

app = Flask(__name__)

@app.route("/", methods=["POST"])
@app.route("/webhook", methods=["POST"])
def webhook():
    """
    Handles GCS object-creation events forwarded via Pub/Sub Push Subscription.
    """
    logger.info("Received request on webhook endpoint.")
    
    envelope = request.get_json()
    if not envelope:
        logger.error("No JSON payload received.")
        return "Bad Request: Empty body", 400

    if not isinstance(envelope, dict) or "message" not in envelope:
        logger.error("Invalid Pub/Sub message format (missing 'message' wrapper).")
        return "Bad Request: Invalid Pub/Sub structure", 400

    pubsub_message = envelope["message"]
    
    # 1. Parse from GCS notification attributes
    attributes = pubsub_message.get("attributes", {})
    bucket_name = attributes.get("bucketId")
    object_name = attributes.get("objectId")
    event_type = attributes.get("eventType")
    
    # 2. Fallback: Parse from base64 data field which holds GCS object resource representation
    if not bucket_name or not object_name:
        if "data" in pubsub_message:
            try:
                data_bytes = base64.b64decode(pubsub_message["data"])
                data_json = json.loads(data_bytes.decode("utf-8"))
                bucket_name = data_json.get("bucket")
                object_name = data_json.get("name")
            except Exception as e:
                logger.warning(f"Could not parse message data payload: {e}")

    if not bucket_name or not object_name:
        logger.error("Failed to determine bucket or object name from payload.")
        return "Bad Request: Missing bucketId or objectId", 400

    # Filter out deletion/update events if they happen to trigger
    # OBJECT_FINALIZE is the GCS Pub/Sub event for object creation
    if event_type and event_type != "OBJECT_FINALIZE":
        logger.info(f"Skipping event type: {event_type} for file gs://{bucket_name}/{object_name}")
        return f"Skipped: Event type {event_type} is not OBJECT_FINALIZE", 200

    try:
        logger.info(f"Processing object: {object_name} from bucket: {bucket_name}")
        
        # Read the file
        content = read_gcs_file(bucket_name, object_name)
        
        # Simulated OCR
        metadata = process_document(object_name, content)
        
        # Insert metadata into BigQuery
        write_metadata_to_bq(metadata)
        
        logger.info(f"Successfully processed gs://{bucket_name}/{object_name}")
        return "OK", 200
        
    except Exception as e:
        logger.exception(f"Error occurred while processing file gs://{bucket_name}/{object_name}: {e}")
        # Returning HTTP 500 error code forces Pub/Sub to retry the delivery.
        return "Internal Server Error", 500

@app.route("/dashboard", methods=["GET"])
def dashboard():
    project_id = os.environ.get("GCP_PROJECT")
    if not project_id:
        return "GCP_PROJECT environment variable is not set.", 500
        
    client = bigquery.Client(project=project_id)
    
    query = f"""
        SELECT filename, date, tags, word_count 
        FROM `{project_id}.document_pipeline.metadata`
        ORDER BY date DESC
    """
    
    try:
        query_job = client.query(query)
        rows = query_job.result()
        data = []
        all_tags = set()
        
        for row in rows:
            tags_val = row.tags
            parsed_tags = []
            if isinstance(tags_val, str):
                try:
                    parsed_tags = json.loads(tags_val)
                except:
                    parsed_tags = [tags_val]
            elif isinstance(tags_val, list):
                parsed_tags = tags_val
                
            for t in parsed_tags:
                all_tags.add(t)
                
            data.append({
                "filename": row.filename,
                "date": row.date.strftime("%Y-%m-%d %H:%M:%S") if row.date else "",
                "tags": parsed_tags,
                "word_count": row.word_count
            })
            
        return render_template("dashboard.html", documents=data, tags=sorted(list(all_tags)))
    except Exception as e:
        logger.error(f"Dashboard error: {e}")
        return f"Error loading dashboard: {e}", 500

@app.route("/healthz", methods=["GET"])
def health():
    return "OK", 200

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
