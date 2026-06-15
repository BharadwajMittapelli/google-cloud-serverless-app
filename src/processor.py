import datetime
import os
import re
from typing import List, Dict, Any

def process_document(filename: str, content: str) -> Dict[str, Any]:
    """
    Simulates OCR processing on a document.
    - For .txt files, it analyzes the content provided.
    - For non-txt files, it simulates OCR by generating mock stats.
    """
    file_ext = os.path.splitext(filename)[1].lower()
    
    # Initialize metadata
    word_count = 0
    tags: List[str] = []
    
    if file_ext == '.txt':
        # Simple analysis for text files
        # Count words (any alphanumeric sequence)
        words = re.findall(r'\b\w+\b', content)
        word_count = len(words)
        
        # Simple keyword tag generation
        # Find unique words longer than 5 characters, lowercase them
        long_words = [w.lower() for w in words if len(w) > 5]
        # Keep top unique long words as tags (up to 5 tags)
        unique_words = sorted(list(set(long_words)), key=lambda x: long_words.count(x), reverse=True)
        tags = unique_words[:3]
        tags.append("text")
    else:
        # Simulated OCR for PDFs, Images, etc.
        word_count = len(filename) * 12 + 42  # deterministic mock value
        tags = ["simulated-ocr", file_ext.replace('.', '') or "unknown"]
    
    # Standard tags applied to all processed files
    tags.append("processed")
    # De-duplicate tags
    tags = list(set(tags))
    
    return {
        "filename": filename,
        "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "tags": tags,
        "word_count": word_count
    }
