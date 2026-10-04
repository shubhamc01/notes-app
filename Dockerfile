# Build dependency wheels separately so the runtime image contains no compiler
# toolchain. requirements.txt should pin the application's dependencies.
FROM python:3.14-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1
WORKDIR /build
COPY requirements.txt ./requirements.txt
RUN python -m pip wheel --wheel-dir=/wheels --requirement requirements.txt \
    'gunicorn==23.0.0'

FROM python:3.14-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8080
WORKDIR /app
COPY requirements.txt /tmp/requirements.txt
COPY --from=builder /wheels /wheels
RUN printf '%s\n' '-r /tmp/requirements.txt' 'gunicorn==23.0.0' > /tmp/runtime-requirements.txt \
    && python -m pip install --no-index --find-links=/wheels \
      --requirement /tmp/runtime-requirements.txt \
    && rm -rf /wheels /tmp/requirements.txt /tmp/runtime-requirements.txt \
    && groupadd --system app \
    && useradd --system --gid app --home-dir /app --no-create-home app
COPY . .
USER app:app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
# The WSGI entry point is app:app; application logs go to stdout/stderr.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
