# Jarvis Iteration 5: Conversations

> **Goal:** Stateful conversation sessions with context preservation.
>
> **Status:** ⬜ Not Started

---

## Overview

This iteration adds stateful conversations to Jarvis. Users can have multi-turn dialogues where context is preserved, clarifications can be requested, and the agent remembers previous interactions.

---

## Prerequisites

- [Iteration 4: Multi-Agent](iteration-4-multi-agent.md) complete
- Full agent pipeline working

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Conversation Manager                       │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  Session Store                       │   │
│  │                                                      │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│  │  │ Session A   │  │ Session B   │  │ Session C   │  │   │
│  │  │             │  │             │  │             │  │   │
│  │  │ Messages    │  │ Messages    │  │ Messages    │  │   │
│  │  │ Context     │  │ Context     │  │ Context     │  │   │
│  │  │ State       │  │ State       │  │ State       │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Context Accumulator                     │   │
│  │                                                      │   │
│  │  • Referenced files    • Mentioned repos             │   │
│  │  • User preferences    • Task outcomes               │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Clarification Handler                   │   │
│  │                                                      │   │
│  │  • Detect ambiguity    • Generate questions          │   │
│  │  • Wait for response   • Resume with context         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Work Units

### 5.1 Conversation State Management

**Goal:** Store and manage conversation state.

**Tasks:**
- [ ] Define conversation data model
- [ ] Implement session storage
- [ ] Add message history
- [ ] Handle session expiry

**Conversation Models:**

```python
# jarvis/src/jarvis_conversations/models.py
from datetime import datetime, timedelta
from uuid import UUID, uuid4
from pydantic import BaseModel, Field
from typing import Literal

class Message(BaseModel):
    """A message in the conversation."""
    id: UUID = Field(default_factory=uuid4)
    role: Literal["user", "assistant", "system"]
    content: str
    timestamp: datetime = Field(default_factory=datetime.utcnow)
    metadata: dict = Field(default_factory=dict)

class ConversationContext(BaseModel):
    """Accumulated context from conversation."""
    referenced_repos: list[UUID] = Field(default_factory=list)
    referenced_files: list[str] = Field(default_factory=list)
    active_task_id: UUID | None = None
    user_preferences: dict = Field(default_factory=dict)
    clarifications_pending: list[dict] = Field(default_factory=list)

class Conversation(BaseModel):
    """A conversation session."""
    id: UUID = Field(default_factory=uuid4)
    user_id: str | None = None
    messages: list[Message] = Field(default_factory=list)
    context: ConversationContext = Field(default_factory=ConversationContext)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_activity: datetime = Field(default_factory=datetime.utcnow)
    expires_at: datetime = Field(
        default_factory=lambda: datetime.utcnow() + timedelta(hours=24)
    )
    state: Literal["active", "waiting", "completed"] = "active"
```

**Conversation Store:**

```python
# jarvis/src/jarvis_conversations/store.py
from uuid import UUID
from datetime import datetime
from jarvis_knowledge import KnowledgeClient
from .models import Conversation, Message, ConversationContext

class ConversationStore:
    """Store and retrieve conversations."""

    def __init__(self, knowledge: KnowledgeClient):
        self.knowledge = knowledge

    async def create(self, user_id: str | None = None) -> Conversation:
        """Create a new conversation."""
        conversation = Conversation(user_id=user_id)

        await self.knowledge.create_conversation(
            id=conversation.id,
            user_id=user_id,
            context=conversation.context.model_dump(),
        )

        return conversation

    async def get(self, conversation_id: UUID) -> Conversation | None:
        """Get a conversation by ID."""
        row = await self.knowledge.get_conversation(conversation_id)
        if not row:
            return None

        messages = await self.knowledge.get_conversation_messages(conversation_id)

        return Conversation(
            id=row["id"],
            user_id=row["user_id"],
            messages=[Message(**m) for m in messages],
            context=ConversationContext(**row["context"]),
            created_at=row["started_at"],
            last_activity=row["last_activity_at"],
            expires_at=row["expires_at"],
        )

    async def add_message(
        self,
        conversation_id: UUID,
        message: Message,
    ) -> None:
        """Add a message to conversation."""
        # Store message
        await self.knowledge.add_conversation_message(
            conversation_id=conversation_id,
            role=message.role,
            content=message.content,
            embedding=await self.get_embedding(message.content),
        )

        # Update last activity
        await self.knowledge.update_conversation_activity(conversation_id)

    async def update_context(
        self,
        conversation_id: UUID,
        context: ConversationContext,
    ) -> None:
        """Update conversation context."""
        await self.knowledge.update_conversation_context(
            conversation_id,
            context.model_dump(),
        )

    async def get_embedding(self, text: str) -> list[float]:
        """Get embedding for text."""
        # Use embedding service
        pass
```

