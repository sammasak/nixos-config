# Jarvis Iteration 3: Single Agent

> **Goal:** CodeAgent with ReAct pattern that can make simple code changes.
>
> **Status:** ⬜ Not Started

---

## Overview

This iteration implements the first intelligent agent - the CodeAgent. It uses the ReAct (Reason + Act) pattern to understand code, make changes, and create pull requests.

---

## Prerequisites

- [Iteration 0: Event Bus](iteration-0-event-bus.md) complete
- [Iteration 1: API Gateway](iteration-1-api-gateway.md) complete
- [Iteration 2: Knowledge Graph](iteration-2-knowledge.md) complete

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      CodeAgent                              │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   ReAct Loop                         │   │
│  │                                                      │   │
│  │   ┌─────────┐    ┌─────────┐    ┌─────────────┐    │   │
│  │   │  THINK  │───▶│   ACT   │───▶│  OBSERVE    │    │   │
│  │   │         │    │         │    │             │    │   │
│  │   │ LLM     │    │ Tool    │    │ Result      │    │   │
│  │   │ Reason  │    │ Execute │    │ Process     │    │   │
│  │   └─────────┘    └─────────┘    └──────┬──────┘    │   │
│  │        ▲                               │            │   │
│  │        └───────────────────────────────┘            │   │
│  │                    (repeat)                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                     Tools                            │   │
│  │  • search_code  • read_file  • edit_file            │   │
│  │  • list_directory  • create_pr  • run_tests         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Work Units

### 3.1 Agent Framework

**Goal:** Create base agent framework with ReAct loop.

**Tasks:**
- [ ] Define Agent base class
- [ ] Implement ReAct loop
- [ ] Add event publishing
- [ ] Create tool registry

**Base Agent:**

```python
# jarvis/src/jarvis_agents/base.py
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID
import asyncio

from jarvis_bus import JarvisBus
from jarvis_events import AgentThinking, AgentAction
from .tools import ToolRegistry, Tool
from .llm import LLMClient
from .guardrails import Guardrails

@dataclass
class Thought:
    """Agent's reasoning at each step."""
    reasoning: str
    is_complete: bool
    next_action: "Action | None" = None
    confidence: float = 1.0

@dataclass
class Action:
    """Tool invocation."""
    tool: str
    parameters: dict[str, Any]
    rationale: str

@dataclass
class Observation:
    """Result of tool execution."""
    tool: str
    success: bool
    result: Any
    error: str | None = None

@dataclass
class AgentState:
    """Current agent execution state."""
    task_id: UUID
    observations: list[Observation] = field(default_factory=list)
    files_read: dict[str, str] = field(default_factory=dict)
    files_changed: list[str] = field(default_factory=list)
    step: int = 0

class Agent(ABC):
    """Base class for all agents."""

    def __init__(
        self,
        bus: JarvisBus,
        llm: LLMClient,
        tools: ToolRegistry,
        guardrails: Guardrails,
    ):
        self.bus = bus
        self.llm = llm
        self.tools = tools
        self.guardrails = guardrails
        self.agent_id = UUID()
        self.max_steps = 50

    @abstractmethod
    async def gather_context(self, task: dict) -> dict:
        """Gather context for the task."""
        pass

    @abstractmethod
    def get_system_prompt(self, context: dict) -> str:
        """Get system prompt for this agent type."""
        pass

    async def run(self, task: dict) -> dict:
        """Execute task using ReAct loop."""
        state = AgentState(task_id=task["id"])
        context = await self.gather_context(task)

        for step in range(self.max_steps):
            state.step = step

            # 1. THINK
            thought = await self.think(task, context, state)
            await self.publish_thinking(state.task_id, thought)

            # 2. Check completion
            if thought.is_complete:
                return self.finalize(task, state)

            # 3. Check guardrails
            if not thought.next_action:
                continue

            guardrail_result = self.guardrails.check_action(thought.next_action, state)
            if not guardrail_result.allowed:
                return self.abort(task, f"Guardrail: {guardrail_result.reason}")

            # 4. ACT
            await self.publish_action(state.task_id, thought.next_action)
            observation = await self.execute(thought.next_action, state)
            state.observations.append(observation)

            # 5. OBSERVE
            await self.publish_observation(state.task_id, observation)

        return self.abort(task, "Max steps exceeded")

    async def think(self, task: dict, context: dict, state: AgentState) -> Thought:
        """Use LLM to reason about next action."""
        system_prompt = self.get_system_prompt(context)
        messages = self.build_messages(task, state)

        response = await self.llm.think(
            system_prompt=system_prompt,
            messages=messages,
            tools=self.tools.get_tools_for_agent(self.__class__.__name__),
        )

        return self.parse_thought(response)

    async def execute(self, action: Action, state: AgentState) -> Observation:
        """Execute a tool action."""
        tool = self.tools.get(action.tool)
        if not tool:
            return Observation(
                tool=action.tool,
                success=False,
                result=None,
                error=f"Unknown tool: {action.tool}",
            )

        try:
            result = await tool.handler(**action.parameters)
            return Observation(tool=action.tool, success=True, result=result)
        except Exception as e:
            return Observation(
                tool=action.tool,
                success=False,
                result=None,
                error=str(e),
            )

    async def publish_thinking(self, task_id: UUID, thought: Thought):
        await self.bus.publish(
            f"jarvis.agent.{self.agent_id}.thinking",
            AgentThinking(
                agent_id=self.agent_id,
                task_id=task_id,
                thought=thought.reasoning,
                step=thought.step if hasattr(thought, 'step') else 0,
            ),
        )

    async def publish_action(self, task_id: UUID, action: Action):
        await self.bus.publish(
            f"jarvis.agent.{self.agent_id}.action",
            AgentAction(
                agent_id=self.agent_id,
                task_id=task_id,
                tool=action.tool,
                parameters=action.parameters,
                rationale=action.rationale,
            ),
        )

    def finalize(self, task: dict, state: AgentState) -> dict:
        return {
            "success": True,
            "changes": state.files_changed,
            "steps": state.step,
        }

    def abort(self, task: dict, reason: str) -> dict:
        return {
            "success": False,
            "error": reason,
        }
```

