# Jarvis Iteration 6: Learning

> **Goal:** Feedback loops that improve agent performance over time.
>
> **Status:** ⬜ Not Started

---

## Overview

This iteration adds learning capabilities to Jarvis. By tracking outcomes (PR merged/rejected), user feedback, and similar past tasks, Jarvis can improve its planning and execution over time.

---

## Prerequisites

- [Iteration 5: Conversations](iteration-5-conversations.md) complete
- Full conversation flow working

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Learning System                           │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               Feedback Collection                    │   │
│  │                                                      │   │
│  │  PR Merged ──────┐                                  │   │
│  │  PR Rejected ────┼──▶ Feedback Store                │   │
│  │  User Thumbs ────┤                                  │   │
│  │  Explicit ───────┘                                  │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               Pattern Recognition                    │   │
│  │                                                      │   │
│  │  • What approaches work for which repos?            │   │
│  │  • Common failure patterns                          │   │
│  │  • User preference patterns                         │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                Similar Task Recall                   │   │
│  │                                                      │   │
│  │  New Task ──▶ Find Similar ──▶ Apply Learnings      │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  Metrics & Analysis                  │   │
│  │                                                      │   │
│  │  Success Rate │ Time to Merge │ Common Issues       │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Work Units

### 6.1 Feedback Collection

**Goal:** Collect feedback from multiple sources.

**Tasks:**
- [ ] Track PR merge/reject via webhooks
- [ ] Add user feedback endpoints
- [ ] Capture implicit signals
- [ ] Store feedback in knowledge graph

**Feedback Models:**

```python
# jarvis/src/jarvis_learning/feedback.py
from dataclasses import dataclass
from datetime import datetime
from uuid import UUID
from enum import Enum

class FeedbackType(str, Enum):
    PR_MERGED = "pr_merged"
    PR_REJECTED = "pr_rejected"
    PR_CHANGES_REQUESTED = "pr_changes_requested"
    USER_POSITIVE = "user_positive"
    USER_NEGATIVE = "user_negative"
    USER_CORRECTION = "user_correction"

@dataclass
class Feedback:
    """Feedback signal for learning."""
    id: UUID
    task_id: UUID
    feedback_type: FeedbackType
    source: str  # github, user, system
    context: dict  # Additional context
    timestamp: datetime

class FeedbackCollector:
    """Collects feedback from various sources."""

    def __init__(self, knowledge: KnowledgeClient, bus: JarvisBus):
        self.knowledge = knowledge
        self.bus = bus

    async def record_feedback(self, feedback: Feedback) -> None:
        """Record feedback in knowledge graph."""
        await self.knowledge.store_feedback(
            task_id=feedback.task_id,
            feedback_type=feedback.feedback_type.value,
            source=feedback.source,
            context=feedback.context,
        )

        # Publish event
        await self.bus.publish(
            "jarvis.feedback.received",
            {
                "task_id": str(feedback.task_id),
                "type": feedback.feedback_type.value,
                "source": feedback.source,
            },
        )

    async def handle_github_webhook(self, event: dict) -> None:
        """Handle GitHub PR webhook events."""
        action = event.get("action")
        pr = event.get("pull_request", {})

        # Find task by PR URL
        task = await self.knowledge.find_task_by_pr(pr.get("html_url"))
        if not task:
            return

        if action == "closed" and pr.get("merged"):
            await self.record_feedback(Feedback(
                id=UUID(),
                task_id=task["id"],
                feedback_type=FeedbackType.PR_MERGED,
                source="github",
                context={
                    "merged_by": pr.get("merged_by", {}).get("login"),
                    "time_to_merge_hours": self.calculate_time_to_merge(pr),
                },
                timestamp=datetime.utcnow(),
            ))

            # Update task
            await self.knowledge.update_task_status(
                task["id"],
                pr_merged=True,
            )

        elif action == "closed" and not pr.get("merged"):
            await self.record_feedback(Feedback(
                id=UUID(),
                task_id=task["id"],
                feedback_type=FeedbackType.PR_REJECTED,
                source="github",
                context={
                    "closed_by": event.get("sender", {}).get("login"),
                },
                timestamp=datetime.utcnow(),
            ))

        elif action == "review_requested_changes":
            await self.record_feedback(Feedback(
                id=UUID(),
                task_id=task["id"],
                feedback_type=FeedbackType.PR_CHANGES_REQUESTED,
                source="github",
                context={
                    "reviewer": event.get("review", {}).get("user", {}).get("login"),
                    "comments": event.get("review", {}).get("body"),
                },
                timestamp=datetime.utcnow(),
            ))
```