---

### 5.2 Context Accumulation

**Goal:** Track and accumulate context across messages.

**Tasks:**
- [ ] Extract entities from messages
- [ ] Track referenced files and repos
- [ ] Build conversation summary
- [ ] Manage context window

**Context Accumulator:**

```python
# jarvis/src/jarvis_conversations/context.py
from uuid import UUID
import re
from .models import Conversation, Message, ConversationContext
from jarvis_knowledge import KnowledgeClient

class ContextAccumulator:
    """Accumulates context from conversation messages."""

    def __init__(self, knowledge: KnowledgeClient):
        self.knowledge = knowledge

    async def process_message(
        self,
        conversation: Conversation,
        message: Message,
    ) -> ConversationContext:
        """Process a message and update context."""
        context = conversation.context

        # Extract repo references
        repo_refs = await self.extract_repo_references(message.content)
        for repo_id in repo_refs:
            if repo_id not in context.referenced_repos:
                context.referenced_repos.append(repo_id)

        # Extract file references
        file_refs = self.extract_file_references(message.content)
        for file_path in file_refs:
            if file_path not in context.referenced_files:
                context.referenced_files.append(file_path)

        # Extract preferences
        prefs = self.extract_preferences(message.content)
        context.user_preferences.update(prefs)

        return context

    async def extract_repo_references(self, content: str) -> list[UUID]:
        """Extract repository references from message."""
        refs = []

        # Pattern: repo name or URL
        patterns = [
            r"(?:repo|repository)\s+['\"]?(\S+)['\"]?",
            r"github\.com/[\w-]+/([\w-]+)",
            r"in\s+([\w-]+)\s+(?:repo|repository)",
        ]

        for pattern in patterns:
            matches = re.findall(pattern, content, re.IGNORECASE)
            for match in matches:
                repo = await self.knowledge.find_repo_by_name(match)
                if repo:
                    refs.append(repo["id"])

        return refs

    def extract_file_references(self, content: str) -> list[str]:
        """Extract file path references."""
        patterns = [
            r"(?:file|in)\s+['\"]?([\w/.-]+\.\w+)['\"]?",
            r"([\w/.-]+\.(?:py|ts|js|rs|go|java|nix|yaml|json|md))",
        ]

        files = []
        for pattern in patterns:
            matches = re.findall(pattern, content)
            files.extend(matches)

        return list(set(files))

    def extract_preferences(self, content: str) -> dict:
        """Extract user preferences from message."""
        prefs = {}

        # Language preference
        lang_match = re.search(r"(?:use|prefer|in)\s+(python|rust|typescript|go)", content, re.I)
        if lang_match:
            prefs["preferred_language"] = lang_match.group(1).lower()

        # Style preferences
        if "detailed" in content.lower():
            prefs["verbosity"] = "detailed"
        elif "brief" in content.lower():
            prefs["verbosity"] = "brief"

        return prefs

    async def build_context_summary(
        self,
        conversation: Conversation,
        token_limit: int = 2000,
    ) -> str:
        """Build a summary of conversation context for prompts."""
        lines = []

        # Recent messages summary
        recent = conversation.messages[-10:]
        if recent:
            lines.append("## Recent Conversation")
            for msg in recent:
                role = "User" if msg.role == "user" else "Assistant"
                lines.append(f"{role}: {msg.content[:200]}...")

        # Referenced context
        if conversation.context.referenced_repos:
            lines.append("\n## Referenced Repositories")
            for repo_id in conversation.context.referenced_repos[:5]:
                repo = await self.knowledge.get_repository(repo_id)
                if repo:
                    lines.append(f"- {repo['name']}: {repo.get('description', 'No description')}")

        if conversation.context.referenced_files:
            lines.append("\n## Referenced Files")
            for file_path in conversation.context.referenced_files[:10]:
                lines.append(f"- {file_path}")

        # User preferences
        if conversation.context.user_preferences:
            lines.append("\n## User Preferences")
            for key, value in conversation.context.user_preferences.items():
                lines.append(f"- {key}: {value}")

        return "\n".join(lines)
```

---

### 5.3 Clarification Handling

**Goal:** Allow agents to ask clarifying questions.

**Tasks:**
- [ ] Detect when clarification needed
- [ ] Generate clarification questions
- [ ] Pause execution for response
- [ ] Resume with clarification

**Clarification Handler:**

