import logging
from google.cloud import storage

logger = logging.getLogger(__name__)

def read_gcs_file(bucket_name: str, blob_name: str) -> str:
    """
    Downloads file content from Google Cloud Storage.
    Returns the file content decoded as a UTF-8 string.
    """
    try:
        logger.info(f"Reading file gs://{bucket_name}/{blob_name}")
        client = storage.Client()
        bucket = client.bucket(bucket_name)
        blob = bucket.blob(blob_name)
        
        # Download bytes and decode
        data = blob.download_as_bytes()
        return data.decode("utf-8", errors="ignore")
    except Exception as e:
        logger.error(f"Failed to read file from GCS: {e}")
        raise e