**Feedback API:**

```python
# jarvis/src/jarvis_api/routes/feedback.py
from uuid import UUID
from fastapi import APIRouter, Depends
from pydantic import BaseModel

router = APIRouter()

class UserFeedbackRequest(BaseModel):
    task_id: UUID
    positive: bool
    comment: str | None = None

@router.post("/feedback")
async def submit_feedback(
    request: UserFeedbackRequest,
    user_id: str = Depends(verify_api_key),
    collector: FeedbackCollector = Depends(),
):
    """Submit user feedback for a task."""
    await collector.record_feedback(Feedback(
        id=UUID(),
        task_id=request.task_id,
        feedback_type=FeedbackType.USER_POSITIVE if request.positive else FeedbackType.USER_NEGATIVE,
        source=f"user:{user_id}",
        context={"comment": request.comment},
        timestamp=datetime.utcnow(),
    ))

    return {"status": "recorded"}

@router.post("/webhooks/github")
async def github_webhook(
    event: dict,
    collector: FeedbackCollector = Depends(),
):
    """Handle GitHub webhooks."""
    event_type = event.get("action")
    if event_type in ["closed", "review_requested_changes"]:
        await collector.handle_github_webhook(event)

    return {"status": "processed"}
```

---

### 6.2 Similar Task Retrieval

**Goal:** Find and apply learnings from similar past tasks.

**Tasks:**
- [ ] Implement similarity search
- [ ] Extract successful patterns
- [ ] Identify failure patterns
- [ ] Integrate with planning

**Similar Task Finder:**

```python
# jarvis/src/jarvis_learning/similarity.py
from dataclasses import dataclass
from uuid import UUID
from jarvis_knowledge import KnowledgeClient

@dataclass
class SimilarTask:
    """A similar past task with outcome."""
    task_id: UUID
    description: str
    similarity: float
    success: bool
    pr_merged: bool | None
    plan: dict | None
    feedback: list[dict]
    learnings: str | None

class SimilarTaskFinder:
    """Finds similar past tasks for learning."""

    def __init__(self, knowledge: KnowledgeClient, embeddings):
        self.knowledge = knowledge
        self.embeddings = embeddings

    async def find_similar(
        self,
        description: str,
        repo_id: UUID | None = None,
        limit: int = 5,
    ) -> list[SimilarTask]:
        """Find similar past tasks."""
        # Get embedding
        embedding = await self.embeddings.embed(description)

        # Query knowledge graph
        rows = await self.knowledge.find_similar_tasks(
            embedding=embedding,
            repo_id=repo_id,
            limit=limit,
        )

        similar = []
        for row in rows:
            feedback = await self.knowledge.get_task_feedback(row["id"])

            similar.append(SimilarTask(
                task_id=row["id"],
                description=row["description"],
                similarity=row["similarity"],
                success=row["status"] == "completed",
                pr_merged=row.get("pr_merged"),
                plan=row.get("plan"),
                feedback=feedback,
                learnings=self.extract_learnings(row, feedback),
            ))

        return similar

    def extract_learnings(self, task: dict, feedback: list[dict]) -> str | None:
        """Extract learnings from task and feedback."""
        learnings = []

        if task.get("pr_merged"):
            learnings.append("This approach resulted in a merged PR.")

        if task.get("error"):
            learnings.append(f"Encountered error: {task['error']}")

        for fb in feedback:
            if fb["type"] == "pr_changes_requested":
                learnings.append(f"Reviewer requested changes: {fb.get('context', {}).get('comments', 'No details')}")
            elif fb["type"] == "user_negative":
                learnings.append(f"User was unsatisfied: {fb.get('context', {}).get('comment', 'No details')}")

        return " ".join(learnings) if learnings else None
```

**Integration with Planner:**