```python
# jarvis/src/jarvis_conversations/clarification.py
from dataclasses import dataclass
from uuid import UUID
from enum import Enum
from jarvis_bus import JarvisBus

class ClarificationType(str, Enum):
    AMBIGUOUS_TARGET = "ambiguous_target"
    MISSING_PARAMETER = "missing_parameter"
    CONFIRMATION_NEEDED = "confirmation_needed"
    MULTIPLE_OPTIONS = "multiple_options"

@dataclass
class ClarificationRequest:
    """Request for clarification from user."""
    id: UUID
    conversation_id: UUID
    type: ClarificationType
    question: str
    options: list[str] | None = None
    context: dict | None = None

@dataclass
class ClarificationResponse:
    """User's response to clarification."""
    request_id: UUID
    response: str
    selected_option: int | None = None

class ClarificationHandler:
    """Handles clarification requests and responses."""

    def __init__(self, bus: JarvisBus, store: ConversationStore):
        self.bus = bus
        self.store = store
        self.pending: dict[UUID, ClarificationRequest] = {}

    async def request_clarification(
        self,
        conversation_id: UUID,
        type: ClarificationType,
        question: str,
        options: list[str] | None = None,
    ) -> ClarificationRequest:
        """Send clarification request to user."""
        request = ClarificationRequest(
            id=UUID(),
            conversation_id=conversation_id,
            type=type,
            question=question,
            options=options,
        )

        self.pending[request.id] = request

        # Update conversation state
        conversation = await self.store.get(conversation_id)
        conversation.state = "waiting"
        conversation.context.clarifications_pending.append({
            "id": str(request.id),
            "question": question,
        })
        await self.store.update_context(conversation_id, conversation.context)

        # Publish event for UI
        await self.bus.publish(
            f"jarvis.conversation.{conversation_id}.clarification",
            {
                "request_id": str(request.id),
                "question": question,
                "options": options,
            },
        )

        return request

    async def handle_response(
        self,
        response: ClarificationResponse,
    ) -> dict:
        """Handle user's response to clarification."""
        request = self.pending.get(response.request_id)
        if not request:
            raise ValueError("Unknown clarification request")

        del self.pending[response.request_id]

        # Update conversation
        conversation = await self.store.get(request.conversation_id)
        conversation.state = "active"
        conversation.context.clarifications_pending = [
            c for c in conversation.context.clarifications_pending
            if c["id"] != str(request.id)
        ]

        # Add as message
        await self.store.add_message(
            request.conversation_id,
            Message(role="user", content=response.response),
        )

        return {
            "conversation_id": request.conversation_id,
            "original_question": request.question,
            "response": response.response,
            "context": request.context,
        }

    def detect_need_for_clarification(
        self,
        intent: str,
        context: dict,
    ) -> ClarificationRequest | None:
        """Detect if clarification is needed."""

        # Check for ambiguous repo reference
        if "repo" not in intent.lower() and not context.get("referenced_repos"):
            return ClarificationRequest(
                id=UUID(),
                conversation_id=context.get("conversation_id"),
                type=ClarificationType.AMBIGUOUS_TARGET,
                question="Which repository should I work on?",
                options=None,  # Will be populated with enabled repos
            )

        # Check for dangerous operation
        dangerous_patterns = ["delete", "remove all", "drop", "truncate"]
        if any(p in intent.lower() for p in dangerous_patterns):
            return ClarificationRequest(
                id=UUID(),
                conversation_id=context.get("conversation_id"),
                type=ClarificationType.CONFIRMATION_NEEDED,
                question=f"This looks like a destructive operation. Are you sure you want to: {intent}?",
                options=["Yes, proceed", "No, cancel"],
            )

        return None
```

---

### 5.4 Voice Interface Integration

**Goal:** Connect to Home Assistant for voice input.

**Tasks:**
- [ ] Create Home Assistant integration
- [ ] Handle voice transcription
- [ ] Send responses via TTS
- [ ] Support conversation flow

**Home Assistant Integration:**

