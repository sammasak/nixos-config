# Jarvis Core - Agents

> **Purpose:** Define agent patterns, types, and implementation for Jarvis's intelligent task execution.

---

## Overview

Agents are the intelligent workers in Jarvis. They receive tasks via the event bus, reason about how to accomplish them, take actions using tools, and report results.

**Core Pattern:** ReAct (Reason + Act) - agents alternate between thinking and acting until a task is complete.

---

## Agent Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         AGENT POOL                              │
│                                                                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐             │
│  │   Planner   │  │  CodeAgent  │  │  TestAgent  │             │
│  │             │  │             │  │             │             │
│  │ Decomposes  │  │ Understands │  │ Runs tests  │             │
│  │ intents     │  │ and edits   │  │ and fixes   │             │
│  │ into tasks  │  │ code        │  │ failures    │             │
│  └─────────────┘  └─────────────┘  └─────────────┘             │
│         │                │                │                     │
│         └────────────────┼────────────────┘                     │
│                          │                                      │
│                    ┌─────┴─────┐                                │
│                    │  Review   │                                │
│                    │  Agent    │                                │
│                    │           │                                │
│                    │ Checks    │                                │
│                    │ quality   │                                │
│                    └───────────┘                                │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                    Shared Components                      │  │
│  │  • Tool Registry  • LLM Client  • Event Publisher        │  │
│  │  • Context Manager  • Guardrails  • Memory               │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

---

## The ReAct Pattern

### Core Loop

```python
class Agent:
    async def run(self, task: Task) -> TaskResult:
        """Execute task using ReAct loop."""
        context = await self.gather_context(task)
        observations = []

        for step in range(self.max_steps):
            # 1. REASON - Think about what to do
            thought = await self.think(task, context, observations)
            await self.publish_thinking(task.id, thought)

            # 2. Check if done
            if thought.is_complete:
                return self.finalize(task, observations)

            # 3. ACT - Execute chosen action
            action = thought.next_action
            await self.publish_action(task.id, action)

            # 4. OBSERVE - Get result
            observation = await self.execute(action)
            observations.append(observation)
            await self.publish_observation(task.id, observation)

            # 5. Check guardrails
            if self.guardrails.should_stop(observations):
                return self.abort(task, "Guardrail triggered")

        return self.abort(task, "Max steps exceeded")
```

### Thought Structure

```python
@dataclass
class Thought:
    """Agent's reasoning at each step."""
    reasoning: str           # Chain of thought
    is_complete: bool        # Task finished?
    next_action: Action | None  # What to do next
    confidence: float        # 0.0 - 1.0

@dataclass
class Action:
    """Tool invocation."""
    tool: str               # Tool name
    parameters: dict        # Tool arguments
    rationale: str          # Why this action
```

### Example ReAct Trace

```
Task: "Add input validation to the login function"

Step 1:
  THOUGHT: I need to understand the current login function. Let me search for it.
  ACTION: search_code(query="login function", repo="auth-service")
  OBSERVATION: Found login() in src/auth/handlers.py:45-67

Step 2:
  THOUGHT: I found the function. It takes username and password but has no validation.
           I should add validation for empty strings and email format.
  ACTION: read_file(path="src/auth/handlers.py", lines=(45, 67))
  OBSERVATION: [file content]

Step 3:
  THOUGHT: Now I understand the code. I'll add validation at the start of the function.
  ACTION: edit_file(
    path="src/auth/handlers.py",
    changes=[{start: 46, end: 46, content: "    if not username or not password:\n        raise ValidationError('...')"}]
  )
  OBSERVATION: File edited successfully

Step 4:
  THOUGHT: Validation added. Task complete.
  COMPLETE: true
```

---

## Agent Types

### Planner Agent

**Role:** Decompose high-level intents into concrete tasks.

```python
class PlannerAgent(Agent):
    """Breaks down intents into executable tasks."""

    tools = [
        "search_code",      # Find relevant code
        "read_file",        # Understand context
        "query_knowledge",  # Check history/patterns
        "create_tasks",     # Output subtasks
    ]

    async def plan(self, intent: Intent) -> list[Task]:
        """Create execution plan from intent."""

        # 1. Understand the request
        context = await self.gather_context(intent)

        # 2. Search for relevant code/history
        relevant_files = await self.search_similar(intent.description)
        past_tasks = await self.find_similar_tasks(intent.description)

        # 3. Generate plan via LLM
        plan = await self.llm.plan(
            intent=intent,
            context=context,
            similar_files=relevant_files,
            past_tasks=past_tasks,
        )

        # 4. Validate plan
        self.validate_plan(plan)

        # 5. Create tasks
        return [
            Task(
                description=step.description,
                task_type=step.type,
                dependencies=step.depends_on,
                estimated_complexity=step.complexity,
            )
            for step in plan.steps
        ]
```

