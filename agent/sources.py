"""Les trois sources de données de l'agent.

- Prometheus : les métriques (ce qui s'est passé récemment, en chiffres)
- Loki       : les logs (les messages écrits par les applications)
- Kubernetes : l'état actuel du cluster (ce qui existe maintenant)
"""

import os
import time
from datetime import datetime, timezone

import requests
from kubernetes import client, config

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://localhost:9090")
LOKI_URL = os.getenv("LOKI_URL", "http://localhost:3100")
TIMEOUT = 20


# ---------------------------------------------------------------- Prometheus

def prometheus(query):
    """Envoie une requête PromQL et renvoie une liste de {labels, value}."""
    response = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query",
        params={"query": query},
        timeout=TIMEOUT,
    )
    response.raise_for_status()
    return [
        {"labels": serie["metric"], "value": float(serie["value"][1])}
        for serie in response.json()["data"]["result"]
    ]


# ---------------------------------------------------------------------- Loki

def loki(query, minutes=30, limit=20):
    """Renvoie les lignes de logs les plus récentes (les plus récentes d'abord)."""
    end = time.time_ns()
    start = end - minutes * 60 * 1_000_000_000
    response = requests.get(
        f"{LOKI_URL}/loki/api/v1/query_range",
        params={
            "query": query,
            "start": start,
            "end": end,
            "limit": limit,
            "direction": "backward",
        },
        timeout=TIMEOUT,
    )
    response.raise_for_status()

    lines = []
    for stream in response.json()["data"]["result"]:
        for timestamp, line in stream["values"]:
            lines.append((int(timestamp), line[:300]))  # on coupe les lignes trop longues

    lines.sort(reverse=True)
    return [f"{age_text(ts / 1e9)} | {line}" for ts, line in lines[:limit]]


# ---------------------------------------------------------------- Kubernetes

_core_api = None


def kube():
    """Connexion à l'API Kubernetes, avec le même fichier de config que kubectl."""
    global _core_api
    if _core_api is None:
        config.load_kube_config()
        _core_api = client.CoreV1Api()
    return _core_api


def age_text(moment):
    """Transforme une date (ou un timestamp) en texte lisible : 'il y a 12 min'."""
    if moment is None:
        return "date inconnue"
    if isinstance(moment, (int, float)):
        moment = datetime.fromtimestamp(moment, tz=timezone.utc)
    seconds = (datetime.now(timezone.utc) - moment).total_seconds()
    if seconds < 120:
        return f"il y a {int(seconds)} s"
    if seconds < 7200:
        return f"il y a {int(seconds // 60)} min"
    return f"il y a {int(seconds // 3600)} h"


def container_state(status):
    """Résume l'état d'un conteneur : running, waiting (pourquoi) ou terminated."""
    state = status.state
    if state.running:
        return "running"
    if state.waiting:
        return f"waiting ({state.waiting.reason})"
    if state.terminated:
        return f"terminated ({state.terminated.reason}, exit code {state.terminated.exit_code})"
    return "unknown"


def describe_pod(pod):
    """Résumé de l'état ACTUEL d'un pod et de ses conteneurs."""
    containers = []
    for status in pod.status.container_statuses or []:
        last = status.last_state.terminated if status.last_state else None
        containers.append({
            "name": status.name,
            "ready": status.ready,
            "state": container_state(status),
            "restart_count_total": status.restart_count,
            "last_termination": (
                f"{last.reason}, exit code {last.exit_code}, {age_text(last.finished_at)}"
                if last else None
            ),
        })
    return {
        "namespace": pod.metadata.namespace,
        "pod": pod.metadata.name,
        "phase": pod.status.phase,
        "node": pod.spec.node_name,
        "created": age_text(pod.metadata.creation_timestamp),
        "containers": containers,
    }


def pod_is_unhealthy(summary):
    if summary["phase"] not in ("Running", "Succeeded"):
        return True
    if summary["phase"] == "Succeeded":
        return False
    return any(not c["ready"] for c in summary["containers"])


def get_pod(namespace, name):
    """Renvoie le résumé du pod, ou None s'il n'existe pas (ou plus)."""
    try:
        return describe_pod(kube().read_namespaced_pod(name, namespace))
    except client.ApiException as error:
        if error.status == 404:
            return None
        raise


def list_unhealthy_pods():
    pods = kube().list_pod_for_all_namespaces().items
    return [s for s in map(describe_pod, pods) if pod_is_unhealthy(s)]


def list_nodes():
    nodes = []
    for node in kube().list_node().items:
        ready = next((c.status for c in node.status.conditions if c.type == "Ready"), "Unknown")
        nodes.append({"node": node.metadata.name, "ready": ready == "True"})
    return nodes


def events(namespace=None, pod=None, max_age_minutes=60, warnings_only=False):
    """Événements Kubernetes RÉCENTS, chacun avec son âge."""
    api = kube()
    if namespace and pod:
        items = api.list_namespaced_event(
            namespace, field_selector=f"involvedObject.name={pod}"
        ).items
    else:
        items = api.list_event_for_all_namespaces().items

    result = []
    now = datetime.now(timezone.utc)
    for event in items:
        moment = event.last_timestamp or event.event_time or event.metadata.creation_timestamp
        if moment and (now - moment).total_seconds() > max_age_minutes * 60:
            continue  # trop ancien : on ne le montre pas au modèle
        if warnings_only and event.type != "Warning":
            continue
        result.append({
            "age": age_text(moment),
            "type": event.type,
            "reason": event.reason,
            "object": f"{event.involved_object.namespace}/{event.involved_object.name}",
            "message": (event.message or "")[:200],
            "count": event.count,
        })
    return result[-20:]


def previous_logs(namespace, pod, container=None, lines=15):
    """Logs du conteneur AVANT son dernier plantage (comme kubectl logs --previous)."""
    try:
        return kube().read_namespaced_pod_log(
            pod, namespace, container=container, previous=True, tail_lines=lines
        ).splitlines()
    except client.ApiException:
        return []  # pas de conteneur précédent : il n'a jamais planté
