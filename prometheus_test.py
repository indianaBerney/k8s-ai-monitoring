import requests

PROMETHEUS_URL = "http://localhost:9090"

def query_prometheus(query):
    """Envoie une requête PromQL à Prometheus et renvoie la liste des résultats."""
    response = requests.get(
        f"{PROMETHEUS_URL}/api/v1/query",
        params={"query": query},
        timeout=20,
    )
    response.raise_for_status()
    return response.json()["data"]["result"]

# Les pods dont la phase n'est pas "Running" ni "Succeeded"
resultats = query_prometheus(
    'kube_pod_status_phase{phase!~"Running|Succeeded"} == 1'
)

if not resultats:
    print("Tous les pods tournent normalement.")
else:
    for r in resultats:
        labels = r["metric"]
        print(f"{labels['namespace']}/{labels['pod']} : {labels['phase']}")