# Jarvis Iteration 4: Multi-Agent

> **Goal:** Full agent suite with orchestration for complex tasks.
>
> **Status:** ⬜ Not Started

---

## Overview

This iteration adds the complete agent suite: Planner for task decomposition, TestAgent for test execution, ReviewAgent for quality checks, and an Orchestrator to coordinate them.

---

## Prerequisites

- [Iteration 3: Single Agent](iteration-3-single-agent.md) complete
- CodeAgent working end-to-end

---

## Architecture

```
                         Intent
                            │
                            ▼
                    ┌───────────────┐
                    │    Planner    │
                    │               │
                    │ Decomposes    │
                    │ into tasks    │
                    └───────┬───────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  Orchestrator │
                    │               │
                    │ Coordinates   │
                    │ execution     │
                    └───────┬───────┘
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
    ┌───────────┐   ┌───────────┐   ┌───────────┐
    │ CodeAgent │   │ CodeAgent │   │ CodeAgent │
    │  Task 1   │   │  Task 2   │   │  Task 3   │
    └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
          │               │               │
          └───────────────┼───────────────┘
                          │
                          ▼
                  ┌───────────────┐
                  │   TestAgent   │
                  │               │
                  │ Run tests     │
                  │ Fix failures  │
                  └───────┬───────┘
                          │
                          ▼
                  ┌───────────────┐
                  │ ReviewAgent   │
                  │               │
                  │ Quality check │
                  │ Security scan │
                  └───────┬───────┘
                          │
                          ▼
                       PR Created
```

---

## Work Units

### 4.1 Planner Agent

**Goal:** Decompose intents into executable tasks.

**Tasks:**
- [ ] Create PlannerAgent class
- [ ] Implement planning prompts
- [ ] Add task dependency detection
- [ ] Store plans in knowledge graph

**Planner Implementation:**

```python
# jarvis/src/jarvis_agents/planner.py
from dataclasses import dataclass
from uuid import UUID, uuid4
from .base import Agent

@dataclass
class PlanStep:
    """A step in the execution plan."""
    description: str
    task_type: str
    dependencies: list[int]  # Indices of dependent steps
    estimated_complexity: str  # low, medium, high

@dataclass
class ExecutionPlan:
    """Plan for executing an intent."""
    intent_id: UUID
    steps: list[PlanStep]
    summary: str

PLANNER_SYSTEM_PROMPT = """
You are a software engineering planner. Your job is to break down user requests into concrete, executable tasks.

## Guidelines
- Break complex requests into smaller, focused tasks
- Identify dependencies between tasks
- Consider testing and review as part of the plan
- Estimate complexity to help with prioritization

## Repository Context
{context}

## Available Task Types
- code_change: Modify existing code
- create_file: Create new file
- test_run: Run test suite
- review: Code review

## Response Format
Provide a plan as a JSON array of steps:
```json
{
  "summary": "Brief description of the overall plan",
  "steps": [
    {
      "description": "What this step does",
      "task_type": "code_change",
      "dependencies": [],
      "estimated_complexity": "low"
    }
  ]
}
```
"""

class PlannerAgent(Agent):
    """Agent that creates execution plans from intents."""

    async def plan(self, intent: dict) -> ExecutionPlan:
        """Create execution plan from intent."""

        # Gather context
        context = await self.gather_context(intent)

        # Get similar past tasks for reference
        past_tasks = await self.knowledge.get_relevant_history(
            intent.get("target_repo_id"),
            await self.llm.embed(intent["description"]),
            limit=5,
        )

        # Generate plan via LLM
        response = await self.llm.think(
            system_prompt=PLANNER_SYSTEM_PROMPT.format(context=self.format_context(context)),
            messages=[
                {"role": "user", "content": f"Plan this request: {intent['description']}"},
                {"role": "user", "content": f"Similar past tasks: {past_tasks}"},
            ],
        )

        # Parse plan
        plan_data = self.parse_plan_response(response.content)

        return ExecutionPlan(
            intent_id=intent["id"],
            steps=[PlanStep(**step) for step in plan_data["steps"]],
            summary=plan_data["summary"],
        )

    def parse_plan_response(self, content: str) -> dict:
        """Extract JSON plan from LLM response."""
        import json
        import re

        # Find JSON block
        match = re.search(r"```json\s*(.*?)\s*```", content, re.DOTALL)
        if match:
            return json.loads(match.group(1))

        # Try parsing entire content as JSON
        return json.loads(content)
```

---

### 4.2 Test Agent

**Goal:** Run tests and fix failures.

**Tasks:**
- [ ] Create TestAgent class
- [ ] Implement test execution via Argo
- [ ] Add failure analysis
- [ ] Implement fix generation

