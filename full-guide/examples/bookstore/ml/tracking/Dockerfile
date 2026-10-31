# Bookstore, Part 12 ch.08: the MLflow tracker image, built on the upstream
# image pinned by digest. The upstream image is `pip install mlflow==3.3.2`
# and nothing more, so it lacks the basic-auth extras (Flask-WTF), a
# PostgreSQL driver for the external database and boto3 for an s3:// artifact
# store. This image adds those at pinned versions and runs as a non-root UID.
FROM ghcr.io/mlflow/mlflow@sha256:b166428a3ab479e396f14d671987a70b27741a8d9b22f9d69a559c1fbf09d551

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

USER 65532:65532
EXPOSE 5000