```python
# jarvis/src/jarvis_agents/planner.py (updated)

class PlannerAgent(Agent):
    def __init__(self, similar_finder: SimilarTaskFinder, **kwargs):
        super().__init__(**kwargs)
        self.similar_finder = similar_finder

    async def plan(self, intent: dict) -> ExecutionPlan:
        """Create execution plan with learnings from similar tasks."""

        # Find similar tasks
        similar = await self.similar_finder.find_similar(
            description=intent["description"],
            repo_id=intent.get("target_repo_id"),
            limit=5,
        )

        # Build prompt with learnings
        similar_context = self.format_similar_tasks(similar)

        # Generate plan (existing logic)
        response = await self.llm.think(
            system_prompt=PLANNER_SYSTEM_PROMPT.format(
                context=self.format_context(context),
                similar_tasks=similar_context,
            ),
            messages=[...],
        )

        return self.parse_plan(response)

    def format_similar_tasks(self, similar: list[SimilarTask]) -> str:
        """Format similar tasks for prompt."""
        if not similar:
            return "No similar past tasks found."

        lines = ["## Similar Past Tasks"]
        for task in similar:
            status = "✓ Merged" if task.pr_merged else ("✗ Failed" if not task.success else "Completed")
            lines.append(f"\n### {task.description[:100]} ({status})")

            if task.plan:
                lines.append(f"Plan: {len(task.plan.get('steps', []))} steps")

            if task.learnings:
                lines.append(f"Learnings: {task.learnings}")

        return "\n".join(lines)
```

---

### 6.3 Pattern Recognition

**Goal:** Identify patterns in successes and failures.

**Tasks:**
- [ ] Analyze task outcomes
- [ ] Identify repo-specific patterns
- [ ] Track common failure modes
- [ ] Generate improvement suggestions

**Pattern Analyzer:**

```python
# jarvis/src/jarvis_learning/patterns.py
from dataclasses import dataclass
from collections import defaultdict
from jarvis_knowledge import KnowledgeClient

@dataclass
class RepoPattern:
    """Patterns specific to a repository."""
    repo_id: UUID
    success_rate: float
    common_task_types: list[str]
    frequent_failures: list[str]
    average_time_to_merge: float | None
    preferred_approaches: list[str]

@dataclass
class GlobalPattern:
    """Global patterns across all repos."""
    overall_success_rate: float
    most_successful_task_types: list[str]
    common_failure_reasons: list[str]
    improvement_suggestions: list[str]

class PatternAnalyzer:
    """Analyzes patterns in task outcomes."""

    def __init__(self, knowledge: KnowledgeClient):
        self.knowledge = knowledge

    async def analyze_repo(self, repo_id: UUID) -> RepoPattern:
        """Analyze patterns for a specific repository."""

        # Get all tasks for repo
        tasks = await self.knowledge.get_repo_tasks(repo_id)
        feedback = await self.knowledge.get_repo_feedback(repo_id)

        # Calculate success rate
        completed = [t for t in tasks if t["status"] == "completed"]
        merged = [t for t in completed if t.get("pr_merged")]
        success_rate = len(merged) / len(completed) if completed else 0

        # Find common task types
        task_types = defaultdict(int)
        for task in tasks:
            task_types[task["task_type"]] += 1
        common_types = sorted(task_types.keys(), key=lambda x: -task_types[x])[:5]

        # Find frequent failures
        failure_reasons = defaultdict(int)
        for fb in feedback:
            if fb["type"] in ["pr_rejected", "user_negative"]:
                reason = fb.get("context", {}).get("comment", "Unknown")
                failure_reasons[reason[:50]] += 1
        frequent_failures = sorted(failure_reasons.keys(), key=lambda x: -failure_reasons[x])[:5]

        # Calculate average time to merge
        merge_times = []
        for task in merged:
            if task.get("completed_at") and task.get("created_at"):
                delta = task["completed_at"] - task["created_at"]
                merge_times.append(delta.total_seconds() / 3600)
        avg_time = sum(merge_times) / len(merge_times) if merge_times else None

        return RepoPattern(
            repo_id=repo_id,
            success_rate=success_rate,
            common_task_types=common_types,
            frequent_failures=frequent_failures,
            average_time_to_merge=avg_time,
            preferred_approaches=[],  # Extracted from successful plans
        )

    async def analyze_global(self) -> GlobalPattern:
        """Analyze global patterns across all repositories."""

        # Get all tasks and feedback
        stats = await self.knowledge.get_global_task_stats()

        # Calculate metrics
        success_rate = stats["merged_count"] / stats["total_count"] if stats["total_count"] > 0 else 0

        # Find successful task types
        successful_types = await self.knowledge.get_successful_task_types()

        # Find common failures
        common_failures = await self.knowledge.get_common_failure_reasons()

        # Generate suggestions
        suggestions = self.generate_suggestions(stats, common_failures)

        return GlobalPattern(
            overall_success_rate=success_rate,
            most_successful_task_types=successful_types,
            common_failure_reasons=common_failures,
            improvement_suggestions=suggestions,
        )

    def generate_suggestions(self, stats: dict, failures: list[str]) -> list[str]:
        """Generate improvement suggestions based on patterns."""
        suggestions = []

        if stats["test_failure_rate"] > 0.3:
            suggestions.append("High test failure rate - consider running tests earlier in the process")

        if "timeout" in str(failures).lower():
            suggestions.append("Tasks timing out frequently - consider breaking into smaller steps")

        if stats["average_attempts"] > 2:
            suggestions.append("Multiple attempts needed - improve initial planning")

        return suggestions
```

