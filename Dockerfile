# The repository must provide requirements.txt and a Flask WSGI application at app:app.
# A single EC2 host cannot provide HA; scaling requires a larger host or re-architecture.
FROM python:3.14-slim AS builder
WORKDIR /app
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt gunicorn
# Exclude credentials, deployment artifacts and infrastructure state from image layers.
COPY --exclude=.git --exclude=.github --exclude=infra --exclude=deploy --exclude=*.env --exclude=*.tfstate* --exclude=docker-compose.prod.yml --exclude=Dockerfile.bundle . ./

FROM python:3.14-slim
ENV VIRTUAL_ENV=/opt/venv PATH=/opt/venv/bin:$PATH PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
RUN groupadd --system app && useradd --system --gid app --home-dir /app app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder --chown=app:app /app /app
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3).close()"]
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
