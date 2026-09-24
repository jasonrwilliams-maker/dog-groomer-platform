# The labelling and review tool — and, from its Run & test screen, every
# command the READMEs give: the harness (selfcheck / run / score / load), the
# schema load, and the pgTAP suite. Started with the rest of the stack:
#
#   docker compose up -d
#
# and served at http://localhost:8501 (bound to this machine only — the pages
# it shows are the real documents in private/). The repo is mounted at /repo,
# so the keys, private/ and runs/ are the live copies on your disk.
#
# Build context is extraction/ so the harness's requirements come from the one
# file that lists them.
FROM python:3.12-slim

# psql for the schema load, pg_prove for the pgTAP suite.
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client libtap-parser-sourcehandler-pgtap-perl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /repo/extraction/review
COPY harness/requirements.txt /tmp/harness-requirements.txt
COPY review/requirements.txt /tmp/review-requirements.txt
RUN pip install --no-cache-dir -r /tmp/harness-requirements.txt -r /tmp/review-requirements.txt

EXPOSE 8501
CMD ["streamlit", "run", "app.py", "--server.address=0.0.0.0", "--server.port=8501", \
     "--server.headless=true", "--browser.gatherUsageStats=false"]
