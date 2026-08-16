FROM python:3.12-alpine

WORKDIR /app

COPY server.py ./
COPY config.json ./
COPY static/ ./static/

EXPOSE 8080

CMD ["python3", "server.py"]
