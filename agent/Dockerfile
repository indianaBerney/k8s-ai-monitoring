# Image de l'agent (FastAPI). Elle tourne dans le cluster, dans le namespace « monitoring ».
#
# Construction, puis copie dans minikube (pas besoin de registre d'images) :
#   docker build -t k8s-agent:local agent
#   minikube image load --overwrite=true k8s-agent:local

FROM python:3.12-slim

WORKDIR /app

# D'abord les dépendances : cette étape est gardée en cache tant que requirements.txt ne change pas.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY *.py ./

# L'agent ne tourne pas en root.
RUN useradd --uid 1000 --create-home app
USER 1000

# Adresses des services dans le cluster (DNS Kubernetes) : plus besoin de tunnels.
ENV PROMETHEUS_URL=http://monitoring-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090 \
    LOKI_URL=http://loki.monitoring.svc.cluster.local:3100 \
    PYTHONUNBUFFERED=1

EXPOSE 8001
CMD ["uvicorn", "api:app", "--host", "0.0.0.0", "--port", "8001"]