**Output Events:**
- `jarvis.task.created` - For each generated task
- `jarvis.agent.{id}.thinking` - Planning reasoning

---

### Code Agent

**Role:** Understand, analyze, and modify code.

```python
class CodeAgent(Agent):
    """Performs code understanding and modification."""

    tools = [
        # Read operations
        "search_code",       # Semantic code search
        "read_file",         # Read file content
        "list_directory",    # Explore structure
        "get_symbol",        # Get function/class details
        "find_references",   # Find usages

        # Write operations
        "edit_file",         # Modify existing file
        "create_file",       # Create new file
        "delete_file",       # Remove file

        # Analysis
        "explain_code",      # Get LLM explanation
        "suggest_changes",   # Get modification ideas
    ]

    guardrails = CodeGuardrails(
        max_files_changed=10,
        max_lines_per_file=500,
        forbidden_patterns=[
            r"password\s*=",      # Hardcoded credentials
            r"api[_-]?key\s*=",   # Exposed API keys
            r"eval\(",            # Dangerous eval
        ],
    )
```

**Key Behaviors:**
- Always reads code before modifying
- Preserves existing style and patterns
- Explains changes in commit messages
- Respects `.jarvis.yaml` constraints

---

### Test Agent

**Role:** Run tests, analyze failures, suggest fixes.

```python
class TestAgent(Agent):
    """Executes tests and handles failures."""

    tools = [
        "run_tests",          # Execute test suite
        "run_single_test",    # Run specific test
        "analyze_failure",    # Parse test output
        "get_coverage",       # Check coverage
        "suggest_fix",        # Generate fix for failure
    ]

    async def test_changes(
        self,
        task: Task,
        changes: list[FileChange]
    ) -> TestResult:
        """Test changes and attempt fixes if needed."""

        for attempt in range(self.max_attempts):
            # Run tests
            result = await self.run_tests(task.repo_id)

            if result.passed:
                return TestResult(success=True, attempts=attempt + 1)

            # Analyze failures
            failures = await self.analyze_failures(result)

            # Try to fix
            fixes = await self.generate_fixes(failures, changes)

            if not fixes:
                return TestResult(
                    success=False,
                    failures=failures,
                    message="Could not generate fixes"
                )

            # Apply fixes
            await self.apply_fixes(fixes)
            changes.extend(fixes)

        return TestResult(
            success=False,
            attempts=self.max_attempts,
            message="Max fix attempts exceeded"
        )
```

---

### Review Agent

**Role:** Check code quality, security, and style.

```python
class ReviewAgent(Agent):
    """Reviews code changes for quality and security."""

    tools = [
        "diff_changes",       # Get change diff
        "check_style",        # Lint/format check
        "security_scan",      # Security analysis
        "complexity_check",   # Cyclomatic complexity
        "suggest_improvement", # Quality suggestions
    ]

    async def review(
        self,
        changes: list[FileChange],
        repo_config: JarvisConfig
    ) -> ReviewResult:
        """Review changes before PR creation."""

        issues = []

        # 1. Security scan
        security_issues = await self.security_scan(changes)
        issues.extend(security_issues)

        # 2. Style check
        if repo_config.enforce_style:
            style_issues = await self.check_style(changes)
            issues.extend(style_issues)

        # 3. Complexity check
        complexity_issues = await self.complexity_check(changes)
        issues.extend(complexity_issues)

        # 4. LLM review for subtle issues
        llm_issues = await self.llm_review(changes)
        issues.extend(llm_issues)

        # Categorize
        blocking = [i for i in issues if i.severity == "error"]
        warnings = [i for i in issues if i.severity == "warning"]

        return ReviewResult(
            approved=len(blocking) == 0,
            blocking_issues=blocking,
            warnings=warnings,
        )
```

---

## Tool System

### Tool Definition

```python
@dataclass
class Tool:
    """Definition of an agent tool."""
    name: str
    description: str
    parameters: dict[str, ParameterDef]
    handler: Callable
    requires_confirmation: bool = False

@dataclass
class ParameterDef:
    type: str
    description: str
    required: bool = True
    default: Any = None
```