```python
# jarvis/src/jarvis_conversations/voice.py
import aiohttp
from uuid import UUID
from jarvis_bus import JarvisBus
from jarvis_events import IntentReceived, IntentSource

class HomeAssistantVoice:
    """Integration with Home Assistant voice pipeline."""

    def __init__(
        self,
        bus: JarvisBus,
        ha_url: str,
        ha_token: str,
    ):
        self.bus = bus
        self.ha_url = ha_url
        self.ha_token = ha_token
        self.active_conversations: dict[str, UUID] = {}

    async def handle_voice_input(
        self,
        user_id: str,
        transcript: str,
    ) -> None:
        """Handle transcribed voice input."""

        # Get or create conversation
        conversation_id = self.active_conversations.get(user_id)

        # Publish intent
        await self.bus.publish(
            "jarvis.intent.received",
            IntentReceived(
                raw_input=transcript,
                source=IntentSource.VOICE,
                user_id=user_id,
                conversation_id=conversation_id,
            ),
        )

    async def send_voice_response(
        self,
        user_id: str,
        message: str,
    ) -> None:
        """Send response via TTS."""
        async with aiohttp.ClientSession() as session:
            await session.post(
                f"{self.ha_url}/api/services/tts/speak",
                headers={"Authorization": f"Bearer {self.ha_token}"},
                json={
                    "entity_id": f"media_player.{user_id}_speaker",
                    "message": message,
                },
            )

    async def run(self):
        """Listen for conversation completions and send voice responses."""
        async for event in self.bus.subscribe(
            stream="INTENTS",
            consumer="voice-responder",
            filter_subject="jarvis.intent.*.completed",
        ):
            if event.payload.get("source") == "voice":
                user_id = event.payload.get("user_id")
                message = self.format_response(event.payload)
                await self.send_voice_response(user_id, message)

    def format_response(self, result: dict) -> str:
        """Format result for voice output."""
        if result.get("success"):
            pr_url = result.get("pr_url", "")
            return f"Done! I've created a pull request. {pr_url}"
        else:
            error = result.get("error", "Unknown error")
            return f"Sorry, I couldn't complete that. {error}"
```

---

### 5.5 Conversation API Endpoints

**Goal:** Add conversation endpoints to API.

**Tasks:**
- [ ] Create conversation CRUD endpoints
- [ ] Add message endpoints
- [ ] Handle clarification responses
- [ ] Support conversation listing

**Conversation Routes:**

```python
# jarvis/src/jarvis_api/routes/conversations.py
from uuid import UUID
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel

from ..auth import verify_api_key
from jarvis_conversations import ConversationStore, Message

router = APIRouter()

class CreateConversationRequest(BaseModel):
    initial_message: str | None = None

class SendMessageRequest(BaseModel):
    content: str

class ClarificationResponseRequest(BaseModel):
    request_id: UUID
    response: str
    selected_option: int | None = None

@router.post("/conversations")
async def create_conversation(
    request: CreateConversationRequest,
    user_id: str = Depends(verify_api_key),
    store: ConversationStore = Depends(),
):
    """Create a new conversation."""
    conversation = await store.create(user_id=user_id)

    if request.initial_message:
        await store.add_message(
            conversation.id,
            Message(role="user", content=request.initial_message),
        )

    return {"conversation_id": conversation.id}

@router.get("/conversations/{conversation_id}")
async def get_conversation(
    conversation_id: UUID,
    user_id: str = Depends(verify_api_key),
    store: ConversationStore = Depends(),
):
    """Get conversation details."""
    conversation = await store.get(conversation_id)
    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    return conversation.model_dump()

@router.post("/conversations/{conversation_id}/messages")
async def send_message(
    conversation_id: UUID,
    request: SendMessageRequest,
    user_id: str = Depends(verify_api_key),
    store: ConversationStore = Depends(),
):
    """Send a message in conversation."""
    conversation = await store.get(conversation_id)
    if not conversation:
        raise HTTPException(status_code=404, detail="Conversation not found")

    message = Message(role="user", content=request.content)
    await store.add_message(conversation_id, message)

    # Trigger intent processing
    # ...

    return {"message_id": message.id}

@router.post("/conversations/{conversation_id}/clarify")
async def respond_to_clarification(
    conversation_id: UUID,
    request: ClarificationResponseRequest,
    user_id: str = Depends(verify_api_key),
):
    """Respond to a clarification request."""
    # Handle clarification response
    # ...
    return {"status": "received"}
```

---

## Definition of Done

- [ ] Multi-turn conversations work
- [ ] Context preserved between messages
- [ ] Agent can ask clarifying questions
- [ ] User can respond to clarifications
- [ ] Voice commands work via Home Assistant
- [ ] Conversation history queryable

---

## Verification Steps

```bash
# 1. Create conversation
CONV_ID=$(curl -X POST https://jarvis.homelab.local/api/v1/conversations \
  -H "X-API-Key: $API_KEY" \
  -d '{"initial_message": "I want to update the auth module"}' \
  | jq -r '.conversation_id')

# 2. Send follow-up
curl -X POST "https://jarvis.homelab.local/api/v1/conversations/$CONV_ID/messages" \
  -H "X-API-Key: $API_KEY" \
  -d '{"content": "specifically the login function"}'

# 3. Check conversation
curl "https://jarvis.homelab.local/api/v1/conversations/$CONV_ID"
# Expected: Both messages and accumulated context

# 4. Test clarification
# Send ambiguous request, wait for clarification
# Respond to clarification
# Verify execution continues

# 5. Test voice (requires Home Assistant)
# Say: "Hey Jarvis, update the readme"
# Verify response via TTS
```

---

## Next Steps

After this iteration:
- [Iteration 6: Learning](iteration-6-learning.md) - Feedback loops and improvement

