# syntax=docker/dockerfile:1.19
# Supplied pinned Python base; the Flask WSGI entrypoint is app:app.
FROM python:3.14-slim AS build
WORKDIR /build
COPY requirements.txt ./
RUN python -m pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt gunicorn

FROM python:3.14-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
RUN groupadd --system app && useradd --system --gid app --home-dir /app app
COPY requirements.txt ./
COPY --from=build /wheels /wheels
RUN python -m pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt gunicorn && rm -rf /wheels
# Do not include repository metadata, infrastructure, local env files or credentials.
COPY --exclude=.git --exclude=.github --exclude=infra --exclude=deploy --exclude=*.env --exclude=.env* --exclude=*.tfstate* --exclude=ssm-request.json . /app/
RUN chown -R app:app /app
USER app
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "--error-logfile", "-", "app:app"]