---

### 3.2 CodeAgent Implementation

**Goal:** Implement CodeAgent for code changes.

**Tasks:**
- [ ] Create CodeAgent class
- [ ] Define code-specific tools
- [ ] Implement context gathering
- [ ] Add PR creation logic

**CodeAgent:**

```python
# jarvis/src/jarvis_agents/code_agent.py
from .base import Agent, AgentState
from jarvis_knowledge import KnowledgeClient

CODE_AGENT_SYSTEM_PROMPT = """
You are an expert software engineer. Your task is to make code changes based on the user's request.

## Guidelines
- Always read code before modifying it
- Preserve existing code style
- Make minimal, focused changes
- Explain your reasoning

## Available Tools
{tools}

## Repository Context
{context}

## Task
{task_description}

## Response Format
Think step by step, then use tools to accomplish the task.

THOUGHT: [Your reasoning]
ACTION: tool_name(param1="value1", param2="value2")

When complete:
THOUGHT: [Summary of changes]
COMPLETE: true
"""

class CodeAgent(Agent):
    """Agent for understanding and modifying code."""

    def __init__(self, knowledge: KnowledgeClient, **kwargs):
        super().__init__(**kwargs)
        self.knowledge = knowledge

    async def gather_context(self, task: dict) -> dict:
        """Gather code context for the task."""
        repo_id = task.get("target_repo_id")
        if not repo_id:
            return {}

        # Get embedding for task description
        embedding = await self.llm.embed(task["description"])

        # Use knowledge graph
        context = await self.knowledge.gather_context(
            task_description=task["description"],
            repo_id=repo_id,
            embedding=embedding,
        )

        return context

    def get_system_prompt(self, context: dict) -> str:
        tools_desc = self.tools.format_for_llm(
            self.tools.get_tools_for_agent("CodeAgent")
        )

        context_str = self.format_context(context)

        return CODE_AGENT_SYSTEM_PROMPT.format(
            tools=tools_desc,
            context=context_str,
            task_description="{task_description}",  # Filled per-task
        )

    def format_context(self, context: dict) -> str:
        """Format context for prompt."""
        lines = []

        if context.get("files"):
            lines.append("## Relevant Files")
            for f in context["files"][:10]:
                lines.append(f"- {f.path}: {f.summary}")

        if context.get("structure"):
            lines.append("\n## Repository Structure")
            lines.append(self.format_tree(context["structure"]))

        return "\n".join(lines)

    def format_tree(self, tree: dict, indent: int = 0) -> str:
        """Format directory tree."""
        lines = []
        for name, value in sorted(tree.items()):
            prefix = "  " * indent
            if isinstance(value, dict):
                lines.append(f"{prefix}{name}/")
                lines.append(self.format_tree(value, indent + 1))
            else:
                lines.append(f"{prefix}{name}")
        return "\n".join(lines)
```

