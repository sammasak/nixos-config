# Jarvis Iteration 0: Event Bus

> **Goal:** Establish NATS JetStream as the messaging backbone.
>
> **Status:** ⬜ Not Started

---

## Overview

The event bus is the nervous system of Jarvis. All components communicate through events, enabling loose coupling, observability, and replay capabilities.

---

## Prerequisites

- [Platform Iteration 0](../../homelab-platform/iterations/iteration-0-foundation.md) complete
- Kubernetes cluster running
- Flux reconciling

---

## Why NATS JetStream?

| Consideration | NATS JetStream | Alternatives |
|---------------|----------------|--------------|
| Purpose-built | Messaging-first design | Redis Streams is DB + messaging |
| Persistence | Built-in with replay | Kafka heavier for homelab |
| Subject routing | Wildcard subscriptions | RabbitMQ similar but heavier |
| Operational | Single binary | Kafka needs ZooKeeper |
| Scale | Perfect for homelab | Overkill avoided |

---

## Work Units

### 0.1 NATS JetStream Deployment

**Goal:** Deploy NATS with JetStream enabled.

**Tasks:**
- [ ] Add NATS Helm repository
- [ ] Create HelmRelease for NATS
- [ ] Configure JetStream storage
- [ ] Verify cluster is healthy

**Helm Repository:**

```yaml
# platform/clusters/homelab/sources/nats.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: nats
  namespace: flux-system
spec:
  interval: 1h
  url: https://nats-io.github.io/k8s/helm/charts/
```

**HelmRelease:**

```yaml
# platform/clusters/homelab/infra/jarvis/nats/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: nats
  namespace: jarvis
spec:
  interval: 30m
  chart:
    spec:
      chart: nats
      version: "1.1.x"
      sourceRef:
        kind: HelmRepository
        name: nats
        namespace: flux-system
  values:
    config:
      cluster:
        enabled: false  # Single node for homelab

      jetstream:
        enabled: true
        fileStore:
          pvc:
            enabled: true
            size: 10Gi

      # Monitoring
      monitor:
        enabled: true
        port: 8222

    # Resources
    container:
      resources:
        requests:
          memory: 256Mi
          cpu: 100m
        limits:
          memory: 1Gi

    # Metrics for Prometheus
    promExporter:
      enabled: true
      port: 7777
```

**Namespace:**

```yaml
# platform/clusters/homelab/infra/jarvis/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: jarvis
  labels:
    name: jarvis
```

---

### 0.2 Stream Configuration

**Goal:** Create JetStream streams for all event subjects.

**Tasks:**
- [ ] Define stream configuration
- [ ] Create streams via init job
- [ ] Configure retention policies
- [ ] Test stream creation

**Stream Definitions:**

```yaml
# jarvis/manifests/nats/streams.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: nats-stream-setup
  namespace: jarvis
spec:
  template:
    spec:
      containers:
        - name: setup
          image: natsio/nats-box:latest
          command:
            - /bin/sh
            - -c
            - |
              # Wait for NATS
              until nats server ping -s nats://nats:4222; do sleep 1; done

              # Intent stream
              nats stream add INTENTS \
                --subjects "jarvis.intent.>" \
                --retention limits \
                --max-msgs 100000 \
                --max-age 7d \
                --storage file \
                --replicas 1 \
                --discard old \
                --dupe-window 2m

              # Task stream
              nats stream add TASKS \
                --subjects "jarvis.task.>" \
                --retention limits \
                --max-msgs 100000 \
                --max-age 30d \
                --storage file \
                --replicas 1 \
                --discard old

              # Agent stream (high volume, shorter retention)
              nats stream add AGENTS \
                --subjects "jarvis.agent.>" \
                --retention limits \
                --max-msgs 1000000 \
                --max-age 24h \
                --storage file \
                --replicas 1 \
                --discard old

              # Workflow stream
              nats stream add WORKFLOWS \
                --subjects "jarvis.workflow.>" \
                --retention limits \
                --max-msgs 50000 \
                --max-age 7d \
                --storage file \
                --replicas 1

              # Knowledge stream
              nats stream add KNOWLEDGE \
                --subjects "jarvis.knowledge.>" \
                --retention limits \
                --max-msgs 50000 \
                --max-age 30d \
                --storage file \
                --replicas 1

              # Feedback stream (long retention for learning)
              nats stream add FEEDBACK \
                --subjects "jarvis.feedback.>" \
                --retention limits \
                --max-msgs 100000 \
                --max-age 365d \
                --storage file \
                --replicas 1

              echo "Streams created successfully"
      restartPolicy: OnFailure
```

