"""Rassemble les preuves pour chacun des trois cas d'usage.

Chaque fonction renvoie un dictionnaire qui sépare clairement :
- "now"     : l'état actuel (API Kubernetes)
- "history" : ce qui s'est passé récemment (Prometheus, événements, logs)
"""

from sources import (
    events, get_pod, list_nodes, list_unhealthy_pods, loki, previous_logs, prometheus,
)


def safe(function, *args, **kwargs):
    """Appelle une source ; si elle ne répond pas, on le note au lieu de planter.

    Une source en panne ne doit JAMAIS être interprétée comme « tout va bien ».
    """
    try:
        return function(*args, **kwargs)
    except Exception as error:  # noqa: BLE001
        return {"SOURCE_UNAVAILABLE": f"{type(error).__name__}: {error}"}


def restarts_last_hour(namespace=None, pod=None):
    selector = ""
    if namespace and pod:
        selector = f'{{namespace="{namespace}",pod="{pod}"}}'
    query = f"increase(kube_pod_container_status_restarts_total{selector}[1h]) > 0"
    series = prometheus(query)
    return [
        {
            "namespace": s["labels"].get("namespace"),
            "pod": s["labels"].get("pod"),
            "container": s["labels"].get("container"),
            "restarts_last_hour": round(s["value"]),
        }
        for s in series
    ]


def node_usage():
    cpu = prometheus('100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))')
    memory = prometheus("100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)")
    return {
        "cpu_percent": {s["labels"].get("instance"): round(s["value"], 1) for s in cpu},
        "memory_percent": {s["labels"].get("instance"): round(s["value"], 1) for s in memory},
    }


# ------------------------------------------------------------- cas d'usage 1

def cluster_health():
    unhealthy = safe(list_unhealthy_pods)
    restarts = safe(restarts_last_hour)

    # Pour chaque redémarrage récent : le pod existe-t-il encore ?
    if isinstance(restarts, list) and isinstance(unhealthy, list):
        for r in restarts:
            r["pod_still_exists"] = safe(get_pod, r["namespace"], r["pod"]) is not None

    return {
        "use_case": "cluster health overview",
        "now": {
            "nodes": safe(list_nodes),
            "unhealthy_pods": unhealthy,
            "node_usage": safe(node_usage),
        },
        "history": {
            "container_restarts_last_hour": restarts,
            "warning_events_last_30_min": safe(events, max_age_minutes=30, warnings_only=True),
        },
    }


# ------------------------------------------------------------- cas d'usage 2

def investigate_pod(namespace, pod):
    current = safe(get_pod, namespace, pod)
    if current is None:
        current = "This pod does not exist (anymore) in the cluster."

    memory = safe(
        prometheus,
        f'sum(container_memory_working_set_bytes{{namespace="{namespace}",pod="{pod}",container!=""}}) / 1048576',
    )
    cpu = safe(
        prometheus,
        f'sum(rate(container_cpu_usage_seconds_total{{namespace="{namespace}",pod="{pod}",container!=""}}[5m]))',
    )
    if isinstance(memory, list):
        memory = round(memory[0]["value"]) if memory else "no data"
    if isinstance(cpu, list):
        cpu = round(cpu[0]["value"], 3) if cpu else "no data"

    return {
        "use_case": "incident investigation",
        "now": {"pod": current, "memory_mib": memory, "cpu_cores": cpu},
        "history": {
            "restarts_last_hour": safe(restarts_last_hour, namespace, pod),
            "events_last_60_min": safe(events, namespace, pod, max_age_minutes=60),
            "recent_logs_last_30_min": safe(
                loki, f'{{namespace="{namespace}",pod="{pod}"}}', minutes=30, limit=15
            ),
        },
    }


# ------------------------------------------------------------- cas d'usage 3

def root_cause(namespace, pod):
    evidence = investigate_pod(namespace, pod)
    evidence["use_case"] = "root-cause analysis"
    evidence["history"]["error_logs_last_60_min"] = safe(
        loki,
        f'{{namespace="{namespace}",pod="{pod}"}} |~ "(?i)(error|fail|exception|refused|denied|timeout|killed)"',
        minutes=60,
        limit=15,
    )
    evidence["history"]["logs_before_last_crash"] = safe(previous_logs, namespace, pod)
    return evidence