**Test Agent:**

```python
# jarvis/src/jarvis_agents/test_agent.py
from dataclasses import dataclass
from .base import Agent, Observation

@dataclass
class TestResult:
    """Result of test execution."""
    success: bool
    total: int
    passed: int
    failed: int
    failures: list[dict]
    output: str

@dataclass
class TestFix:
    """Suggested fix for a test failure."""
    test_name: str
    failure_reason: str
    suggested_fix: str
    file_path: str
    confidence: float

TEST_AGENT_SYSTEM_PROMPT = """
You are a test analysis expert. Your job is to:
1. Understand test failures
2. Identify root causes
3. Suggest fixes

## Test Output
{test_output}

## Failed Tests
{failures}

## Task
Analyze the failures and suggest fixes. Focus on the most likely root cause.
"""

class TestAgent(Agent):
    """Agent for running tests and fixing failures."""

    max_attempts = 3

    async def run_tests(self, repo_id: UUID) -> TestResult:
        """Run test suite via Argo Workflow."""

        # Submit workflow
        workflow_id = await self.submit_test_workflow(repo_id)

        # Wait for completion
        result = await self.wait_for_workflow(workflow_id)

        # Parse test output
        return self.parse_test_result(result)

    async def test_and_fix(
        self,
        repo_id: UUID,
        changes: list[dict],
    ) -> dict:
        """Run tests and attempt to fix failures."""

        for attempt in range(self.max_attempts):
            # Run tests
            result = await self.run_tests(repo_id)

            if result.success:
                return {
                    "success": True,
                    "attempts": attempt + 1,
                    "test_result": result,
                }

            # Analyze failures
            fixes = await self.analyze_failures(result)

            if not fixes:
                return {
                    "success": False,
                    "attempts": attempt + 1,
                    "message": "Could not determine fix",
                    "failures": result.failures,
                }

            # Apply fixes
            for fix in fixes:
                await self.apply_fix(fix)
                changes.append({
                    "path": fix.file_path,
                    "reason": f"Fix: {fix.test_name}",
                })

        return {
            "success": False,
            "attempts": self.max_attempts,
            "message": "Max fix attempts exceeded",
        }

    async def analyze_failures(self, result: TestResult) -> list[TestFix]:
        """Analyze test failures and suggest fixes."""

        response = await self.llm.think(
            system_prompt=TEST_AGENT_SYSTEM_PROMPT.format(
                test_output=result.output[:5000],  # Truncate if too long
                failures=result.failures,
            ),
            messages=[
                {"role": "user", "content": "Analyze these failures and suggest fixes."},
            ],
        )

        return self.parse_fixes(response.content)

    async def submit_test_workflow(self, repo_id: UUID) -> str:
        """Submit Argo workflow to run tests."""
        repo = await self.knowledge.get_repository(repo_id)

        workflow = {
            "metadata": {"generateName": f"test-{repo['name']}-"},
            "spec": {
                "workflowTemplateRef": {"name": "test-runner"},
                "arguments": {
                    "parameters": [
                        {"name": "repo-url", "value": repo["url"]},
                        {"name": "branch", "value": "jarvis-changes"},
                    ]
                },
            },
        }

        # Submit via Argo API
        result = await self.argo_client.create_workflow(workflow)
        return result["metadata"]["name"]
```

---

### 4.3 Review Agent

**Goal:** Check code quality before PR creation.

**Tasks:**
- [ ] Create ReviewAgent class
- [ ] Implement quality checks
- [ ] Add security scanning
- [ ] Generate review feedback

**Review Agent:**

