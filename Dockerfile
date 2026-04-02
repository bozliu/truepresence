FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/apps/api:/app/packages/biometrics/src

WORKDIR /app

COPY apps/api /app/apps/api
COPY packages/biometrics /app/packages/biometrics
COPY data /app/data

RUN pip install --no-cache-dir \
    "fastapi>=0.135,<1" \
    "uvicorn[standard]>=0.41,<1" \
    "pydantic>=2.12,<3" \
    "numpy>=2,<3" \
    "opencv-python-headless>=4.10,<5"

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--app-dir", "apps/api", "--host", "0.0.0.0", "--port", "8000"]