---

### 6.4 Metrics and Dashboard

**Goal:** Track and visualize learning metrics.

**Tasks:**
- [ ] Define key metrics
- [ ] Create Prometheus metrics
- [ ] Build Grafana dashboard
- [ ] Add trend analysis

**Metrics Exporter:**

```python
# jarvis/src/jarvis_learning/metrics.py
from prometheus_client import Counter, Gauge, Histogram
from jarvis_knowledge import KnowledgeClient

# Prometheus metrics
TASKS_TOTAL = Counter(
    "jarvis_tasks_total",
    "Total tasks processed",
    ["repo", "task_type", "status"]
)

TASKS_SUCCESS_RATE = Gauge(
    "jarvis_tasks_success_rate",
    "Task success rate",
    ["repo"]
)

PR_MERGE_RATE = Gauge(
    "jarvis_pr_merge_rate",
    "PR merge rate",
    ["repo"]
)

TASK_DURATION = Histogram(
    "jarvis_task_duration_seconds",
    "Task duration in seconds",
    ["task_type"],
    buckets=[60, 300, 600, 1800, 3600, 7200]
)

TIME_TO_MERGE = Histogram(
    "jarvis_time_to_merge_hours",
    "Time from PR creation to merge",
    ["repo"],
    buckets=[1, 4, 8, 24, 48, 72, 168]
)

class MetricsExporter:
    """Exports learning metrics to Prometheus."""

    def __init__(self, knowledge: KnowledgeClient):
        self.knowledge = knowledge

    async def update_metrics(self) -> None:
        """Update all metrics."""

        # Get stats per repo
        repos = await self.knowledge.get_enabled_repos()

        for repo in repos:
            stats = await self.knowledge.get_repo_task_stats(repo["id"])

            TASKS_SUCCESS_RATE.labels(repo=repo["name"]).set(
                stats["success_rate"]
            )

            PR_MERGE_RATE.labels(repo=repo["name"]).set(
                stats["merge_rate"]
            )

    def record_task_completion(
        self,
        repo_name: str,
        task_type: str,
        status: str,
        duration_seconds: float,
    ) -> None:
        """Record task completion metrics."""
        TASKS_TOTAL.labels(
            repo=repo_name,
            task_type=task_type,
            status=status,
        ).inc()

        TASK_DURATION.labels(task_type=task_type).observe(duration_seconds)

    def record_pr_merge(
        self,
        repo_name: str,
        hours_to_merge: float,
    ) -> None:
        """Record PR merge metrics."""
        TIME_TO_MERGE.labels(repo=repo_name).observe(hours_to_merge)
```

**Grafana Dashboard:**

```json
{
  "title": "Jarvis Learning Metrics",
  "panels": [
    {
      "title": "Overall Success Rate",
      "type": "gauge",
      "targets": [
        {
          "expr": "avg(jarvis_tasks_success_rate)"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "max": 1,
          "thresholds": {
            "steps": [
              {"color": "red", "value": 0},
              {"color": "yellow", "value": 0.6},
              {"color": "green", "value": 0.8}
            ]
          }
        }
      }
    },
    {
      "title": "PR Merge Rate by Repo",
      "type": "bargauge",
      "targets": [
        {
          "expr": "jarvis_pr_merge_rate",
          "legendFormat": "{{repo}}"
        }
      ]
    },
    {
      "title": "Tasks Over Time",
      "type": "graph",
      "targets": [
        {
          "expr": "sum(increase(jarvis_tasks_total[1d])) by (status)",
          "legendFormat": "{{status}}"
        }
      ]
    },
    {
      "title": "Task Duration Distribution",
      "type": "heatmap",
      "targets": [
        {
          "expr": "sum(increase(jarvis_task_duration_seconds_bucket[1h])) by (le)"
        }
      ]
    },
    {
      "title": "Time to Merge Trend",
      "type": "graph",
      "targets": [
        {
          "expr": "histogram_quantile(0.5, sum(rate(jarvis_time_to_merge_hours_bucket[7d])) by (le))",
          "legendFormat": "Median"
        },
        {
          "expr": "histogram_quantile(0.95, sum(rate(jarvis_time_to_merge_hours_bucket[7d])) by (le))",
          "legendFormat": "P95"
        }
      ]
    }
  ]
}
```