```python
# jarvis/src/jarvis_agents/review_agent.py
from dataclasses import dataclass
from enum import Enum
from .base import Agent

class IssueSeverity(str, Enum):
    ERROR = "error"
    WARNING = "warning"
    INFO = "info"

@dataclass
class ReviewIssue:
    """An issue found during review."""
    severity: IssueSeverity
    category: str  # security, style, complexity, logic
    message: str
    file_path: str | None = None
    line: int | None = None

@dataclass
class ReviewResult:
    """Result of code review."""
    approved: bool
    issues: list[ReviewIssue]
    summary: str

REVIEW_SYSTEM_PROMPT = """
You are a code reviewer. Check changes for:
1. Security issues (injection, credentials, etc.)
2. Logic errors
3. Code quality
4. Style consistency

## Changes
{diff}

## Repository Standards
{standards}

Provide feedback in JSON format:
```json
{
  "approved": true/false,
  "summary": "Brief summary",
  "issues": [
    {
      "severity": "error|warning|info",
      "category": "security|style|complexity|logic",
      "message": "Description",
      "file_path": "path/to/file",
      "line": 42
    }
  ]
}
```
"""

class ReviewAgent(Agent):
    """Agent for reviewing code changes."""

    async def review(
        self,
        changes: list[dict],
        repo_config: dict,
    ) -> ReviewResult:
        """Review code changes."""

        # Get diff
        diff = await self.get_diff(changes)

        # Run automated checks
        auto_issues = await self.run_automated_checks(changes)

        # LLM review
        response = await self.llm.think(
            system_prompt=REVIEW_SYSTEM_PROMPT.format(
                diff=diff[:10000],  # Truncate if too long
                standards=repo_config.get("standards", "Standard best practices"),
            ),
            messages=[
                {"role": "user", "content": "Review these changes."},
            ],
        )

        llm_result = self.parse_review_response(response.content)

        # Combine issues
        all_issues = auto_issues + llm_result["issues"]

        # Determine approval
        blocking = [i for i in all_issues if i.severity == IssueSeverity.ERROR]

        return ReviewResult(
            approved=len(blocking) == 0,
            issues=all_issues,
            summary=llm_result["summary"],
        )

    async def run_automated_checks(self, changes: list[dict]) -> list[ReviewIssue]:
        """Run automated security and style checks."""
        issues = []

        for change in changes:
            content = change.get("new_content", "")

            # Security patterns
            security_patterns = [
                (r"password\s*=\s*['\"]", "Hardcoded password detected"),
                (r"api[_-]?key\s*=\s*['\"]", "Hardcoded API key detected"),
                (r"eval\s*\(", "Dangerous eval() usage"),
                (r"exec\s*\(", "Dangerous exec() usage"),
            ]

            import re
            for pattern, message in security_patterns:
                if re.search(pattern, content, re.IGNORECASE):
                    issues.append(ReviewIssue(
                        severity=IssueSeverity.ERROR,
                        category="security",
                        message=message,
                        file_path=change.get("path"),
                    ))

        return issues
```

---

### 4.4 Orchestrator

**Goal:** Coordinate multi-agent execution.

**Tasks:**
- [ ] Create Orchestrator class
- [ ] Implement task scheduling
- [ ] Handle parallel execution
- [ ] Manage failures and retries

**Orchestrator:**

```python
# jarvis/src/jarvis_agents/orchestrator.py
import asyncio
from uuid import UUID
from dataclasses import dataclass

from jarvis_bus import JarvisBus
from jarvis_events import IntentParsed, TaskCreated
from .planner import PlannerAgent, ExecutionPlan
from .code_agent import CodeAgent
from .test_agent import TestAgent
from .review_agent import ReviewAgent

@dataclass
class IntentResult:
    """Result of intent execution."""
    success: bool
    pr_url: str | None = None
    error: str | None = None
    tasks_completed: int = 0
    tasks_failed: int = 0

class Orchestrator:
    """Coordinates multi-agent task execution."""

    def __init__(
        self,
        bus: JarvisBus,
        planner: PlannerAgent,
        code_agent: CodeAgent,
        test_agent: TestAgent,
        review_agent: ReviewAgent,
    ):
        self.bus = bus
        self.planner = planner
        self.code_agent = code_agent
        self.test_agent = test_agent
        self.review_agent = review_agent

    async def execute_intent(self, intent: dict) -> IntentResult:
        """Execute an intent through the full pipeline."""

        # 1. Planning phase
        plan = await self.planner.plan(intent)
        await self.publish_plan(intent["id"], plan)

        # 2. Group tasks by dependencies
        task_groups = self.group_by_dependencies(plan.steps)

        # 3. Execute code changes
        all_changes = []
        for group in task_groups:
            # Execute independent tasks in parallel
            results = await asyncio.gather(*[
                self.execute_step(step, intent)
                for step in group
            ], return_exceptions=True)

            for i, result in enumerate(results):
                if isinstance(result, Exception):
                    return IntentResult(
                        success=False,
                        error=f"Task failed: {result}",
                        tasks_completed=len(all_changes),
                        tasks_failed=1,
                    )
                all_changes.extend(result.get("changes", []))

        # 4. Test phase
        test_result = await self.test_agent.test_and_fix(
            intent.get("target_repo_id"),
            all_changes,
        )

        if not test_result["success"]:
            return IntentResult(
                success=False,
                error="Tests failed after max fix attempts",
                tasks_completed=len(all_changes),
            )

        # 5. Review phase
        review_result = await self.review_agent.review(
            all_changes,
            intent.get("repo_config", {}),
        )

        if not review_result.approved:
            blocking = [i for i in review_result.issues if i.severity.value == "error"]
            return IntentResult(
                success=False,
                error=f"Review failed: {blocking[0].message if blocking else 'Unknown'}",
                tasks_completed=len(all_changes),
            )

        # 6. Create PR
        pr = await self.create_pr(intent, all_changes, plan.summary)

        return IntentResult(
            success=True,
            pr_url=pr["url"],
            tasks_completed=len(all_changes),
        )

    def group_by_dependencies(self, steps: list) -> list[list]:
        """Group steps by dependencies for parallel execution."""
        groups = []
        completed = set()

        while len(completed) < len(steps):
            # Find steps with all dependencies satisfied
            ready = [
                (i, step) for i, step in enumerate(steps)
                if i not in completed
                and all(dep in completed for dep in step.dependencies)
            ]

            if not ready:
                raise ValueError("Circular dependency detected")

            groups.append([step for _, step in ready])
            completed.update(i for i, _ in ready)

        return groups

    async def execute_step(self, step, intent: dict) -> dict:
        """Execute a single plan step."""
        if step.task_type in ["code_change", "create_file"]:
            return await self.code_agent.run({
                "id": UUID(),
                "description": step.description,
                "target_repo_id": intent.get("target_repo_id"),
            })
        else:
            raise ValueError(f"Unknown task type: {step.task_type}")

    async def create_pr(
        self,
        intent: dict,
        changes: list[dict],
        summary: str,
    ) -> dict:
        """Create pull request with all changes."""
        # Use git client to create PR
        # ...
        return {"url": "https://github.com/..."}
```