---

### 3.3 Tool Implementations

**Goal:** Create tools for code operations.

**Tasks:**
- [ ] Implement search_code tool
- [ ] Implement read_file tool
- [ ] Implement edit_file tool
- [ ] Implement create_pr tool

**Tool Definitions:**

```python
# jarvis/src/jarvis_agents/tools/code_tools.py
from pathlib import Path
from typing import Any
import aiofiles
from ..base import Tool

class SearchCodeTool(Tool):
    """Semantic code search."""

    name = "search_code"
    description = "Search for code semantically related to a query"
    parameters = {
        "query": {"type": "string", "description": "Search query"},
        "limit": {"type": "integer", "description": "Max results", "default": 10},
    }

    def __init__(self, knowledge: KnowledgeClient, embeddings: EmbeddingClient):
        self.knowledge = knowledge
        self.embeddings = embeddings

    async def handler(self, query: str, limit: int = 10) -> list[dict]:
        embedding = await self.embeddings.embed(query)
        results = await self.knowledge.find_similar_files(embedding, limit=limit)
        return [
            {"path": r.path, "summary": r.summary, "similarity": r.similarity}
            for r in results
        ]

class ReadFileTool(Tool):
    """Read file contents."""

    name = "read_file"
    description = "Read the contents of a file"
    parameters = {
        "path": {"type": "string", "description": "File path relative to repo root"},
        "start_line": {"type": "integer", "description": "Start line (optional)"},
        "end_line": {"type": "integer", "description": "End line (optional)"},
    }

    def __init__(self, repo_path: Path):
        self.repo_path = repo_path

    async def handler(
        self,
        path: str,
        start_line: int | None = None,
        end_line: int | None = None,
    ) -> str:
        full_path = self.repo_path / path

        if not full_path.exists():
            raise FileNotFoundError(f"File not found: {path}")

        if not full_path.is_relative_to(self.repo_path):
            raise ValueError("Path escapes repository")

        async with aiofiles.open(full_path, "r") as f:
            lines = await f.readlines()

        if start_line is not None:
            lines = lines[start_line - 1 : end_line]

        return "".join(lines)

class EditFileTool(Tool):
    """Edit file contents."""

    name = "edit_file"
    description = "Edit a file by replacing content"
    parameters = {
        "path": {"type": "string", "description": "File path"},
        "old_content": {"type": "string", "description": "Content to replace"},
        "new_content": {"type": "string", "description": "Replacement content"},
    }

    def __init__(self, repo_path: Path):
        self.repo_path = repo_path

    async def handler(self, path: str, old_content: str, new_content: str) -> str:
        full_path = self.repo_path / path

        if not full_path.exists():
            raise FileNotFoundError(f"File not found: {path}")

        async with aiofiles.open(full_path, "r") as f:
            content = await f.read()

        if old_content not in content:
            raise ValueError("Old content not found in file")

        new_file_content = content.replace(old_content, new_content, 1)

        async with aiofiles.open(full_path, "w") as f:
            await f.write(new_file_content)

        return f"Successfully edited {path}"

class CreatePRTool(Tool):
    """Create a pull request."""

    name = "create_pr"
    description = "Create a pull request with changes"
    parameters = {
        "title": {"type": "string", "description": "PR title"},
        "body": {"type": "string", "description": "PR description"},
        "branch": {"type": "string", "description": "Branch name"},
    }

    def __init__(self, git_client):
        self.git = git_client

    async def handler(self, title: str, body: str, branch: str) -> dict:
        # Create branch
        await self.git.create_branch(branch)

        # Commit changes
        await self.git.commit_all(f"{title}\n\n{body}")

        # Push
        await self.git.push(branch)

        # Create PR
        pr = await self.git.create_pr(title=title, body=body, head=branch)

        return {"pr_url": pr.url, "pr_number": pr.number}
```

---

### 3.4 LLM Integration

**Goal:** Integrate Claude API for reasoning.

**Tasks:**
- [ ] Create LLM client
- [ ] Implement tool use
- [ ] Add response parsing
- [ ] Handle rate limits

**LLM Client:**

