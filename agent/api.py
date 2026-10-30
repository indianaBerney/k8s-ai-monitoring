"""API web compatible OpenAI, pour qu'Open WebUI voie l'agent comme un « modèle ».

Dans le cluster : voir Dockerfile et k8s/agent.yaml.
Sur un PC, pour tester (depuis le dossier agent) :
    $env:AGENT_API_KEY = "une-cle-secrete"
    uvicorn api:app --port 8001

Adresses :
    GET  /health            l'agent répond, et quel modèle d'IA il utilise
    GET  /health/sources    l'agent joint-il Prometheus, Loki et l'API Kubernetes ?
    GET  /v1/models         liste des modèles (clé API obligatoire)
    POST /v1/chat/completions   poser une question (clé API obligatoire)
"""

import json
import os
import time
import uuid

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from fastapi.concurrency import run_in_threadpool

import requests

from agent import answer
from llm import LLM_PROVIDER, BEDROCK_MODEL_ID, MODEL
from sources import LOKI_URL, list_nodes, prometheus

LLM_MODEL_NAME = BEDROCK_MODEL_ID if LLM_PROVIDER == "bedrock" else MODEL

MODEL_ID = "k8s-agent"
API_KEY = os.getenv("AGENT_API_KEY", "")

app = FastAPI(title="Kubernetes monitoring agent")


def check_key(authorization):
    if not API_KEY:
        raise HTTPException(500, "AGENT_API_KEY is not set on the server")
    if authorization != f"Bearer {API_KEY}":
        raise HTTPException(401, "Invalid API key")


def last_user_message(messages):
    for message in reversed(messages):
        if message.get("role") == "user":
            content = message.get("content", "")
            if isinstance(content, list):  # format « morceaux » d'Open WebUI
                content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
            return content
    return ""


@app.get("/health")
def health():
    """L'agent répond (utilisé par Kubernetes pour savoir si le pod est prêt)."""
    return {"status": "ok", "llm_provider": LLM_PROVIDER, "llm_model": LLM_MODEL_NAME}


@app.get("/health/sources")
def health_sources():
    """Vérifie que l'agent arrive à joindre chacune de ses sources de données."""
    checks = {
        "prometheus": lambda: prometheus("up") and "ok",
        "loki": lambda: requests.get(f"{LOKI_URL}/ready", timeout=5).raise_for_status() or "ok",
        "kubernetes": lambda: f"ok ({len(list_nodes())} node(s))",
    }
    result = {}
    for name, check in checks.items():
        try:
            result[name] = check() or "no data"
        except Exception as error:  # noqa: BLE001
            result[name] = f"UNAVAILABLE: {type(error).__name__}"
    result["status"] = "ok" if all(str(v).startswith("ok") for v in result.values()) else "degraded"
    return result


@app.get("/v1/models")
def models(authorization: str = Header(None)):
    check_key(authorization)
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "groupe19"}]}


@app.post("/v1/chat/completions")
async def chat(body: dict, authorization: str = Header(None)):
    check_key(authorization)
    question = last_user_message(body.get("messages", []))

    # Open WebUI demande aussi au modèle de générer un titre, des tags, des suggestions.
    # On répond tout de suite, sans interroger le cluster.
    if question.lstrip().startswith("### Task:"):
        text = json.dumps({"title": "Kubernetes monitoring", "tags": ["Kubernetes"], "follow_ups": []})
    else:
        try:
            text = await run_in_threadpool(answer, question)
        except Exception as error:  # noqa: BLE001
            text = f"The agent failed: {type(error).__name__}: {error}"

    reply_id = f"chatcmpl-{uuid.uuid4().hex}"
    created = int(time.time())

    if body.get("stream"):
        def stream():
            chunk = {
                "id": reply_id, "object": "chat.completion.chunk", "created": created, "model": MODEL_ID,
                "choices": [{"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": None}],
            }
            yield f"data: {json.dumps(chunk)}\n\n"
            end = {**chunk, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            yield f"data: {json.dumps(end)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(stream(), media_type="text/event-stream")

    return {
        "id": reply_id, "object": "chat.completion", "created": created, "model": MODEL_ID,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
    }
