# Jarvis Iteration 2: Knowledge Graph

> **Goal:** PostgreSQL + pgvector for code understanding and history.
>
> **Status:** ⬜ Not Started

---

## Overview

The Knowledge Graph stores Jarvis's understanding of repositories, code structure, task history, and conversation context. It uses PostgreSQL with pgvector for semantic search capabilities.

---

## Prerequisites

- [Iteration 0: Event Bus](iteration-0-event-bus.md) complete
- [Iteration 1: API Gateway](iteration-1-api-gateway.md) complete
- NATS JetStream running

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Knowledge Graph                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   PostgreSQL                         │   │
│  │                                                      │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│  │  │ Repositories│  │   Files     │  │  Symbols    │  │   │
│  │  │             │  │ + embeddings│  │ + embeddings│  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │   │
│  │                                                      │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│  │  │   Tasks     │  │Conversations│  │  Feedback   │  │   │
│  │  │             │  │ + embeddings│  │             │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │   │
│  │                                                      │   │
│  │  ┌─────────────────────────────────────────────────┐│   │
│  │  │              pgvector extension                 ││   │
│  │  │         (vector similarity search)             ││   │
│  │  └─────────────────────────────────────────────────┘│   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Knowledge Client (Python)               │   │
│  │  • Semantic search  • Context gathering              │   │
│  │  • Repository indexing  • History queries            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Work Units

### 2.1 PostgreSQL Deployment

**Goal:** Deploy PostgreSQL with pgvector extension.

**Tasks:**
- [ ] Deploy PostgreSQL via Helm
- [ ] Enable pgvector extension
- [ ] Configure persistent storage
- [ ] Set up backup job

**HelmRelease:**

```yaml
# platform/clusters/homelab/infra/jarvis/postgres/release.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: postgres
  namespace: jarvis
spec:
  interval: 30m
  chart:
    spec:
      chart: postgresql
      version: "15.x.x"
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  values:
    image:
      repository: pgvector/pgvector
      tag: pg16

    auth:
      postgresPassword: ""  # Set via secret
      database: jarvis

    primary:
      persistence:
        enabled: true
        size: 20Gi

      initdb:
        scripts:
          init-extensions.sql: |
            CREATE EXTENSION IF NOT EXISTS vector;
            CREATE EXTENSION IF NOT EXISTS pg_trgm;

      resources:
        requests:
          memory: 256Mi
          cpu: 100m
        limits:
          memory: 1Gi

    metrics:
      enabled: true
      serviceMonitor:
        enabled: true
```

---

### 2.2 Schema Implementation

**Goal:** Create database schema for knowledge storage.

**Tasks:**
- [ ] Create migration system
- [ ] Implement core tables
- [ ] Add indexes for performance
- [ ] Create vector indexes

**Migration Tool:**

```python
# jarvis/src/jarvis_knowledge/migrations.py
import asyncpg
from pathlib import Path

MIGRATIONS_DIR = Path(__file__).parent / "migrations"

async def run_migrations(pool: asyncpg.Pool):
    """Run pending migrations."""
    async with pool.acquire() as conn:
        # Create migrations table
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TIMESTAMP DEFAULT NOW()
            )
        """)

        # Get applied versions
        applied = set(
            row["version"]
            for row in await conn.fetch("SELECT version FROM schema_migrations")
        )

        # Run pending migrations
        for migration_file in sorted(MIGRATIONS_DIR.glob("*.sql")):
            version = int(migration_file.stem.split("_")[0])
            if version not in applied:
                sql = migration_file.read_text()
                await conn.execute(sql)
                await conn.execute(
                    "INSERT INTO schema_migrations (version) VALUES ($1)",
                    version
                )
                print(f"Applied migration {version}")
```

**Initial Migration:**

