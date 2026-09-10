FROM python:3.13-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY CodexBar/Resources/UsageCollector.py /app/UsageCollector.py
COPY Collector/server.py /app/server.py
USER 1000:1000
EXPOSE 8765
ENTRYPOINT ["python3", "/app/server.py"]
CMD ["--listen", "0.0.0.0", "--token-file", "/run/secrets/collector_token"]