---

### 6.5 Continuous Improvement Loop

**Goal:** Automatically apply learnings to improve.

**Tasks:**
- [ ] Generate weekly reports
- [ ] Suggest configuration changes
- [ ] Track improvement over time
- [ ] A/B test approaches

**Improvement Loop:**

```python
# jarvis/src/jarvis_learning/improvement.py
from dataclasses import dataclass
from datetime import datetime, timedelta

@dataclass
class ImprovementReport:
    """Weekly improvement report."""
    period_start: datetime
    period_end: datetime
    tasks_completed: int
    success_rate: float
    success_rate_change: float  # vs previous period
    top_issues: list[str]
    recommendations: list[str]
    patterns_learned: list[str]

class ImprovementLoop:
    """Manages continuous improvement cycle."""

    def __init__(
        self,
        knowledge: KnowledgeClient,
        pattern_analyzer: PatternAnalyzer,
    ):
        self.knowledge = knowledge
        self.analyzer = pattern_analyzer

    async def generate_weekly_report(self) -> ImprovementReport:
        """Generate weekly improvement report."""
        now = datetime.utcnow()
        period_start = now - timedelta(days=7)
        prev_period_start = now - timedelta(days=14)

        # Current period stats
        current = await self.knowledge.get_period_stats(period_start, now)

        # Previous period stats
        previous = await self.knowledge.get_period_stats(prev_period_start, period_start)

        # Calculate change
        current_rate = current["merged"] / current["total"] if current["total"] > 0 else 0
        prev_rate = previous["merged"] / previous["total"] if previous["total"] > 0 else 0
        rate_change = current_rate - prev_rate

        # Get patterns
        global_patterns = await self.analyzer.analyze_global()

        return ImprovementReport(
            period_start=period_start,
            period_end=now,
            tasks_completed=current["total"],
            success_rate=current_rate,
            success_rate_change=rate_change,
            top_issues=global_patterns.common_failure_reasons[:5],
            recommendations=global_patterns.improvement_suggestions,
            patterns_learned=self.get_new_patterns(period_start),
        )

    async def apply_learnings(self) -> None:
        """Apply learnings to system configuration."""

        patterns = await self.analyzer.analyze_global()

        # Adjust guardrails based on patterns
        if patterns.overall_success_rate < 0.5:
            # Be more conservative
            await self.update_config({
                "max_files_changed": 5,  # Reduce from 10
                "require_confirmation": True,
            })

        # Adjust planning based on successful approaches
        for repo_id in await self.knowledge.get_enabled_repo_ids():
            repo_patterns = await self.analyzer.analyze_repo(repo_id)

            if repo_patterns.preferred_approaches:
                await self.update_repo_config(repo_id, {
                    "preferred_approaches": repo_patterns.preferred_approaches,
                })
```

---

## Definition of Done

- [ ] PR merge/reject tracked automatically
- [ ] User feedback collected and stored
- [ ] Similar past tasks influence planning
- [ ] Success rate metrics visible in Grafana
- [ ] Weekly improvement reports generated
- [ ] Demonstrable improvement over baseline

---

## Verification Steps

```bash
# 1. Submit task and merge PR
# Create task, get PR, merge in GitHub
# Verify feedback event received

# 2. Check similar task retrieval
curl "https://jarvis.homelab.local/api/v1/similar-tasks?description=update%20auth"
# Expected: List of similar past tasks with outcomes

# 3. Check metrics
curl "http://localhost:9090/api/v1/query?query=jarvis_tasks_success_rate"
# Expected: Success rate per repo

# 4. View dashboard
# Open Grafana > Jarvis Learning Metrics
# Expected: All panels showing data

# 5. Generate report
curl -X POST "https://jarvis.homelab.local/api/v1/reports/weekly"
# Expected: Report with metrics and recommendations
```

---

## Success Metrics

| Metric | Baseline | Target |
|--------|----------|--------|
| PR Merge Rate | - | >70% |
| Average Attempts | - | <2 |
| Time to Merge | - | <24h |
| Test Pass Rate | - | >80% |
| User Satisfaction | - | >4/5 |

---

## Related Documentation

- [Overview](../overview.md) - System architecture
- [Events](../events.md) - Feedback event schemas
- [Knowledge Graph](../knowledge-graph.md) - Feedback storage
- [Agents](../agents.md) - How agents use learnings

