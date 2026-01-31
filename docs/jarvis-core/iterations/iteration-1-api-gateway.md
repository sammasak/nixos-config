# Jarvis Iteration 1: API Gateway

> **Goal:** REST API that accepts intents and publishes to the event bus.
>
> **Status:** ⬜ Not Started

---

## Overview

The API Gateway is the entry point for all external interactions with Jarvis. It accepts requests via REST, WebSocket, or webhooks, validates them, and publishes events to the bus.

---

## Prerequisites

- [Iteration 0: Event Bus](iteration-0-event-bus.md) complete
- NATS JetStream running
- Event types defined

---

## Architecture

```
                    ┌─────────────────────────────────────┐
                    │           API Gateway               │
                    │                                     │
    REST ──────────▶│  ┌─────────┐    ┌──────────────┐   │
                    │  │ FastAPI │───▶│ Intent       │   │
    WebSocket ─────▶│  │ Router  │    │ Parser       │   │
                    │  └─────────┘    └──────┬───────┘   │
    Webhooks ──────▶│                        │           │
                    │                        ▼           │
                    │               ┌──────────────┐     │
                    │               │ Bus Client   │─────┼───▶ NATS
                    │               └──────────────┘     │
                    └─────────────────────────────────────┘
```

---

## Work Units

### 1.1 FastAPI Application Setup

**Goal:** Create the base FastAPI application.

**Tasks:**
- [ ] Set up Python project with uv
- [ ] Create FastAPI application structure
- [ ] Configure logging and error handling
- [ ] Add health check endpoints

**Project Structure:**

```
jarvis/src/jarvis_api/
├── __init__.py
├── main.py           # FastAPI app entry
├── config.py         # Configuration
├── routes/
│   ├── __init__.py
│   ├── intents.py    # Intent endpoints
│   ├── tasks.py      # Task query endpoints
│   └── health.py     # Health checks
├── services/
│   ├── __init__.py
│   ├── intent_parser.py
│   └── bus.py        # Event bus client
└── models/
    ├── __init__.py
    └── requests.py   # Request/response models
```

**Main Application:**

```python
# jarvis/src/jarvis_api/main.py
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import settings
from .routes import intents, tasks, health
from .services.bus import bus_client

@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await bus_client.connect(settings.nats_url, "jarvis-api")
    yield
    # Shutdown
    await bus_client.close()

app = FastAPI(
    title="Jarvis API",
    description="API Gateway for Jarvis Core",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router, tags=["health"])
app.include_router(intents.router, prefix="/api/v1", tags=["intents"])
app.include_router(tasks.router, prefix="/api/v1", tags=["tasks"])
```

**Configuration:**

```python
# jarvis/src/jarvis_api/config.py
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # NATS
    nats_url: str = "nats://nats.jarvis:4222"

    # API
    api_key: str = ""  # Set via environment
    cors_origins: list[str] = ["*"]

    # Logging
    log_level: str = "INFO"

    class Config:
        env_prefix = "JARVIS_"

settings = Settings()
```

---

### 1.2 Intent Endpoints

**Goal:** Create endpoints for submitting intents.

**Tasks:**
- [ ] Implement POST /api/v1/intents
- [ ] Add request validation
- [ ] Publish IntentReceived events
- [ ] Return intent ID for tracking

**Intent Routes:**

```python
# jarvis/src/jarvis_api/routes/intents.py
from uuid import UUID, uuid4
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from ..services.bus import bus_client
from ..services.intent_parser import parse_intent
from ..auth import verify_api_key
from jarvis_events import IntentReceived, IntentSource

router = APIRouter()

class IntentRequest(BaseModel):
    """Request to submit an intent."""
    input: str
    source: IntentSource = IntentSource.API
    conversation_id: UUID | None = None

class IntentResponse(BaseModel):
    """Response with intent tracking info."""
    intent_id: UUID
    status: str = "received"
    message: str = "Intent received and queued for processing"

@router.post("/intents", response_model=IntentResponse)
async def submit_intent(
    request: IntentRequest,
    user_id: str = Depends(verify_api_key),
):
    """Submit a new intent for processing."""
    intent_id = uuid4()

    # Create event
    event = IntentReceived(
        raw_input=request.input,
        source=request.source,
        user_id=user_id,
        conversation_id=request.conversation_id,
    )

    # Publish to bus
    await bus_client.publish(
        "jarvis.intent.received",
        event,
        correlation_id=intent_id,
    )

    return IntentResponse(intent_id=intent_id)

@router.get("/intents/{intent_id}")
async def get_intent_status(
    intent_id: UUID,
    user_id: str = Depends(verify_api_key),
):
    """Get status of an intent."""
    # Query knowledge graph for intent status
    # This will be implemented in iteration 2
    return {"intent_id": intent_id, "status": "processing"}
```