---

### 0.3 Event Type Definitions (Rust)

**Goal:** Define event schemas in Rust for type safety.

**Tasks:**
- [ ] Create `jarvis-events` crate
- [ ] Define all event types
- [ ] Implement serialization
- [ ] Add validation

**Cargo.toml:**

```toml
# jarvis/crates/jarvis-events/Cargo.toml
[package]
name = "jarvis-events"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
uuid = { version = "1.0", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
thiserror = "1.0"
```

**Event Types:**

```rust
// jarvis/crates/jarvis-events/src/lib.rs
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Event envelope wrapping all events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EventEnvelope<T> {
    pub id: Uuid,
    pub timestamp: DateTime<Utc>,
    pub source: String,
    pub correlation_id: Option<Uuid>,
    pub payload: T,
}

impl<T> EventEnvelope<T> {
    pub fn new(source: impl Into<String>, payload: T) -> Self {
        Self {
            id: Uuid::new_v4(),
            timestamp: Utc::now(),
            source: source.into(),
            correlation_id: None,
            payload,
        }
    }

    pub fn with_correlation(mut self, correlation_id: Uuid) -> Self {
        self.correlation_id = Some(correlation_id);
        self
    }
}

// Intent Events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentReceived {
    pub raw_input: String,
    pub source: IntentSource,
    pub user_id: Option<String>,
    pub conversation_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IntentSource {
    Voice,
    Cli,
    Api,
    Webhook,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IntentParsed {
    pub intent_id: Uuid,
    pub action: String,
    pub target_repo: Option<String>,
    pub parameters: serde_json::Value,
    pub confidence: f32,
}

// Task Events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCreated {
    pub task_id: Uuid,
    pub intent_id: Uuid,
    pub description: String,
    pub task_type: TaskType,
    pub target_repo_id: Option<Uuid>,
    pub priority: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskType {
    CodeChange,
    TestRun,
    Review,
    Deploy,
    Query,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskCompleted {
    pub task_id: Uuid,
    pub success: bool,
    pub result: serde_json::Value,
    pub pr_url: Option<String>,
    pub duration_ms: u64,
}

// Agent Events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentThinking {
    pub agent_id: Uuid,
    pub task_id: Uuid,
    pub thought: String,
    pub step: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentAction {
    pub agent_id: Uuid,
    pub task_id: Uuid,
    pub tool: String,
    pub parameters: serde_json::Value,
    pub rationale: String,
}

// Workflow Events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowSubmitted {
    pub workflow_id: String,
    pub task_id: Uuid,
    pub template_name: String,
    pub parameters: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkflowCompleted {
    pub workflow_id: String,
    pub task_id: Uuid,
    pub success: bool,
    pub outputs: serde_json::Value,
}

// Feedback Events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeedbackReceived {
    pub task_id: Uuid,
    pub feedback_type: FeedbackType,
    pub source: String,
    pub context: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedbackType {
    PrMerged,
    PrRejected,
    UserPositive,
    UserNegative,
}
```

---

### 0.4 Event Type Definitions (Python)

**Goal:** Mirror event schemas in Python for agent code.

**Tasks:**
- [ ] Create `jarvis_events` package
- [ ] Define Pydantic models
- [ ] Ensure compatibility with Rust types
- [ ] Add serialization helpers

**Python Package:**