### Tool Registry

```python
class ToolRegistry:
    """Central registry of available tools."""

    def __init__(self):
        self.tools: dict[str, Tool] = {}

    def register(self, tool: Tool) -> None:
        self.tools[tool.name] = tool

    def get_tools_for_agent(
        self,
        agent_type: str
    ) -> list[Tool]:
        """Get tools available to an agent type."""
        return [
            t for t in self.tools.values()
            if agent_type in t.allowed_agents
        ]

    def format_for_llm(self, tools: list[Tool]) -> str:
        """Format tool descriptions for LLM prompt."""
        return "\n".join(
            f"- {t.name}: {t.description}\n"
            f"  Parameters: {t.parameters}"
            for t in tools
        )
```

### Common Tools

| Tool | Description | Agents |
|------|-------------|--------|
| `search_code` | Semantic search in codebase | All |
| `read_file` | Read file contents | All |
| `edit_file` | Modify file | CodeAgent |
| `create_file` | Create new file | CodeAgent |
| `run_tests` | Execute test suite | TestAgent |
| `security_scan` | Check for vulnerabilities | ReviewAgent |
| `submit_workflow` | Send job to Argo | All |
| `create_pr` | Open pull request | CodeAgent |
| `query_knowledge` | Search knowledge graph | All |

---

## Multi-Agent Orchestration

### Task Flow

```
Intent Received
       │
       ▼
┌─────────────┐
│   Planner   │  ──→  Creates subtasks
└─────────────┘
       │
       ▼
┌─────────────┐
│  CodeAgent  │  ──→  Implements changes (parallel if independent)
└─────────────┘
       │
       ▼
┌─────────────┐
│  TestAgent  │  ──→  Runs tests, fixes failures
└─────────────┘
       │
       ▼
┌─────────────┐
│   Review    │  ──→  Quality check
└─────────────┘
       │
       ▼
    PR Created
```

### Orchestrator

```python
class AgentOrchestrator:
    """Coordinates multi-agent task execution."""

    async def execute_intent(self, intent: Intent) -> IntentResult:
        """Full intent execution pipeline."""

        # 1. Planning phase
        tasks = await self.planner.plan(intent)
        await self.publish_plan(intent.id, tasks)

        # 2. Group tasks by dependencies
        task_groups = self.group_by_dependencies(tasks)

        # 3. Execute groups in order
        all_changes = []
        for group in task_groups:
            # Execute independent tasks in parallel
            results = await asyncio.gather(*[
                self.code_agent.execute(task)
                for task in group
            ])

            for result in results:
                if not result.success:
                    return IntentResult(
                        success=False,
                        error=f"Task failed: {result.error}"
                    )
                all_changes.extend(result.changes)

        # 4. Test phase
        test_result = await self.test_agent.test_changes(
            intent, all_changes
        )
        if not test_result.success:
            return IntentResult(
                success=False,
                error="Tests failed",
                test_result=test_result
            )

        # 5. Review phase
        review_result = await self.review_agent.review(
            all_changes, intent.repo_config
        )
        if not review_result.approved:
            return IntentResult(
                success=False,
                error="Review failed",
                review_result=review_result
            )

        # 6. Create PR
        pr = await self.create_pr(intent, all_changes)

        return IntentResult(success=True, pr_url=pr.url)
```

---

## Guardrails

### Types of Guardrails

```python
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
    max_llm_tokens: int = 100000

    # Time limits
    max_duration_seconds: int = 600

    # Pattern detection
    forbidden_patterns: list[str] = field(default_factory=list)
    sensitive_paths: list[str] = field(default_factory=list)
```

### Guardrail Enforcement

```python
class GuardrailEnforcer:
    """Enforces guardrails during agent execution."""

    def check_action(
        self,
        action: Action,
        state: AgentState
    ) -> GuardrailResult:
        """Check if action is allowed."""

        # Check file limits
        if action.tool == "edit_file":
            if len(state.files_changed) >= self.guardrails.max_files_changed:
                return GuardrailResult(
                    allowed=False,
                    reason="Max files changed limit reached"
                )

        # Check patterns
        if action.tool in ["edit_file", "create_file"]:
            content = action.parameters.get("content", "")
            for pattern in self.guardrails.forbidden_patterns:
                if re.search(pattern, content):
                    return GuardrailResult(
                        allowed=False,
                        reason=f"Forbidden pattern detected: {pattern}"
                    )

        # Check sensitive paths
        path = action.parameters.get("path", "")
        for sensitive in self.guardrails.sensitive_paths:
            if fnmatch(path, sensitive):
                return GuardrailResult(
                    allowed=False,
                    reason=f"Sensitive path: {path}"
                )

        return GuardrailResult(allowed=True)
```

