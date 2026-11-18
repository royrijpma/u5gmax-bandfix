FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
ENV TZ=Europe/Amsterdam
EXPOSE 8095
# 1 worker + threads: de log-thread draait binnen het proces
CMD ["gunicorn", "-b", "0.0.0.0:8095", "-w", "1", "--threads", "8", "app:app"]
