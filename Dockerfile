# syntax=docker/dockerfile:1

# ---- builder: resolve deps into a venv we can copy verbatim ----
FROM python:3.12.7-slim-bookworm AS builder

WORKDIR /app

RUN python -m venv /venv
ENV PATH="/venv/bin:${PATH}"

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip==24.2 \
    && pip install --no-cache-dir -r requirements.txt

# ---- runtime: slim image, no compilers/build tooling ----
FROM python:3.12.7-slim-bookworm AS runtime

# The slim-bookworm base lags Debian's security repo; pull the same-version
# patches (no apt-get dist-upgrade) rather than floating to an unpinned tag.
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid app --shell /usr/sbin/nologin --no-create-home app

WORKDIR /app

COPY --from=builder /venv /venv
COPY app.py .

ENV PATH="/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

USER 1000:1000

EXPOSE 8080

# curl/wget aren't installed to keep the image small; Python's stdlib
# avoids adding either package just for the healthcheck.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status == 200 else 1)"]

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "app:app"]
