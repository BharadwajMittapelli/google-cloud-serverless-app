import logging
import os
from typing import Dict, Any
from google.cloud import bigquery

logger = logging.getLogger(__name__)

def write_metadata_to_bq(metadata: Dict[str, Any]) -> None:
    """
    Streams a single metadata row into the BigQuery table.
    Uses credentials from Application Default Credentials.
    """
    try:
        client = bigquery.Client()
        
        # Determine target project, dataset, and table
        project = os.environ.get("GCP_PROJECT") or client.project
        dataset_id = os.environ.get("BQ_DATASET", "document_pipeline")
        table_id = os.environ.get("BQ_TABLE", "metadata")
        
        table_ref = f"{project}.{dataset_id}.{table_id}"
        logger.info(f"Streaming metadata to BigQuery table {table_ref}: {metadata}")
        
        errors = client.insert_rows_json(table_ref, [metadata])
        if errors:
            logger.error(f"BigQuery insertion errors: {errors}")
            raise RuntimeError(f"BigQuery streaming failed: {errors}")
            
        logger.info("BigQuery streaming succeeded.")
    except Exception as e:
        logger.error(f"Failed to stream metadata to BigQuery: {e}")
        raise e
