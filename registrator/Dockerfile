FROM python:3.12-alpine

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Crear usuario sin privilegios para mitigar vulnerabilidades de ejecucion como root (Trivy / CIS Benchmark)
RUN addgroup -g 999 docker && \
    adduser -S -u 1001 -G docker appuser

COPY --chown=appuser:docker registrator.py .

USER appuser

CMD ["python", "-u", "registrator.py"]