---

## LLM Integration

### Prompt Templates

```python
REACT_SYSTEM_PROMPT = """
You are an expert software engineer assistant. You accomplish tasks by:
1. THINKING carefully about what to do
2. Using TOOLS to take actions
3. OBSERVING the results
4. Repeating until the task is complete

Available tools:
{tools}

Current task: {task_description}

Repository context:
{context}

Respond in this format:
THOUGHT: [Your reasoning about what to do next]
ACTION: [tool_name]({parameters})

Or if complete:
THOUGHT: [Summary of what was done]
COMPLETE: true
"""

CODE_GENERATION_PROMPT = """
Generate code changes for the following task:

Task: {task_description}

Current file content:
```{language}
{file_content}
```

Requirements:
- Preserve existing code style
- Add appropriate comments
- Handle edge cases
- Follow {language} best practices

Generate the modified code:
"""
```

### LLM Client

```python
class LLMClient:
    """Interface to Claude API."""

    async def think(
        self,
        system_prompt: str,
        messages: list[Message],
        tools: list[Tool] | None = None,
    ) -> LLMResponse:
        """Get LLM completion with tool use."""

        response = await self.client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=4096,
            system=system_prompt,
            messages=messages,
            tools=self.format_tools(tools) if tools else None,
        )

        return self.parse_response(response)
```

---

## Memory and Context

### Short-term Memory (Task-scoped)

```python
@dataclass
class TaskMemory:
    """Memory for current task execution."""

    observations: list[Observation]
    files_read: dict[str, str]
    files_changed: list[str]
    tool_calls: list[ToolCall]

    def get_relevant_observations(
        self,
        query: str,
        limit: int = 10
    ) -> list[Observation]:
        """Get observations relevant to query."""
        # Use embedding similarity
        pass
```

### Long-term Memory (Knowledge Graph)

```python
class LongTermMemory:
    """Interface to knowledge graph for agent memory."""

    async def remember_task(
        self,
        task: Task,
        result: TaskResult
    ) -> None:
        """Store task outcome for future reference."""
        await self.db.store_task(task, result)

    async def recall_similar(
        self,
        description: str,
        repo_id: UUID | None = None,
        limit: int = 5
    ) -> list[TaskMemory]:
        """Recall similar past tasks."""
        embedding = await self.embed(description)
        return await self.db.find_similar_tasks(
            embedding, repo_id, limit
        )
```

---

## Event Integration

### Events Published by Agents

```python
# Agent starts working
await publish("jarvis.agent.{id}.started", {
    "agent_type": "code",
    "task_id": task.id,
})

# Agent thinking (observability)
await publish("jarvis.agent.{id}.thinking", {
    "thought": thought.reasoning,
    "confidence": thought.confidence,
})

# Agent takes action
await publish("jarvis.agent.{id}.action", {
    "tool": action.tool,
    "parameters": action.parameters,
    "rationale": action.rationale,
})

# Agent observes result
await publish("jarvis.agent.{id}.observation", {
    "tool": action.tool,
    "result": observation.result,
    "success": observation.success,
})

# Agent completes
await publish("jarvis.agent.{id}.completed", {
    "task_id": task.id,
    "success": True,
    "changes": changes,
})
```

---

## Configuration

### Agent Configuration

```yaml
# jarvis-config.yaml
agents:
  planner:
    model: claude-sonnet-4-20250514
    max_steps: 20

  code:
    model: claude-sonnet-4-20250514
    max_steps: 50
    guardrails:
      max_files_changed: 10
      max_lines_per_file: 500

  test:
    model: claude-haiku-4-20250514  # Faster for test analysis
    max_attempts: 3

  review:
    model: claude-sonnet-4-20250514
    security_scan: true
    style_check: true
```

---

## Related Documentation

- [Overview](overview.md) - System architecture
- [Events](events.md) - Event schemas
- [Knowledge Graph](knowledge-graph.md) - Context and memory storage
- [Iterations](iterations.md) - Implementation roadmap

