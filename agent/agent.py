"""Le cerveau de l'agent : comprend la question, rassemble les preuves, interroge le modèle.

On peut le tester directement dans le terminal :
    python agent.py "How healthy is my cluster?"
"""

import re
import sys

#from evidence import cluster_health, investigate_pod, root_cause
from agent.evidence import cluster_health, investigate_pod, root_cause
from agent.llm import ask_model

HELP = (
    "I can answer three kinds of questions:\n"
    "- How healthy is my cluster?\n"
    "- Investigate pod <name> in namespace <namespace>\n"
    "- Root-cause analysis of pod <name> in namespace <namespace>"
)

POD_PATTERN = re.compile(
    r"\bpod\s+([a-z0-9][a-z0-9.-]*)\b.*?\bnamespace\s+([a-z0-9][a-z0-9-]*)\b"
)


def collect_evidence(question):
    """Choisit le bon cas d'usage selon la question. Renvoie None si on ne comprend pas."""
    text = question.lower()
    match = POD_PATTERN.search(text)

    if match:
        pod, namespace = match.groups()
        if any(word in text for word in ("root", "cause", "why", "pourquoi", "rca")):
            return root_cause(namespace, pod)
        return investigate_pod(namespace, pod)

    if any(word in text for word in ("cluster", "health", "healthy", "santé", "overview", "état")):
        return cluster_health()

    return None


def answer(question):
    evidence = collect_evidence(question)
    if evidence is None:
        return HELP
    return ask_model(question, evidence)


if __name__ == "__main__":
    question = " ".join(sys.argv[1:]) or "How healthy is my cluster?"
    print(answer(question))