```python
# jarvis/src/jarvis_events/__init__.py
from .intents import IntentReceived, IntentParsed, IntentSource
from .tasks import TaskCreated, TaskCompleted, TaskType
from .agents import AgentThinking, AgentAction
from .workflows import WorkflowSubmitted, WorkflowCompleted
from .feedback import FeedbackReceived, FeedbackType
from .envelope import EventEnvelope

__all__ = [
    "EventEnvelope",
    "IntentReceived", "IntentParsed", "IntentSource",
    "TaskCreated", "TaskCompleted", "TaskType",
    "AgentThinking", "AgentAction",
    "WorkflowSubmitted", "WorkflowCompleted",
    "FeedbackReceived", "FeedbackType",
]
```

```python
# jarvis/src/jarvis_events/envelope.py
from datetime import datetime
from typing import Generic, TypeVar
from uuid import UUID, uuid4
from pydantic import BaseModel, Field

T = TypeVar("T")

class EventEnvelope(BaseModel, Generic[T]):
    """Wrapper for all events."""
    id: UUID = Field(default_factory=uuid4)
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    source: str
    correlation_id: UUID | None = None
    payload: T

    @classmethod
    def create(cls, source: str, payload: T, correlation_id: UUID | None = None):
        return cls(source=source, payload=payload, correlation_id=correlation_id)
```

```python
# jarvis/src/jarvis_events/intents.py
from enum import Enum
from uuid import UUID
from pydantic import BaseModel
from typing import Any

class IntentSource(str, Enum):
    VOICE = "voice"
    CLI = "cli"
    API = "api"
    WEBHOOK = "webhook"

class IntentReceived(BaseModel):
    raw_input: str
    source: IntentSource
    user_id: str | None = None
    conversation_id: UUID | None = None

class IntentParsed(BaseModel):
    intent_id: UUID
    action: str
    target_repo: str | None = None
    parameters: dict[str, Any] = {}
    confidence: float
```

---

### 0.5 Bus Client Library

**Goal:** Create client libraries for publishing/subscribing.

**Tasks:**
- [ ] Create Rust client (`jarvis-bus`)
- [ ] Create Python client
- [ ] Implement publish/subscribe patterns
- [ ] Add error handling and retries

**Rust Client:**

```rust
// jarvis/crates/jarvis-bus/src/lib.rs
use async_nats::jetstream::{self, Context};
use jarvis_events::EventEnvelope;
use serde::{de::DeserializeOwned, Serialize};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum BusError {
    #[error("NATS error: {0}")]
    Nats(#[from] async_nats::Error),
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
}

pub struct JarvisBus {
    jetstream: Context,
    source: String,
}

impl JarvisBus {
    pub async fn connect(url: &str, source: &str) -> Result<Self, BusError> {
        let client = async_nats::connect(url).await?;
        let jetstream = jetstream::new(client);

        Ok(Self {
            jetstream,
            source: source.to_string(),
        })
    }

    pub async fn publish<T: Serialize>(
        &self,
        subject: &str,
        payload: T,
    ) -> Result<(), BusError> {
        let envelope = EventEnvelope::new(&self.source, payload);
        let data = serde_json::to_vec(&envelope)?;

        self.jetstream
            .publish(subject.to_string(), data.into())
            .await?
            .await?;

        Ok(())
    }

    pub async fn subscribe<T: DeserializeOwned>(
        &self,
        stream: &str,
        consumer: &str,
        filter: &str,
    ) -> Result<impl futures::Stream<Item = Result<EventEnvelope<T>, BusError>>, BusError> {
        let stream = self.jetstream.get_stream(stream).await?;

        let consumer = stream
            .get_or_create_consumer(
                consumer,
                jetstream::consumer::pull::Config {
                    filter_subject: filter.to_string(),
                    ..Default::default()
                },
            )
            .await?;

        let messages = consumer.messages().await?;

        Ok(messages.map(|msg| {
            let msg = msg.map_err(BusError::from)?;
            let envelope: EventEnvelope<T> = serde_json::from_slice(&msg.payload)?;
            msg.ack().await.map_err(BusError::from)?;
            Ok(envelope)
        }))
    }
}
```

