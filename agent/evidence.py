"""Rassemble les preuves pour chacun des trois cas d'usage.

Chaque fonction renvoie un dictionnaire qui sépare clairement :
- "now"     : l'état actuel (API Kubernetes)
- "history" : ce qui s'est passé récemment (Prometheus, événements, logs)
"""

from sources import (
    events, get_pod, list_nodes, list_pods, list_unhealthy_pods, loki, pods_per_namespace,
    previous_logs, prometheus,
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
    """Utilisation du CPU, de la mémoire et du disque de chaque nœud, en %."""
    cpu = prometheus('100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))')
    memory = prometheus("100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)")
    disk = prometheus(
        'max by (instance) (100 * (1 - node_filesystem_avail_bytes{mountpoint="/"}'
        ' / node_filesystem_size_bytes{mountpoint="/"}))'
    )
    return {
        "cpu_percent": {s["labels"].get("instance"): round(s["value"], 1) for s in cpu},
        "memory_percent": {s["labels"].get("instance"): round(s["value"], 1) for s in memory},
        "disk_percent": {s["labels"].get("instance"): round(s["value"], 1) for s in disk},
    }


def pod_usage(namespace):
    """Mémoire (Mio) et CPU (cœurs) de chaque pod d'un namespace."""
    memory = prometheus(
        f'sum by (pod) (container_memory_working_set_bytes{{namespace="{namespace}",container!=""}}) / 1048576'
    )
    cpu = prometheus(
        f'sum by (pod) (rate(container_cpu_usage_seconds_total{{namespace="{namespace}",container!=""}}[5m]))'
    )
    usage = {}
    for s in memory:
        usage.setdefault(s["labels"].get("pod"), {})["memory_mib"] = round(s["value"])
    for s in cpu:
        usage.setdefault(s["labels"].get("pod"), {})["cpu_cores"] = round(s["value"], 3)
    return usage


# ------------------------------------------------------------- cas d'usage 1

def split_warnings(warnings, unhealthy, nodes):
    """Sépare les alertes encore d'actualité de celles déjà réglées.

    Une alerte est « encore d'actualité » seulement si l'objet concerné va mal MAINTENANT :
    un pod de la liste des pods en mauvaise santé, ou un nœud qui n'est pas prêt.
    Sinon (par exemple un FailedScheduling au démarrage d'un pod qui tourne bien
    aujourd'hui), elle est déjà réglée. Ce tri est fait ici, dans le code, car un petit
    modèle d'IA a du mal à le faire seul.
    """
    problems = {f"{p['namespace']}/{p['pod']}" for p in unhealthy}
    problems |= {f"None/{n['node']}" for n in nodes if not n["ready"]}

    current, resolved = [], []
    for event in warnings:
        (current if event["object"] in problems else resolved).append(event)

    # Les alertes réglées : seulement un résumé, pour ne pas noyer le modèle.
    resolved_summary = sorted({f"{e['reason']} on {e['object']}" for e in resolved})
    return current, resolved_summary


def cluster_health():
    unhealthy = safe(list_unhealthy_pods)
    nodes = safe(list_nodes)
    restarts = safe(restarts_last_hour)
    warnings = safe(events, max_age_minutes=30, warnings_only=True)

    # Pour chaque redémarrage récent : le pod existe-t-il encore ?
    if isinstance(restarts, list) and isinstance(unhealthy, list):
        for r in restarts:
            r["pod_still_exists"] = safe(get_pod, r["namespace"], r["pod"]) is not None

    history = {"container_restarts_last_hour": restarts}
    if all(isinstance(x, list) for x in (warnings, unhealthy, nodes)):
        current, resolved = split_warnings(warnings, unhealthy, nodes)
        history["warning_events_still_relevant"] = current
        history["warning_events_already_resolved_object_is_healthy_now"] = resolved
    else:
        history["warning_events_last_30_min"] = warnings

    # Un résumé en une ligne, calculé par le code : le modèle s'appuie dessus.
    summary = "UNKNOWN: some data sources are unavailable"
    if isinstance(unhealthy, list) and isinstance(nodes, list):
        ready = sum(n["ready"] for n in nodes)
        summary = (
            f"{ready}/{len(nodes)} nodes Ready, {len(unhealthy)} unhealthy pods right now"
        )

    return {
        "use_case": "cluster health overview",
        "now": {
            "summary": summary,
            "nodes": nodes,
            "unhealthy_pods": unhealthy,
            "node_usage": safe(node_usage),
            "pods_per_namespace": safe(pods_per_namespace),
        },
        "history": history,
    }


# ------------------------------------------------------------- cas d'usage 1 bis

def namespace_overview(namespace):
    """Tous les pods d'un namespace, avec leur état et leurs ressources."""
    return {
        "use_case": "namespace overview",
        "namespace": namespace,
        "now": {
            "pods": safe(list_pods, namespace),
            "usage_per_pod": safe(pod_usage, namespace),
        },
        "history": {
            "restarts_last_hour": safe(restarts_last_hour_in_namespace, namespace),
            "warning_events_last_30_min": safe(
                events, namespace=namespace, max_age_minutes=30, warnings_only=True
            ),
        },
    }


def restarts_last_hour_in_namespace(namespace):
    return [r for r in restarts_last_hour() if r["namespace"] == namespace]


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