---

### 1.3 Task Query Endpoints

**Goal:** Create endpoints for querying task status.

**Tasks:**
- [ ] Implement GET /api/v1/tasks
- [ ] Implement GET /api/v1/tasks/{id}
- [ ] Implement GET /api/v1/tasks/{id}/logs
- [ ] Add filtering and pagination

**Task Routes:**

```python
# jarvis/src/jarvis_api/routes/tasks.py
from uuid import UUID
from fastapi import APIRouter, Query, Depends
from pydantic import BaseModel
from typing import Literal

from ..auth import verify_api_key

router = APIRouter()

class TaskSummary(BaseModel):
    id: UUID
    description: str
    status: Literal["pending", "running", "completed", "failed"]
    created_at: str
    completed_at: str | None = None

class TaskDetail(TaskSummary):
    intent_id: UUID
    task_type: str
    target_repo: str | None
    result: dict | None = None
    pr_url: str | None = None

class TaskList(BaseModel):
    tasks: list[TaskSummary]
    total: int
    page: int
    page_size: int

@router.get("/tasks", response_model=TaskList)
async def list_tasks(
    status: str | None = None,
    repo: str | None = None,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    user_id: str = Depends(verify_api_key),
):
    """List tasks with optional filtering."""
    # Query knowledge graph
    # Implemented in iteration 2
    return TaskList(tasks=[], total=0, page=page, page_size=page_size)

@router.get("/tasks/{task_id}", response_model=TaskDetail)
async def get_task(
    task_id: UUID,
    user_id: str = Depends(verify_api_key),
):
    """Get detailed task information."""
    # Query knowledge graph
    pass

@router.get("/tasks/{task_id}/logs")
async def get_task_logs(
    task_id: UUID,
    user_id: str = Depends(verify_api_key),
):
    """Get task execution logs."""
    # Query from agent events or Argo logs
    return {"logs": []}
```

---

### 1.4 WebSocket Real-Time Updates

**Goal:** Stream task updates via WebSocket.

**Tasks:**
- [ ] Implement WebSocket endpoint
- [ ] Subscribe to relevant NATS subjects
- [ ] Forward events to connected clients
- [ ] Handle connection lifecycle

**WebSocket Route:**

```python
# jarvis/src/jarvis_api/routes/stream.py
import asyncio
import json
from uuid import UUID
from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query
from ..services.bus import bus_client
from jarvis_events import TaskCreated, TaskCompleted, AgentThinking

router = APIRouter()

@router.websocket("/api/v1/stream")
async def websocket_stream(
    websocket: WebSocket,
    task_id: UUID | None = Query(None),
    api_key: str = Query(...),
):
    """Stream real-time updates via WebSocket."""
    # Verify API key
    # ...

    await websocket.accept()

    # Determine filter subject
    if task_id:
        filter_subject = f"jarvis.task.{task_id}.>"
    else:
        filter_subject = "jarvis.>"

    try:
        # Subscribe to events
        async for event in bus_client.subscribe_realtime(filter_subject):
            await websocket.send_json({
                "type": event.__class__.__name__,
                "data": event.model_dump(),
            })
    except WebSocketDisconnect:
        pass
```

**Client Usage:**

```javascript
// JavaScript client example
const ws = new WebSocket('wss://jarvis.homelab.local/api/v1/stream?api_key=xxx');

ws.onmessage = (event) => {
  const data = JSON.parse(event.data);
  console.log(`Event: ${data.type}`, data.data);

  switch (data.type) {
    case 'AgentThinking':
      updateThinkingIndicator(data.data.thought);
      break;
    case 'TaskCompleted':
      showCompletion(data.data);
      break;
  }
};
```

