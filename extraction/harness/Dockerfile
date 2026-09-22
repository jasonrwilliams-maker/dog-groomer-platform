# The extraction harness. Built by docker-compose as the `harness` service and
# run on demand:
#
#   docker compose run --rm harness selfcheck
#   docker compose run --rm harness run
#   docker compose run --rm harness score runs/<stamp>
#   docker compose run --rm harness load  runs/<stamp>
#
# The repo is mounted at /repo, so the code, the keys, private/ and runs/ are
# all the live copies on your disk — nothing is baked into the image except
# the two Python dependencies.
FROM python:3.12-slim

WORKDIR /repo/extraction/harness
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

ENTRYPOINT ["python", "-m", "harness"]
CMD ["--help"]
