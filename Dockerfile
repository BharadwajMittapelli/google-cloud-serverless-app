# Use official lightweight Python image.
FROM python:3.11-slim

# Allow statements and log messages to immediately appear in the logs
ENV PYTHONUNBUFFERED=True

# Set the working directory
WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY src/ .

# Run the web service on container startup.
# Cloud Run defaults PORT to 8080 and handles routing.
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 app:app