---

### 1.5 Authentication

**Goal:** Implement API key authentication.

**Tasks:**
- [ ] Create API key validation
- [ ] Add rate limiting
- [ ] Log authentication events
- [ ] Support multiple keys per user

**Authentication Module:**

```python
# jarvis/src/jarvis_api/auth.py
from fastapi import HTTPException, Security, status
from fastapi.security import APIKeyHeader
import hashlib
import hmac

from .config import settings

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)

# In production, store hashed keys in database
VALID_API_KEYS = {
    # hash: user_id
}

def hash_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()

async def verify_api_key(
    api_key: str | None = Security(api_key_header),
) -> str:
    """Verify API key and return user ID."""
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key required",
        )

    # For development, accept configured key
    if settings.api_key and hmac.compare_digest(api_key, settings.api_key):
        return "default-user"

    # Check against stored keys
    key_hash = hash_key(api_key)
    if key_hash in VALID_API_KEYS:
        return VALID_API_KEYS[key_hash]

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid API key",
    )
```

---

### 1.6 Kubernetes Deployment

**Goal:** Deploy API Gateway to cluster.

**Tasks:**
- [ ] Create Deployment manifest
- [ ] Create Service manifest
- [ ] Configure Ingress
- [ ] Set up secrets

**Deployment:**

```yaml
# jarvis/manifests/overlays/homelab/api/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jarvis-api
  namespace: jarvis
spec:
  replicas: 2
  selector:
    matchLabels:
      app: jarvis-api
  template:
    metadata:
      labels:
        app: jarvis-api
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: api
          image: jarvis-api:latest
          ports:
            - containerPort: 8000
          env:
            - name: JARVIS_NATS_URL
              value: "nats://nats:4222"
            - name: JARVIS_API_KEY
              valueFrom:
                secretKeyRef:
                  name: jarvis-api-secrets
                  key: api-key
          resources:
            requests:
              memory: 128Mi
              cpu: 100m
            limits:
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8000
            initialDelaySeconds: 5
```

**Ingress:**

```yaml
# jarvis/manifests/overlays/homelab/api/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: jarvis-api
  namespace: jarvis
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
    - host: jarvis.homelab.local
      http:
        paths:
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: jarvis-api
                port:
                  number: 8000
          - path: /docs
            pathType: Prefix
            backend:
              service:
                name: jarvis-api
                port:
                  number: 8000
  tls:
    - hosts:
        - jarvis.homelab.local
      secretName: jarvis-tls
```

---

## Definition of Done

- [ ] FastAPI application deployed and healthy
- [ ] `POST /api/v1/intents` accepts requests
- [ ] Intent events published to NATS
- [ ] WebSocket streams task updates
- [ ] API key authentication working
- [ ] Swagger docs available at `/docs`

---

## Verification Steps

```bash
# 1. Check deployment
kubectl get pods -n jarvis -l app=jarvis-api
# Expected: 2 pods Running

# 2. Check health
curl https://jarvis.homelab.local/health
# Expected: {"status": "healthy"}

# 3. Submit intent
curl -X POST https://jarvis.homelab.local/api/v1/intents \
  -H "X-API-Key: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input": "update the readme"}'
# Expected: {"intent_id": "...", "status": "received"}

# 4. Check event in NATS
kubectl exec -it nats-0 -n jarvis -- nats stream view INTENTS
# Expected: IntentReceived event visible

# 5. Access Swagger docs
# Open: https://jarvis.homelab.local/docs
```

---

## API Reference

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Health check |
| `/health/ready` | GET | Readiness check |
| `/api/v1/intents` | POST | Submit intent |
| `/api/v1/intents/{id}` | GET | Get intent status |
| `/api/v1/tasks` | GET | List tasks |
| `/api/v1/tasks/{id}` | GET | Get task details |
| `/api/v1/tasks/{id}/logs` | GET | Get task logs |
| `/api/v1/stream` | WS | Real-time updates |

---

## Next Steps

After this iteration:
- [Iteration 2: Knowledge Graph](iteration-2-knowledge.md) - Enable task queries
- [Iteration 3: Single Agent](iteration-3-single-agent.md) - Process intents

