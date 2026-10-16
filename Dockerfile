FROM python:3.11.17-slim

WORKDIR /app

# libgomp1 is required by TensorFlow
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV PORT=8080
EXPOSE 8080

CMD exec gunicorn -b :$PORT main:app -w 2 --timeout=300
