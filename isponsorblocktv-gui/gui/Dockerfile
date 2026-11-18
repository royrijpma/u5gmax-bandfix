FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
EXPOSE 8095
# Eén worker: de log-collector draait als achtergrond-thread in dit proces.
CMD ["gunicorn", "-w", "1", "--threads", "8", "-b", "0.0.0.0:8095", "app:app"]