**Python Client:**

```python
# jarvis/src/jarvis_bus/client.py
import json
from typing import TypeVar, Type, AsyncIterator
from uuid import UUID
import nats
from nats.js import JetStreamContext
from jarvis_events import EventEnvelope

T = TypeVar("T")

class JarvisBus:
    """NATS JetStream client for Jarvis events."""

    def __init__(self, js: JetStreamContext, source: str):
        self.js = js
        self.source = source

    @classmethod
    async def connect(cls, url: str, source: str) -> "JarvisBus":
        nc = await nats.connect(url)
        js = nc.jetstream()
        return cls(js, source)

    async def publish(
        self,
        subject: str,
        payload: any,
        correlation_id: UUID | None = None,
    ) -> None:
        """Publish an event to the bus."""
        envelope = EventEnvelope.create(
            source=self.source,
            payload=payload,
            correlation_id=correlation_id,
        )
        data = envelope.model_dump_json().encode()
        await self.js.publish(subject, data)

    async def subscribe(
        self,
        stream: str,
        consumer: str,
        filter_subject: str,
        payload_type: Type[T],
    ) -> AsyncIterator[EventEnvelope[T]]:
        """Subscribe to events from a stream."""
        sub = await self.js.pull_subscribe(
            filter_subject,
            durable=consumer,
            stream=stream,
        )

        while True:
            try:
                msgs = await sub.fetch(batch=10, timeout=5)
                for msg in msgs:
                    data = json.loads(msg.data.decode())
                    payload = payload_type(**data["payload"])
                    envelope = EventEnvelope[T](
                        id=UUID(data["id"]),
                        timestamp=data["timestamp"],
                        source=data["source"],
                        correlation_id=UUID(data["correlation_id"]) if data.get("correlation_id") else None,
                        payload=payload,
                    )
                    yield envelope
                    await msg.ack()
            except nats.errors.TimeoutError:
                continue
```

---

## Definition of Done

- [ ] NATS JetStream running in `jarvis` namespace
- [ ] All streams created with appropriate retention
- [ ] Event types defined in both Rust and Python
- [ ] Can publish events from Python
- [ ] Can subscribe and receive events
- [ ] Replay from stream working

---

## Verification Steps

```bash
# 1. Check NATS is running
kubectl get pods -n jarvis -l app.kubernetes.io/name=nats
# Expected: nats-0 Running

# 2. Check streams exist
kubectl exec -it nats-0 -n jarvis -- nats stream ls
# Expected: INTENTS, TASKS, AGENTS, etc.

# 3. Publish test event
kubectl exec -it nats-0 -n jarvis -- nats pub jarvis.intent.received \
  '{"raw_input":"test","source":"cli"}'

# 4. Check message in stream
kubectl exec -it nats-0 -n jarvis -- nats stream view INTENTS
# Expected: Message visible

# 5. Test Python client
python -c "
import asyncio
from jarvis_bus import JarvisBus
from jarvis_events import IntentReceived, IntentSource

async def test():
    bus = await JarvisBus.connect('nats://localhost:4222', 'test')
    await bus.publish(
        'jarvis.intent.received',
        IntentReceived(raw_input='hello', source=IntentSource.CLI)
    )
    print('Published!')

asyncio.run(test())
"
```

---

## Troubleshooting

| Issue | Check | Solution |
|-------|-------|----------|
| NATS won't start | `kubectl logs nats-0 -n jarvis` | Check PVC, resources |
| Stream not found | `nats stream ls` | Run stream setup job |
| Publish fails | Network connectivity | Check service DNS |
| Consumer lag | `nats consumer info` | Increase consumers |

---

## Next Steps

After this iteration:
- [Iteration 1: API Gateway](iteration-1-api-gateway.md) - REST API for intents
- [Iteration 2: Knowledge Graph](iteration-2-knowledge.md) - PostgreSQL + pgvector