```sql
-- jarvis/src/jarvis_knowledge/migrations/001_initial.sql

-- Repositories
CREATE TABLE repositories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    url TEXT NOT NULL UNIQUE,
    default_branch TEXT NOT NULL DEFAULT 'main',
    primary_language TEXT,
    description TEXT,

    -- Jarvis configuration
    enabled BOOLEAN NOT NULL DEFAULT false,
    jarvis_config JSONB,

    -- Indexing state
    last_indexed_at TIMESTAMP,
    index_status TEXT DEFAULT 'pending',
    file_count INTEGER DEFAULT 0,
    symbol_count INTEGER DEFAULT 0,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_repos_enabled ON repositories(enabled);
CREATE INDEX idx_repos_url ON repositories(url);

-- Files
CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id UUID NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,

    path TEXT NOT NULL,
    language TEXT,
    size_bytes INTEGER,
    last_modified TIMESTAMP,
    content_hash TEXT,

    summary TEXT,
    embedding VECTOR(1536),

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(repo_id, path)
);

CREATE INDEX idx_files_repo ON files(repo_id);
CREATE INDEX idx_files_path ON files(repo_id, path);
CREATE INDEX idx_files_language ON files(language);

-- Symbols
CREATE TABLE symbols (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,

    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    signature TEXT,
    documentation TEXT,

    start_line INTEGER NOT NULL,
    end_line INTEGER NOT NULL,

    summary TEXT,
    embedding VECTOR(1536),

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_symbols_file ON symbols(file_id);
CREATE INDEX idx_symbols_name ON symbols(name);
CREATE INDEX idx_symbols_kind ON symbols(kind);

-- Tasks
CREATE TABLE tasks (
    id UUID PRIMARY KEY,
    intent_id UUID NOT NULL,

    description TEXT NOT NULL,
    task_type TEXT NOT NULL,
    target_repo_id UUID REFERENCES repositories(id),

    status TEXT NOT NULL DEFAULT 'pending',
    plan JSONB,
    result JSONB,
    error TEXT,

    created_at TIMESTAMP DEFAULT NOW(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,

    pr_url TEXT,
    pr_merged BOOLEAN
);

CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_repo ON tasks(target_repo_id);
CREATE INDEX idx_tasks_created ON tasks(created_at DESC);

-- Conversations
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT,

    started_at TIMESTAMP DEFAULT NOW(),
    last_activity_at TIMESTAMP DEFAULT NOW(),

    context JSONB DEFAULT '{}'::jsonb,
    expires_at TIMESTAMP
);

CREATE INDEX idx_convos_user ON conversations(user_id);

CREATE TABLE conversation_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,

    role TEXT NOT NULL,
    content TEXT NOT NULL,
    embedding VECTOR(1536),

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_msgs_convo ON conversation_messages(conversation_id, created_at);

-- Feedback
CREATE TABLE feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID REFERENCES tasks(id),

    feedback_type TEXT NOT NULL,
    source TEXT,
    context JSONB,

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_feedback_task ON feedback(task_id);
CREATE INDEX idx_feedback_type ON feedback(feedback_type);

-- Dependencies
CREATE TABLE repo_dependencies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_repo_id UUID NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    target_repo_id UUID REFERENCES repositories(id) ON DELETE SET NULL,

    target_name TEXT NOT NULL,
    dependency_type TEXT NOT NULL,
    version_constraint TEXT,

    created_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(source_repo_id, target_name, dependency_type)
);

CREATE INDEX idx_deps_source ON repo_dependencies(source_repo_id);
CREATE INDEX idx_deps_target ON repo_dependencies(target_repo_id);
```

**Vector Index Migration:**

```sql
-- jarvis/src/jarvis_knowledge/migrations/002_vector_indexes.sql

-- Create IVFFlat indexes for vector similarity search
-- These require data to exist first, so run after initial indexing

CREATE INDEX idx_files_embedding ON files
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

CREATE INDEX idx_symbols_embedding ON symbols
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

CREATE INDEX idx_msgs_embedding ON conversation_messages
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

---

### 2.3 Knowledge Client

**Goal:** Create Python client for knowledge operations.

**Tasks:**
- [ ] Create async database client
- [ ] Implement CRUD operations
- [ ] Add semantic search methods
- [ ] Create context gathering utilities

**Knowledge Client:**

```python
# jarvis/src/jarvis_knowledge/client.py
from uuid import UUID
from typing import AsyncIterator
import asyncpg
from pydantic import BaseModel

class FileMatch(BaseModel):
    id: UUID
    path: str
    summary: str | None
    repo_name: str
    similarity: float

