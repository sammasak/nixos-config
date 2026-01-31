# Jarvis Core - Knowledge Graph

> **Purpose:** Define the schema and queries for Jarvis's code understanding system.

---

## Overview

The Knowledge Graph stores Jarvis's understanding of:

- **Repositories** - Metadata, configuration, relationships
- **Code Structure** - Files, symbols, dependencies
- **History** - Tasks, conversations, outcomes
- **Learning** - Feedback signals for improvement

**Technology:** PostgreSQL with pgvector extension for vector similarity search.

---

## Why PostgreSQL + pgvector?

| Consideration | Decision |
|---------------|----------|
| Operational simplicity | Single database to manage |
| Relational queries | Strong for structured data |
| Vector search | pgvector provides similarity search |
| Homelab scale | Doesn't need distributed graph DB |
| Maturity | Well-understood, excellent tooling |

If we outgrow this, we can evaluate Neo4j or dedicated vector DBs later.

---

## Schema

### Core Entities

#### Repositories

```sql
CREATE TABLE repositories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    url TEXT NOT NULL UNIQUE,
    default_branch TEXT NOT NULL DEFAULT 'main',
    primary_language TEXT,
    description TEXT,

    -- Jarvis configuration
    enabled BOOLEAN NOT NULL DEFAULT false,
    jarvis_config JSONB,  -- Parsed .jarvis.yaml

    -- Metadata
    last_indexed_at TIMESTAMP,
    index_status TEXT DEFAULT 'pending',  -- pending, indexing, ready, failed
    file_count INTEGER DEFAULT 0,
    symbol_count INTEGER DEFAULT 0,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_repos_enabled ON repositories(enabled);
CREATE INDEX idx_repos_url ON repositories(url);
```

#### Files

