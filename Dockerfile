# syntax=docker/dockerfile:1.7

ARG PYTHON_IMAGE=python:3.14.6-slim-bookworm
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.28
ARG BUN_IMAGE=oven/bun:1.3.14-slim


FROM ${UV_IMAGE} AS uv-bin


FROM ${BUN_IMAGE} AS frontend-builder

WORKDIR /app

COPY package.json bun.lock ./

RUN bun install \
    --frozen-lockfile \
    --ignore-scripts

COPY frontend/web-assets ./frontend/web-assets

RUN bun run web:build


FROM ${PYTHON_IMAGE} AS python-base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    UV_PROJECT_ENVIRONMENT=/opt/careerops-venv \
    VIRTUAL_ENV=/opt/careerops-venv \
    PATH="/opt/careerops-venv/bin:${PATH}"

COPY --from=uv-bin /uv /uvx /bin/

WORKDIR /app


FROM python-base AS production-dependencies

COPY pyproject.toml uv.lock README.md ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync \
        --locked \
        --no-dev \
        --no-install-project


FROM python-base AS development

COPY pyproject.toml uv.lock README.md ./

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync \
        --locked \
        --all-groups \
        --no-install-project

COPY . .

EXPOSE 8000

CMD ["sh", "docker/development/start.sh"]


FROM ${PYTHON_IMAGE} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=/opt/careerops-venv \
    PATH="/opt/careerops-venv/bin:${PATH}"

RUN groupadd \
        --system \
        --gid 10001 \
        careerops \
    && useradd \
        --system \
        --uid 10001 \
        --gid careerops \
        --home-dir /app \
        --shell /usr/sbin/nologin \
        careerops

WORKDIR /app

RUN chown careerops:careerops /app

COPY \
    --from=production-dependencies \
    --chown=careerops:careerops \
    /opt/careerops-venv \
    /opt/careerops-venv

COPY --chown=careerops:careerops apps ./apps
COPY --chown=careerops:careerops config ./config
COPY --chown=careerops:careerops templates ./templates
COPY --chown=careerops:careerops manage.py ./

COPY \
    --from=frontend-builder \
    --chown=careerops:careerops \
    /app/frontend/web-assets/static/careerops \
    ./frontend/web-assets/static/careerops

USER careerops

RUN DJANGO_SETTINGS_MODULE=config.settings.production \
    DJANGO_SECRET_KEY=container-build-only-not-a-runtime-secret \
    DJANGO_ALLOWED_HOSTS=localhost \
    python manage.py collectstatic \
        --noinput \
        --clear

EXPOSE 8000

HEALTHCHECK \
    --interval=30s \
    --timeout=5s \
    --start-period=10s \
    --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; host = os.environ.get('DJANGO_ALLOWED_HOSTS', 'localhost').split(',')[0].strip() or 'localhost'; request = urllib.request.Request('http://127.0.0.1:8000/health/live/', headers={'Host': host, 'X-Forwarded-Proto': 'https'}); urllib.request.urlopen(request, timeout=3).read()"]

CMD ["gunicorn", "--bind=0.0.0.0:8000", "--workers=2", "--threads=4", "--timeout=30", "--access-logfile=-", "--error-logfile=-", "config.wsgi:application"]