---

### 4.5 Intent Worker

**Goal:** Worker that processes intents through orchestrator.

**Tasks:**
- [ ] Subscribe to intent events
- [ ] Route to orchestrator
- [ ] Publish results
- [ ] Handle errors

**Intent Worker:**

```python
# jarvis/src/jarvis_agents/intent_worker.py
import asyncio
from jarvis_bus import JarvisBus
from jarvis_events import IntentParsed
from .orchestrator import Orchestrator

class IntentWorker:
    """Worker that processes intents through the orchestrator."""

    def __init__(self, bus: JarvisBus, orchestrator: Orchestrator):
        self.bus = bus
        self.orchestrator = orchestrator

    async def run(self):
        """Main worker loop."""
        print("Intent worker starting...")

        async for event in self.bus.subscribe(
            stream="INTENTS",
            consumer="intent-worker",
            filter_subject="jarvis.intent.parsed",
            payload_type=IntentParsed,
        ):
            asyncio.create_task(self.process_intent(event))

    async def process_intent(self, event):
        """Process a parsed intent."""
        intent = event.payload

        try:
            result = await self.orchestrator.execute_intent({
                "id": intent.intent_id,
                "description": intent.action,
                "target_repo": intent.target_repo,
                "parameters": intent.parameters,
            })

            if result.success:
                await self.bus.publish(
                    f"jarvis.intent.{intent.intent_id}.completed",
                    {
                        "success": True,
                        "pr_url": result.pr_url,
                    },
                )
            else:
                await self.bus.publish(
                    f"jarvis.intent.{intent.intent_id}.failed",
                    {
                        "success": False,
                        "error": result.error,
                    },
                )

        except Exception as e:
            await self.bus.publish(
                f"jarvis.intent.{intent.intent_id}.failed",
                {"success": False, "error": str(e)},
            )
```

---

## Definition of Done

- [ ] Planner decomposes intents into tasks
- [ ] CodeAgent executes tasks (potentially in parallel)
- [ ] TestAgent runs tests and attempts fixes
- [ ] ReviewAgent gates PR creation
- [ ] End-to-end: "Update the auth module" → tested PR

---

## Verification Steps

```bash
# 1. Submit complex intent
curl -X POST https://jarvis.homelab.local/api/v1/intents \
  -H "X-API-Key: $API_KEY" \
  -d '{"input": "Add input validation to all API endpoints"}'

# 2. Watch planning
kubectl exec -it nats-0 -n jarvis -- nats sub "jarvis.intent.*.plan"
# Expected: Plan with multiple steps

# 3. Watch execution
kubectl exec -it nats-0 -n jarvis -- nats sub "jarvis.agent.>"
# Expected: Multiple agents executing

# 4. Watch tests
kubectl exec -it nats-0 -n jarvis -- nats sub "jarvis.workflow.>"
# Expected: Test workflow events

# 5. Check result
curl https://jarvis.homelab.local/api/v1/intents/{intent_id}
# Expected: PR URL if successful
```

---

## Next Steps

After this iteration:
- [Iteration 5: Conversations](iteration-5-conversations.md) - Stateful sessions
- [Iteration 6: Learning](iteration-6-learning.md) - Feedback loops