```sql
CREATE TABLE files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    repo_id UUID NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,

    -- File info
    path TEXT NOT NULL,
    language TEXT,
    size_bytes INTEGER,
    last_modified TIMESTAMP,
    content_hash TEXT,  -- For change detection

    -- AI-generated
    summary TEXT,  -- Brief description of file purpose
    embedding VECTOR(1536),  -- For semantic search

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(repo_id, path)
);

CREATE INDEX idx_files_repo ON files(repo_id);
CREATE INDEX idx_files_path ON files(repo_id, path);
CREATE INDEX idx_files_language ON files(language);
CREATE INDEX idx_files_embedding ON files
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

#### Symbols

```sql
CREATE TABLE symbols (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id UUID NOT NULL REFERENCES files(id) ON DELETE CASCADE,

    -- Symbol info
    name TEXT NOT NULL,
    kind TEXT NOT NULL,  -- function, class, method, variable, type
    signature TEXT,  -- Full signature
    documentation TEXT,  -- Docstring if available

    -- Location
    start_line INTEGER NOT NULL,
    end_line INTEGER NOT NULL,

    -- AI-generated
    summary TEXT,
    embedding VECTOR(1536),

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_symbols_file ON symbols(file_id);
CREATE INDEX idx_symbols_name ON symbols(name);
CREATE INDEX idx_symbols_kind ON symbols(kind);
CREATE INDEX idx_symbols_embedding ON symbols
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

### Relationships

#### Repository Dependencies

```sql
CREATE TABLE repo_dependencies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_repo_id UUID NOT NULL REFERENCES repositories(id) ON DELETE CASCADE,
    target_repo_id UUID REFERENCES repositories(id) ON DELETE SET NULL,

    -- Dependency info
    target_name TEXT NOT NULL,  -- Package name (may not be in our repos)
    dependency_type TEXT NOT NULL,  -- runtime, dev, build, peer
    version_constraint TEXT,

    created_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(source_repo_id, target_name, dependency_type)
);

CREATE INDEX idx_deps_source ON repo_dependencies(source_repo_id);
CREATE INDEX idx_deps_target ON repo_dependencies(target_repo_id);
```

#### Symbol References

```sql
CREATE TABLE symbol_references (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_symbol_id UUID NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
    to_symbol_id UUID NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
    reference_type TEXT NOT NULL,  -- calls, imports, extends, implements

    created_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(from_symbol_id, to_symbol_id, reference_type)
);

CREATE INDEX idx_refs_from ON symbol_references(from_symbol_id);
CREATE INDEX idx_refs_to ON symbol_references(to_symbol_id);
```

### History

#### Tasks

```sql
CREATE TABLE tasks (
    id UUID PRIMARY KEY,
    intent_id UUID NOT NULL,

    -- Task info
    description TEXT NOT NULL,
    task_type TEXT NOT NULL,
    target_repo_id UUID REFERENCES repositories(id),

    -- Execution
    status TEXT NOT NULL DEFAULT 'pending',
    plan JSONB,
    result JSONB,
    error TEXT,

    -- Timing
    created_at TIMESTAMP DEFAULT NOW(),
    started_at TIMESTAMP,
    completed_at TIMESTAMP,

    -- Outcome
    pr_url TEXT,
    pr_merged BOOLEAN
);

CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_repo ON tasks(target_repo_id);
CREATE INDEX idx_tasks_created ON tasks(created_at DESC);
```

#### Conversations

```sql
CREATE TABLE conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id TEXT,

    -- State
    started_at TIMESTAMP DEFAULT NOW(),
    last_activity_at TIMESTAMP DEFAULT NOW(),

    -- Accumulated context
    context JSONB DEFAULT '{}'::jsonb,

    -- Expiry
    expires_at TIMESTAMP
);

CREATE INDEX idx_convos_user ON conversations(user_id);
CREATE INDEX idx_convos_activity ON conversations(last_activity_at);

CREATE TABLE conversation_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,

    -- Message
    role TEXT NOT NULL,  -- user, assistant, system
    content TEXT NOT NULL,

    -- For context retrieval
    embedding VECTOR(1536),

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_msgs_convo ON conversation_messages(conversation_id, created_at);
CREATE INDEX idx_msgs_embedding ON conversation_messages
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

### Learning

#### Feedback

```sql
CREATE TABLE feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID REFERENCES tasks(id),

    -- Feedback
    feedback_type TEXT NOT NULL,  -- pr_merged, pr_rejected, user_positive, user_negative
    source TEXT,  -- Who/what provided feedback
    context JSONB,  -- Additional context

    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_feedback_task ON feedback(task_id);
CREATE INDEX idx_feedback_type ON feedback(feedback_type);
```

---

## Key Queries

### Semantic Search

Find files similar to a query:

```sql
-- Find files semantically similar to a description
SELECT
    f.id,
    f.path,
    f.summary,
    r.name as repo_name,
    1 - (f.embedding <=> $1) as similarity
FROM files f
JOIN repositories r ON f.repo_id = r.id
WHERE r.enabled = true
  AND ($2::uuid IS NULL OR f.repo_id = $2)
ORDER BY f.embedding <=> $1
LIMIT $3;
```

```python
async def find_similar_files(
    self,
    query_embedding: list[float],
    repo_id: UUID | None = None,
    limit: int = 10
) -> list[FileMatch]:
    """Find files semantically similar to query."""
    return await self.db.fetch_all(
        SIMILAR_FILES_QUERY,
        query_embedding, repo_id, limit
    )
```

### Context Gathering

Assemble context for a task:

```python
async def gather_context(
    self,
    task_description: str,
    repo_id: UUID,
    token_budget: int = 8000
) -> TaskContext:
    """Gather relevant context for a task."""

    # 1. Embed the task description
    embedding = await self.embed(task_description)

    # 2. Find relevant files
    files = await self.find_similar_files(
        embedding, repo_id, limit=20
    )

    # 3. Get symbols from those files
    symbols = await self.get_symbols_for_files(
        [f.id for f in files]
    )

    # 4. Get repo structure
    structure = await self.get_repo_structure(repo_id)

    # 5. Get relevant history
    history = await self.get_relevant_history(
        repo_id, embedding, limit=5
    )

    # 6. Fit within token budget
    return self.fit_to_budget(
        files, symbols, structure, history,
        budget=token_budget
    )
```

### Repository Analysis

Get overview of a repository:

```sql
-- Repository summary
SELECT
    r.*,
    COUNT(DISTINCT f.id) as file_count,
    COUNT(DISTINCT s.id) as symbol_count,
    array_agg(DISTINCT f.language) FILTER (WHERE f.language IS NOT NULL) as languages,
    (
        SELECT COUNT(*) FROM tasks t
        WHERE t.target_repo_id = r.id AND t.status = 'completed'
    ) as completed_tasks,
    (
        SELECT COUNT(*) FROM tasks t
        WHERE t.target_repo_id = r.id AND t.pr_merged = true
    ) as merged_prs
FROM repositories r
LEFT JOIN files f ON f.repo_id = r.id
LEFT JOIN symbols s ON s.file_id = f.id
WHERE r.id = $1
GROUP BY r.id;
```

### Dependency Graph

Find what depends on a repository:

```sql
-- Repositories that depend on this one
SELECT
    r.id,
    r.name,
    r.url,
    d.dependency_type,
    d.version_constraint
FROM repo_dependencies d
JOIN repositories r ON d.source_repo_id = r.id
WHERE d.target_repo_id = $1
ORDER BY r.name;
```

### Learning from History

Find successful patterns:

```sql
-- Tasks similar to current one that succeeded
SELECT
    t.id,
    t.description,
    t.plan,
    t.result,
    f.feedback_type,
    1 - (
        (SELECT embedding FROM tasks WHERE id = t.id) <=> $1
    ) as similarity
FROM tasks t
LEFT JOIN feedback f ON f.task_id = t.id
WHERE t.target_repo_id = $2
  AND t.status = 'completed'
  AND (f.feedback_type IS NULL OR f.feedback_type = 'pr_merged')
ORDER BY similarity DESC
LIMIT 5;
```

---

## Indexing Pipeline

### Repository Indexing

```python
async def index_repository(self, repo_url: str) -> None:
    """Index a repository into the knowledge graph."""

    # 1. Clone or update
    repo_path = await self.git.clone_or_update(repo_url)

    # 2. Create/update repo record
    repo = await self.upsert_repository(repo_url)

    # 3. Index files
    for file_path in self.walk_files(repo_path):
        content = self.read_file(file_path)

        # Generate summary and embedding
        summary = await self.llm.summarize_file(content)
        embedding = await self.embed(f"{file_path}\n{summary}")

        await self.upsert_file(repo.id, file_path, summary, embedding)

    # 4. Extract symbols (language-specific)
    for file in await self.get_files(repo.id):
        symbols = await self.extract_symbols(file)
        for symbol in symbols:
            embedding = await self.embed(
                f"{symbol.kind} {symbol.name}: {symbol.signature}"
            )
            await self.upsert_symbol(file.id, symbol, embedding)

    # 5. Parse dependencies
    deps = await self.parse_dependencies(repo_path)
    await self.upsert_dependencies(repo.id, deps)

    # 6. Mark as ready
    await self.update_repo_status(repo.id, 'ready')
```

### Incremental Updates

```python
async def update_repository(self, repo_id: UUID) -> None:
    """Update only changed files."""

    repo = await self.get_repository(repo_id)

    # Get changed files since last index
    changed = await self.git.get_changed_files(
        repo.url,
        since=repo.last_indexed_at
    )

    for file_path, change_type in changed:
        if change_type == 'deleted':
            await self.delete_file(repo_id, file_path)
        else:
            await self.reindex_file(repo_id, file_path)
```

---

## Embedding Strategy

### Model Selection

Using OpenAI's `text-embedding-3-small` (1536 dimensions) or equivalent.

### What Gets Embedded

| Entity | Embedding Input |
|--------|-----------------|
| File | `{path}\n{summary}` |
| Symbol | `{kind} {name}: {signature}\n{documentation}` |
| Message | Full message content |
| Task | Task description |

### Batch Processing

```python
async def embed_batch(self, texts: list[str]) -> list[list[float]]:
    """Embed multiple texts efficiently."""
    # Batch up to 100 at a time
    embeddings = []
    for batch in chunks(texts, 100):
        result = await self.embedding_client.embed(batch)
        embeddings.extend(result)
    return embeddings
```

---

## Performance Considerations

### Index Maintenance

```sql
-- Reindex vector indexes periodically
REINDEX INDEX CONCURRENTLY idx_files_embedding;
REINDEX INDEX CONCURRENTLY idx_symbols_embedding;
```

### Query Optimization

```sql
-- Use approximate search with distance threshold
SELECT * FROM files
WHERE embedding <=> $1 < 0.5  -- Only reasonably similar
ORDER BY embedding <=> $1
LIMIT 10;
```

### Connection Pooling

```python
# Use connection pool for concurrent access
pool = asyncpg.create_pool(
    dsn=DATABASE_URL,
    min_size=5,
    max_size=20
)
```

---

## Backup Strategy

```bash
# Daily backup
pg_dump jarvis > /backups/jarvis-$(date +%Y%m%d).sql

# With compression
pg_dump jarvis | gzip > /backups/jarvis-$(date +%Y%m%d).sql.gz
```

---

## Related Documentation

- [Overview](overview.md) - System architecture
- [Events](events.md) - Event schemas
- [Agents](agents.md) - How agents use the knowledge graph
