# The groomer interface's backend. Started with the rest of the stack —
# `docker compose up -d` — and served at http://localhost:8000 (this machine
# only). The repo is mounted at /repo, so on first start it can build the
# demo database from the same SQL files the tests load.
FROM python:3.12-slim

# psql, for building the demo database on first start and in the tests.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /repo/api
EXPOSE 8000
CMD ["sh", "-c", "cd /repo && sh api/load_demo.sh && cd /repo/api && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload --reload-dir app"]
