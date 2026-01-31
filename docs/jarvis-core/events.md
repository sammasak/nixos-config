# Jarvis Core - Event System

> **Purpose:** Define event types, subjects, and schemas for the event-driven architecture.

---

## Overview

All Jarvis components communicate through events published to NATS JetStream. This enables:

- **Loose coupling** - Components don't know about each other
- **Observability** - All activity is visible in the event stream
- **Replay** - Events can be replayed for debugging or recovery
- **Scaling** - Multiple consumers can process events in parallel

---

## NATS JetStream Configuration

### Stream Definition

```yaml
name: JARVIS
subjects:
  - "jarvis.>"
retention: limits
max_bytes: 10737418240  # 10GB
max_age: 604800000000000  # 7 days in nanoseconds
storage: file
replicas: 1  # Single node for homelab
```

### Consumer Groups

| Consumer | Subjects | Purpose |
|----------|----------|---------|
| intent-processor | `jarvis.intent.received` | Parse and validate intents |
| task-planner | `jarvis.intent.parsed` | Create tasks from intents |
| code-agent | `jarvis.task.*.assigned` | Execute coding tasks |
| test-agent | `jarvis.task.*.test-requested` | Run tests |
| executor | `jarvis.workflow.*` | Bridge to Argo |
| knowledge-updater | `jarvis.knowledge.*` | Update knowledge graph |
| feedback-processor | `jarvis.feedback.*` | Process learning signals |

---

## Subject Hierarchy

```
jarvis.
├── intent.
│   ├── received      # Raw input from any source
│   ├── parsed        # Validated and structured
│   └── rejected      # Policy violation or error
│
├── task.
│   ├── created       # New task from intent
│   └── {task_id}.
│       ├── decomposed    # Broken into subtasks
│       ├── assigned      # Assigned to agent
│       ├── progress      # Progress update
│       ├── completed     # Successfully finished
│       └── failed        # Failed with error
│
├── agent.
│   └── {agent_id}.
│       ├── thinking      # Reasoning step (observability)
│       ├── action        # Tool invocation
│       └── observation   # Tool result
│
├── workflow.
│   ├── submitted     # Sent to Argo
│   ├── status        # Status change
│   └── completed     # Finished (success or failure)
│
├── knowledge.
│   ├── repo.indexed      # Repository scanned
│   ├── context.gathered  # Context assembled for task
│   └── updated           # Knowledge graph changed
│
└── feedback.
    ├── pr.merged     # PR was merged (positive signal)
    ├── pr.rejected   # PR was rejected (negative signal)
    └── user          # Explicit user feedback
```

---

## Event Envelope

All events share a common envelope:

```python
from pydantic import BaseModel
from datetime import datetime
from uuid import UUID

class EventEnvelope(BaseModel):
    """Base envelope for all events."""
    id: UUID                      # Unique event ID
    timestamp: datetime           # When event was created
    source: str                   # Component that created event
    correlation_id: UUID | None   # Links related events
    causation_id: UUID | None     # Event that caused this one

class Event(EventEnvelope):
    """Typed event with payload."""
    type: str                     # Event type discriminator
    data: dict                    # Event-specific payload
```

---

## Event Types

### Intent Events

#### `jarvis.intent.received`

Raw input from any source.

```python
class IntentReceived(BaseModel):
    raw_input: str
    source: IntentSource
    user_id: str | None
    session_id: UUID | None

class IntentSource(BaseModel):
    type: Literal["voice", "cli", "webhook", "ui"]
    metadata: dict  # Source-specific data

# Example
{
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": "2024-01-15T10:30:00Z",
    "source": "api-gateway",
    "type": "intent.received",
    "data": {
        "raw_input": "Update the authentication module to use JWT",
        "source": {
            "type": "voice",
            "metadata": {
                "transcript": "Update the authentication module to use JWT",
                "confidence": 0.95
            }
        },
        "user_id": "lukas",
        "session_id": "660e8400-e29b-41d4-a716-446655440001"
    }
}
```

#### `jarvis.intent.parsed`

Validated and structured intent.

```python
class IntentParsed(BaseModel):
    intent_id: UUID
    intent_type: Literal["change_request", "query", "status", "feedback"]
    description: str
    target_repo: str | None
    parameters: dict
    confidence: float

# Example
{
    "type": "intent.parsed",
    "data": {
        "intent_id": "550e8400-e29b-41d4-a716-446655440000",
        "intent_type": "change_request",
        "description": "Update authentication module to use JWT",
        "target_repo": "org/auth-service",
        "parameters": {
            "scope": "authentication",
            "change_type": "refactor"
        },
        "confidence": 0.92
    }
}
```

#### `jarvis.intent.rejected`

Intent rejected due to policy or error.

```python
class IntentRejected(BaseModel):
    intent_id: UUID
    reason: str
    error_code: str
    suggestion: str | None
```

---

### Task Events

#### `jarvis.task.created`

New task created from intent.

```python
class TaskCreated(BaseModel):
    task_id: UUID
    intent_id: UUID
    task_type: Literal["change_request", "analysis", "scan"]
    description: str
    target_repo: str
    priority: Literal["low", "normal", "high"]
    plan: TaskPlan | None

class TaskPlan(BaseModel):
    steps: list[PlanStep]
    estimated_files: list[str]
    risks: list[str]

class PlanStep(BaseModel):
    order: int
    description: str
    action_type: str
```

