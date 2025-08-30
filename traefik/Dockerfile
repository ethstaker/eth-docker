ARG DOCKER_TAG=3.12-alpine
FROM python:${DOCKER_TAG}

WORKDIR /app

RUN pip install --no-cache-dir boto3 requests tenacity

COPY app/updater.py .

CMD ["python", "updater.py"]
