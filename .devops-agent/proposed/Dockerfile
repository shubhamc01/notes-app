# Build dependency wheels in an isolated stage; the runtime has no build toolchain.
FROM python:3.14-slim AS build

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1
WORKDIR /build
COPY requirements.txt ./
RUN python -m pip wheel --wheel-dir /wheels -r requirements.txt gunicorn

# Keep the runtime minimal and run the Flask application as an unprivileged user.
FROM python:3.14-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080
WORKDIR /app
COPY requirements.txt ./
COPY --from=build /wheels /wheels
RUN python -m pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt gunicorn \
    && rm -rf /wheels \
    && groupadd --system app \
    && useradd --system --gid app --home-dir /app --no-create-home app
COPY --chown=app:app . .
USER app:app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