#### `jarvis.task.{id}.progress`

Progress update during execution.

```python
class TaskProgress(BaseModel):
    task_id: UUID
    phase: str  # "planning", "implementing", "testing", "reviewing"
    step: int
    total_steps: int
    message: str
    artifacts: list[str]  # Files modified so far
```

#### `jarvis.task.{id}.completed`

Task finished successfully.

```python
class TaskCompleted(BaseModel):
    task_id: UUID
    result: TaskResult
    duration_seconds: float

class TaskResult(BaseModel):
    success: bool
    pr_url: str | None
    files_changed: list[str]
    summary: str
```

#### `jarvis.task.{id}.failed`

Task failed.

```python
class TaskFailed(BaseModel):
    task_id: UUID
    error: str
    error_code: str
    phase: str
    recoverable: bool
    suggestion: str | None
```

---

### Agent Events

#### `jarvis.agent.{id}.thinking`

Agent reasoning step (for observability).

```python
class AgentThinking(BaseModel):
    agent_id: UUID
    task_id: UUID
    iteration: int
    thought: str
    observations_count: int
    next_action_hint: str | None
```

#### `jarvis.agent.{id}.action`

Agent invoking a tool.

```python
class AgentAction(BaseModel):
    agent_id: UUID
    task_id: UUID
    action_id: UUID
    tool: str
    input: dict

# Example tools:
# - read_file
# - write_file
# - search_code
# - run_command
# - search_similar
# - get_symbol_info
```

#### `jarvis.agent.{id}.observation`

Result from tool execution.

```python
class AgentObservation(BaseModel):
    agent_id: UUID
    task_id: UUID
    action_id: UUID
    success: bool
    output: str | dict
    duration_ms: int
```

---

### Workflow Events

#### `jarvis.workflow.submitted`

Workflow sent to Argo.

```python
class WorkflowSubmitted(BaseModel):
    workflow_name: str
    namespace: str
    template: str
    parameters: dict
    task_id: UUID
```

#### `jarvis.workflow.status`

Workflow status change.

```python
class WorkflowStatus(BaseModel):
    workflow_name: str
    phase: Literal["Pending", "Running", "Succeeded", "Failed", "Error"]
    message: str | None
    started_at: datetime | None
    finished_at: datetime | None
```

#### `jarvis.workflow.completed`

Workflow finished.

```python
class WorkflowCompleted(BaseModel):
    workflow_name: str
    task_id: UUID
    success: bool
    outputs: dict
    artifacts: list[str]
    duration_seconds: float
```

---

### Knowledge Events

#### `jarvis.knowledge.repo.indexed`

Repository added or updated in knowledge graph.

```python
class RepoIndexed(BaseModel):
    repo_id: UUID
    repo_url: str
    files_indexed: int
    symbols_extracted: int
    duration_seconds: float
```

#### `jarvis.knowledge.context.gathered`

Context assembled for a task.

```python
class ContextGathered(BaseModel):
    task_id: UUID
    files_included: list[str]
    symbols_included: list[str]
    token_count: int
    relevance_scores: dict[str, float]
```

---

### Feedback Events

#### `jarvis.feedback.pr.merged`

Positive learning signal - PR was accepted.

```python
class PRMerged(BaseModel):
    task_id: UUID
    pr_url: str
    merged_by: str
    time_to_merge_hours: float
```

#### `jarvis.feedback.pr.rejected`

Negative learning signal - PR was closed without merge.

```python
class PRRejected(BaseModel):
    task_id: UUID
    pr_url: str
    rejected_by: str
    reason: str | None
    comments: list[str]
```

#### `jarvis.feedback.user`

Explicit user feedback.

```python
class UserFeedback(BaseModel):
    task_id: UUID | None
    feedback_type: Literal["positive", "negative", "suggestion"]
    message: str
    context: dict | None
```

---

## Event Patterns

### Request-Response via Events

When a component needs a response:

```python
# Requester publishes with reply subject
await bus.publish(
    "jarvis.knowledge.context.request",
    ContextRequest(task_id=task_id, token_budget=8000),
    reply_to=f"jarvis.reply.{request_id}"
)

# Wait for response
response = await bus.subscribe_one(f"jarvis.reply.{request_id}", timeout=30)
```

### Event Sourcing

Task state can be reconstructed from events:

```python
events = await bus.get_events("jarvis.task.{task_id}.>")
task_state = TaskState()
for event in events:
    task_state.apply(event)
```

---

## Error Handling

### Dead Letter Queue

Failed events go to `jarvis.dlq.>`:

```python
class DeadLetterEvent(BaseModel):
    original_subject: str
    original_event: dict
    error: str
    retry_count: int
    first_failure: datetime
```

### Retry Policy

```yaml
max_retries: 3
backoff:
  initial: 1s
  multiplier: 2
  max: 30s
```

---

## Monitoring

### Key Metrics

```promql
# Events per second by subject
rate(jarvis_events_total[5m])

# Event processing latency
histogram_quantile(0.95, jarvis_event_latency_seconds_bucket)

# Dead letter queue size
jarvis_dlq_size

# Consumer lag
nats_consumer_pending_messages
```

---

## Related Documentation

- [Overview](overview.md) - System architecture
- [Knowledge Graph](knowledge-graph.md) - Database schema
- [Agents](agents.md) - Agent implementation