```python
# jarvis/src/jarvis_agents/llm.py
import anthropic
from dataclasses import dataclass
from typing import Any

@dataclass
class LLMResponse:
    content: str
    tool_calls: list[dict]
    stop_reason: str

class LLMClient:
    """Client for Claude API."""

    def __init__(self, api_key: str, model: str = "claude-sonnet-4-20250514"):
        self.client = anthropic.AsyncAnthropic(api_key=api_key)
        self.model = model

    async def think(
        self,
        system_prompt: str,
        messages: list[dict],
        tools: list[dict] | None = None,
    ) -> LLMResponse:
        """Get LLM completion with optional tool use."""

        kwargs = {
            "model": self.model,
            "max_tokens": 4096,
            "system": system_prompt,
            "messages": messages,
        }

        if tools:
            kwargs["tools"] = self.format_tools(tools)

        response = await self.client.messages.create(**kwargs)

        return self.parse_response(response)

    def format_tools(self, tools: list[dict]) -> list[dict]:
        """Format tools for Anthropic API."""
        return [
            {
                "name": tool["name"],
                "description": tool["description"],
                "input_schema": {
                    "type": "object",
                    "properties": tool["parameters"],
                    "required": [
                        k for k, v in tool["parameters"].items()
                        if v.get("required", True)
                    ],
                },
            }
            for tool in tools
        ]

    def parse_response(self, response) -> LLMResponse:
        """Parse Anthropic response."""
        content = ""
        tool_calls = []

        for block in response.content:
            if block.type == "text":
                content += block.text
            elif block.type == "tool_use":
                tool_calls.append({
                    "id": block.id,
                    "name": block.name,
                    "input": block.input,
                })

        return LLMResponse(
            content=content,
            tool_calls=tool_calls,
            stop_reason=response.stop_reason,
        )

    async def embed(self, text: str) -> list[float]:
        """Generate embedding (uses OpenAI for now)."""
        # Claude doesn't have embeddings, use OpenAI
        # Or implement with local model
        pass
```

---

### 3.5 Guardrails

**Goal:** Implement safety guardrails.

**Tasks:**
- [ ] Define guardrail rules
- [ ] Implement action checking
- [ ] Add pattern detection
- [ ] Create abort conditions

**Guardrails:**

```python
# jarvis/src/jarvis_agents/guardrails.py
import re
from dataclasses import dataclass, field
from fnmatch import fnmatch
from .base import Action, AgentState

@dataclass
class GuardrailResult:
    allowed: bool
    reason: str | None = None

@dataclass
class Guardrails:
    """Safety limits for agent execution."""

    # Scope limits
    max_files_changed: int = 10
    max_lines_per_file: int = 500
    max_total_lines: int = 2000

    # Execution limits
    max_steps: int = 50
    max_tool_calls: int = 100

    # Pattern detection
    forbidden_patterns: list[str] = field(default_factory=lambda: [
        r"password\s*=\s*['\"][^'\"]+['\"]",  # Hardcoded passwords
        r"api[_-]?key\s*=\s*['\"][^'\"]+['\"]",  # Hardcoded API keys
        r"secret\s*=\s*['\"][^'\"]+['\"]",  # Hardcoded secrets
        r"eval\s*\(",  # Dangerous eval
        r"exec\s*\(",  # Dangerous exec
        r"__import__\s*\(",  # Dynamic import
    ])

    # Sensitive paths
    sensitive_paths: list[str] = field(default_factory=lambda: [
        "*.env",
        "*.pem",
        "*.key",
        "*credentials*",
        "*secret*",
        ".git/*",
    ])

    def check_action(self, action: Action, state: AgentState) -> GuardrailResult:
        """Check if action is allowed."""

        # Check file limits
        if action.tool in ["edit_file", "create_file"]:
            if len(state.files_changed) >= self.max_files_changed:
                return GuardrailResult(
                    allowed=False,
                    reason=f"Max files limit ({self.max_files_changed}) reached",
                )

            # Check sensitive paths
            path = action.parameters.get("path", "")
            for pattern in self.sensitive_paths:
                if fnmatch(path, pattern):
                    return GuardrailResult(
                        allowed=False,
                        reason=f"Sensitive path: {path}",
                    )

            # Check content patterns
            content = action.parameters.get("new_content", "")
            for pattern in self.forbidden_patterns:
                if re.search(pattern, content, re.IGNORECASE):
                    return GuardrailResult(
                        allowed=False,
                        reason=f"Forbidden pattern detected",
                    )

        # Check step limits
        if state.step >= self.max_steps:
            return GuardrailResult(
                allowed=False,
                reason="Max steps exceeded",
            )

        return GuardrailResult(allowed=True)
```

