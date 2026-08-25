FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    ACCOUNTING_DEPLOYMENT_MODE=server

WORKDIR /srv

# packages/ai first: it is the layer that changes least, and packages/api
# depends on it.
COPY packages/ai /srv/packages/ai
RUN pip install --no-cache-dir /srv/packages/ai

COPY packages/api /srv/packages/api
RUN pip install --no-cache-dir /srv/packages/api

COPY apps/server /srv/apps/server
COPY db /srv/db

EXPOSE 8000
CMD ["uvicorn", "apps.server.main:app", "--host", "0.0.0.0", "--port", "8000"]