class KnowledgeClient:
    """Client for knowledge graph operations."""

    def __init__(self, pool: asyncpg.Pool):
        self.pool = pool

    @classmethod
    async def create(cls, dsn: str) -> "KnowledgeClient":
        pool = await asyncpg.create_pool(dsn, min_size=5, max_size=20)
        return cls(pool)

    async def close(self):
        await self.pool.close()

    # Repository operations
    async def get_repository(self, repo_id: UUID) -> dict | None:
        async with self.pool.acquire() as conn:
            return await conn.fetchrow(
                "SELECT * FROM repositories WHERE id = $1",
                repo_id
            )

    async def upsert_repository(self, url: str, **kwargs) -> UUID:
        async with self.pool.acquire() as conn:
            row = await conn.fetchrow("""
                INSERT INTO repositories (url, name, default_branch)
                VALUES ($1, $2, $3)
                ON CONFLICT (url) DO UPDATE SET updated_at = NOW()
                RETURNING id
            """, url, kwargs.get("name", url.split("/")[-1]), kwargs.get("branch", "main"))
            return row["id"]

    # Semantic search
    async def find_similar_files(
        self,
        embedding: list[float],
        repo_id: UUID | None = None,
        limit: int = 10,
    ) -> list[FileMatch]:
        async with self.pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT
                    f.id,
                    f.path,
                    f.summary,
                    r.name as repo_name,
                    1 - (f.embedding <=> $1::vector) as similarity
                FROM files f
                JOIN repositories r ON f.repo_id = r.id
                WHERE r.enabled = true
                  AND ($2::uuid IS NULL OR f.repo_id = $2)
                ORDER BY f.embedding <=> $1::vector
                LIMIT $3
            """, embedding, repo_id, limit)

            return [FileMatch(**dict(row)) for row in rows]

    async def find_similar_symbols(
        self,
        embedding: list[float],
        repo_id: UUID | None = None,
        kind: str | None = None,
        limit: int = 10,
    ) -> list[dict]:
        async with self.pool.acquire() as conn:
            return await conn.fetch("""
                SELECT
                    s.id,
                    s.name,
                    s.kind,
                    s.signature,
                    f.path,
                    r.name as repo_name,
                    1 - (s.embedding <=> $1::vector) as similarity
                FROM symbols s
                JOIN files f ON s.file_id = f.id
                JOIN repositories r ON f.repo_id = r.id
                WHERE r.enabled = true
                  AND ($2::uuid IS NULL OR f.repo_id = $2)
                  AND ($3::text IS NULL OR s.kind = $3)
                ORDER BY s.embedding <=> $1::vector
                LIMIT $4
            """, embedding, repo_id, kind, limit)

    # Task operations
    async def create_task(self, task_id: UUID, intent_id: UUID, **kwargs) -> None:
        async with self.pool.acquire() as conn:
            await conn.execute("""
                INSERT INTO tasks (id, intent_id, description, task_type, target_repo_id, status)
                VALUES ($1, $2, $3, $4, $5, 'pending')
            """, task_id, intent_id, kwargs["description"], kwargs["task_type"], kwargs.get("target_repo_id"))

    async def update_task_status(self, task_id: UUID, status: str, **kwargs) -> None:
        async with self.pool.acquire() as conn:
            await conn.execute("""
                UPDATE tasks
                SET status = $2,
                    started_at = CASE WHEN $2 = 'running' THEN NOW() ELSE started_at END,
                    completed_at = CASE WHEN $2 IN ('completed', 'failed') THEN NOW() ELSE completed_at END,
                    result = COALESCE($3, result),
                    error = COALESCE($4, error),
                    pr_url = COALESCE($5, pr_url)
                WHERE id = $1
            """, task_id, status, kwargs.get("result"), kwargs.get("error"), kwargs.get("pr_url"))

    # Context gathering
    async def gather_context(
        self,
        task_description: str,
        repo_id: UUID,
        embedding: list[float],
        token_budget: int = 8000,
    ) -> dict:
        """Gather relevant context for a task."""

        # Find relevant files
        files = await self.find_similar_files(embedding, repo_id, limit=20)

        # Get repo structure
        structure = await self.get_repo_structure(repo_id)

        # Get relevant history
        history = await self.get_relevant_history(repo_id, embedding, limit=5)

        # Fit within budget (simplified)
        return {
            "files": files[:10],  # Top 10 files
            "structure": structure,
            "history": history,
        }

    async def get_repo_structure(self, repo_id: UUID) -> dict:
        """Get high-level repository structure."""
        async with self.pool.acquire() as conn:
            files = await conn.fetch("""
                SELECT path, language FROM files
                WHERE repo_id = $1
                ORDER BY path
            """, repo_id)

            # Build tree structure
            tree = {}
            for row in files:
                parts = row["path"].split("/")
                current = tree
                for part in parts[:-1]:
                    current = current.setdefault(part, {})
                current[parts[-1]] = row["language"]

            return tree

    async def get_relevant_history(
        self,
        repo_id: UUID,
        embedding: list[float],
        limit: int = 5,
    ) -> list[dict]:
        """Get similar past tasks."""
        async with self.pool.acquire() as conn:
            return await conn.fetch("""
                SELECT
                    t.id,
                    t.description,
                    t.status,
                    t.pr_url,
                    t.pr_merged
                FROM tasks t
                WHERE t.target_repo_id = $1
                  AND t.status = 'completed'
                ORDER BY t.created_at DESC
                LIMIT $2
            """, repo_id, limit)
```

---

### 2.4 Repository Indexing

**Goal:** Create pipeline to index repositories.

**Tasks:**
- [ ] Implement file walker
- [ ] Extract symbols (language-specific)
- [ ] Generate embeddings
- [ ] Store in database

**Indexing Service:**

```python
# jarvis/src/jarvis_knowledge/indexer.py
import hashlib
from pathlib import Path
from uuid import UUID
import aiofiles
from .client import KnowledgeClient
from .embeddings import EmbeddingClient
from .symbols import extract_symbols

class RepositoryIndexer:
    """Index repositories into the knowledge graph."""

    def __init__(
        self,
        knowledge: KnowledgeClient,
        embeddings: EmbeddingClient,
    ):
        self.knowledge = knowledge
        self.embeddings = embeddings

    async def index_repository(self, repo_path: Path, repo_id: UUID) -> None:
        """Index a repository into the knowledge graph."""

        # Update status
        await self.knowledge.update_repo_status(repo_id, "indexing")

        try:
            # Walk files
            files_to_embed = []
            for file_path in self.walk_files(repo_path):
                rel_path = str(file_path.relative_to(repo_path))

                # Read content
                async with aiofiles.open(file_path, "r") as f:
                    try:
                        content = await f.read()
                    except UnicodeDecodeError:
                        continue  # Skip binary files

                # Calculate hash
                content_hash = hashlib.sha256(content.encode()).hexdigest()

                # Check if changed
                existing = await self.knowledge.get_file(repo_id, rel_path)
                if existing and existing["content_hash"] == content_hash:
                    continue  # Skip unchanged files

                # Generate summary
                summary = await self.summarize_file(rel_path, content)

                files_to_embed.append({
                    "path": rel_path,
                    "content": content,
                    "summary": summary,
                    "content_hash": content_hash,
                    "language": self.detect_language(rel_path),
                    "size_bytes": len(content.encode()),
                })

            # Batch embed files
            texts = [f"{f['path']}\n{f['summary']}" for f in files_to_embed]
            embeddings = await self.embeddings.embed_batch(texts)

            # Store files
            for file_data, embedding in zip(files_to_embed, embeddings):
                file_id = await self.knowledge.upsert_file(
                    repo_id=repo_id,
                    path=file_data["path"],
                    summary=file_data["summary"],
                    embedding=embedding,
                    content_hash=file_data["content_hash"],
                    language=file_data["language"],
                    size_bytes=file_data["size_bytes"],
                )

                # Extract and store symbols
                symbols = extract_symbols(file_data["content"], file_data["language"])
                for symbol in symbols:
                    symbol_text = f"{symbol.kind} {symbol.name}: {symbol.signature}"
                    symbol_embedding = await self.embeddings.embed(symbol_text)
                    await self.knowledge.upsert_symbol(
                        file_id=file_id,
                        name=symbol.name,
                        kind=symbol.kind,
                        signature=symbol.signature,
                        start_line=symbol.start_line,
                        end_line=symbol.end_line,
                        embedding=symbol_embedding,
                    )

            # Update status
            await self.knowledge.update_repo_status(repo_id, "ready")

        except Exception as e:
            await self.knowledge.update_repo_status(repo_id, "failed", error=str(e))
            raise

    def walk_files(self, repo_path: Path):
        """Walk repository files, respecting .gitignore."""
        ignore_patterns = [".git", "node_modules", "__pycache__", ".venv", "target"]

        for path in repo_path.rglob("*"):
            if path.is_file():
                if not any(p in path.parts for p in ignore_patterns):
                    yield path

    def detect_language(self, path: str) -> str | None:
        """Detect language from file extension."""
        ext_map = {
            ".py": "python",
            ".rs": "rust",
            ".ts": "typescript",
            ".tsx": "typescript",
            ".js": "javascript",
            ".jsx": "javascript",
            ".go": "go",
            ".java": "java",
            ".nix": "nix",
            ".yaml": "yaml",
            ".yml": "yaml",
            ".json": "json",
            ".md": "markdown",
        }
        ext = Path(path).suffix.lower()
        return ext_map.get(ext)

    async def summarize_file(self, path: str, content: str) -> str:
        """Generate AI summary of file."""
        # Use LLM to summarize (simplified)
        # In practice, use Claude API
        return f"File at {path}"
```

---

### 2.5 Embedding Service

**Goal:** Create service for generating embeddings.

**Tasks:**
- [ ] Integrate OpenAI embeddings API
- [ ] Implement batching
- [ ] Add caching
- [ ] Handle rate limits

**Embedding Client:**

```python
# jarvis/src/jarvis_knowledge/embeddings.py
import asyncio
from typing import Sequence
import httpx

class EmbeddingClient:
    """Client for generating embeddings."""

    def __init__(self, api_key: str, model: str = "text-embedding-3-small"):
        self.api_key = api_key
        self.model = model
        self.client = httpx.AsyncClient(
            base_url="https://api.openai.com/v1",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=60.0,
        )

    async def embed(self, text: str) -> list[float]:
        """Embed a single text."""
        result = await self.embed_batch([text])
        return result[0]

    async def embed_batch(
        self,
        texts: Sequence[str],
        batch_size: int = 100,
    ) -> list[list[float]]:
        """Embed multiple texts in batches."""
        embeddings = []

        for i in range(0, len(texts), batch_size):
            batch = texts[i : i + batch_size]

            response = await self.client.post(
                "/embeddings",
                json={
                    "input": batch,
                    "model": self.model,
                },
            )
            response.raise_for_status()
            data = response.json()

            batch_embeddings = [item["embedding"] for item in data["data"]]
            embeddings.extend(batch_embeddings)

            # Rate limiting
            if i + batch_size < len(texts):
                await asyncio.sleep(0.1)

        return embeddings

    async def close(self):
        await self.client.aclose()
```

---

## Definition of Done

- [ ] PostgreSQL running with pgvector extension
- [ ] Schema migrated with all tables
- [ ] Can index a repository (files + symbols)
- [ ] Semantic search returns relevant results
- [ ] Task history queryable
- [ ] API endpoints use knowledge graph

---

## Verification Steps

```bash
# 1. Check PostgreSQL
kubectl get pods -n jarvis -l app.kubernetes.io/name=postgresql
# Expected: postgres-0 Running

# 2. Check pgvector extension
kubectl exec -it postgres-0 -n jarvis -- psql -U postgres -d jarvis -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
# Expected: vector extension listed

# 3. Check tables
kubectl exec -it postgres-0 -n jarvis -- psql -U postgres -d jarvis -c "\dt"
# Expected: All tables listed

# 4. Test indexing (from Python)
python -c "
import asyncio
from jarvis_knowledge import KnowledgeClient, RepositoryIndexer

async def test():
    client = await KnowledgeClient.create('postgresql://...')
    # Index test repo
    print('Indexing works!')

asyncio.run(test())
"

# 5. Test semantic search
python -c "
import asyncio
from jarvis_knowledge import KnowledgeClient, EmbeddingClient

async def test():
    client = await KnowledgeClient.create('postgresql://...')
    embeddings = EmbeddingClient('...')

    query = 'authentication login'
    embedding = await embeddings.embed(query)
    results = await client.find_similar_files(embedding)

    for r in results:
        print(f'{r.similarity:.3f} {r.path}')

asyncio.run(test())
"
```

---

## Next Steps

After this iteration:
- [Iteration 3: Single Agent](iteration-3-single-agent.md) - Use knowledge for context
- [Iteration 5: Conversations](iteration-5-conversations.md) - Store conversation history