---

### 3.6 Agent Worker

**Goal:** Create worker that processes tasks from event bus.

**Tasks:**
- [ ] Subscribe to task events
- [ ] Dispatch to appropriate agent
- [ ] Publish completion events
- [ ] Handle errors gracefully

**Worker:**

```python
# jarvis/src/jarvis_agents/worker.py
import asyncio
from uuid import UUID

from jarvis_bus import JarvisBus
from jarvis_events import TaskCreated, TaskCompleted
from jarvis_knowledge import KnowledgeClient
from .code_agent import CodeAgent
from .llm import LLMClient
from .tools import ToolRegistry
from .guardrails import Guardrails

class AgentWorker:
    """Worker that processes tasks from the event bus."""

    def __init__(
        self,
        bus: JarvisBus,
        knowledge: KnowledgeClient,
        llm: LLMClient,
    ):
        self.bus = bus
        self.knowledge = knowledge
        self.llm = llm
        self.tools = ToolRegistry()
        self.guardrails = Guardrails()

        # Register agents
        self.agents = {
            "code_change": CodeAgent(
                bus=bus,
                llm=llm,
                tools=self.tools,
                guardrails=self.guardrails,
                knowledge=knowledge,
            ),
        }

    async def run(self):
        """Main worker loop."""
        print("Agent worker starting...")

        async for event in self.bus.subscribe(
            stream="TASKS",
            consumer="agent-worker",
            filter_subject="jarvis.task.created",
            payload_type=TaskCreated,
        ):
            asyncio.create_task(self.process_task(event.payload))

    async def process_task(self, task: TaskCreated):
        """Process a single task."""
        print(f"Processing task: {task.task_id}")

        try:
            # Get agent for task type
            agent = self.agents.get(task.task_type)
            if not agent:
                raise ValueError(f"Unknown task type: {task.task_type}")

            # Update status
            await self.knowledge.update_task_status(task.task_id, "running")

            # Run agent
            result = await agent.run({
                "id": task.task_id,
                "description": task.description,
                "target_repo_id": task.target_repo_id,
            })

            # Publish completion
            await self.bus.publish(
                f"jarvis.task.{task.task_id}.completed",
                TaskCompleted(
                    task_id=task.task_id,
                    success=result["success"],
                    result=result,
                    pr_url=result.get("pr_url"),
                    duration_ms=0,  # Calculate actual duration
                ),
            )

            # Update knowledge
            await self.knowledge.update_task_status(
                task.task_id,
                "completed" if result["success"] else "failed",
                result=result,
                error=result.get("error"),
                pr_url=result.get("pr_url"),
            )

        except Exception as e:
            print(f"Task failed: {e}")
            await self.knowledge.update_task_status(
                task.task_id,
                "failed",
                error=str(e),
            )

# Entry point
async def main():
    bus = await JarvisBus.connect("nats://nats:4222", "agent-worker")
    knowledge = await KnowledgeClient.create("postgresql://...")
    llm = LLMClient(api_key="...")

    worker = AgentWorker(bus, knowledge, llm)
    await worker.run()

if __name__ == "__main__":
    asyncio.run(main())
```

---

## Definition of Done

- [ ] CodeAgent receives tasks from event bus
- [ ] ReAct loop executes with Claude
- [ ] Tools work (search, read, edit)
- [ ] Simple code changes succeed (e.g., "add a comment")
- [ ] Guardrails prevent dangerous changes
- [ ] Agent events published for observability

---

## Verification Steps

```bash
# 1. Check agent worker
kubectl get pods -n jarvis -l app=jarvis-agent-worker
# Expected: Pod running

# 2. Submit test task
curl -X POST https://jarvis.homelab.local/api/v1/intents \
  -H "X-API-Key: $API_KEY" \
  -d '{"input": "add a comment to the main function in src/main.py"}'

# 3. Watch events
kubectl exec -it nats-0 -n jarvis -- nats sub "jarvis.agent.>"
# Expected: Thinking and action events

# 4. Check task completion
curl https://jarvis.homelab.local/api/v1/tasks/{task_id}
# Expected: Status completed, PR URL present

# 5. Verify PR
# Check GitHub for created PR
```

---

## Next Steps

After this iteration:
- [Iteration 4: Multi-Agent](iteration-4-multi-agent.md) - Add Planner, TestAgent, ReviewAgent
- [Iteration 5: Conversations](iteration-5-conversations.md) - Stateful sessions

