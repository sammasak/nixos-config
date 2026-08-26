mod metrics;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
    routing::{get, post, put},
    Json, Router,
};
use chrono::Utc;
use futures_util::{stream::Stream, StreamExt};
use metrics::WorkerMetrics;
use serde::{Deserialize, Serialize};
use std::{
    convert::Infallible,
    env,
    os::unix::fs::PermissionsExt,
    path::{Path as StdPath, PathBuf},
    process::Stdio,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use std::collections::VecDeque;
use tokio::{
    fs,
    io::{AsyncBufReadExt, BufReader},
    sync::{broadcast, Mutex},
};
use tokio_stream::wrappers::BroadcastStream;
use tracing::{error, info, instrument, warn};
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use uuid::Uuid;

// ── Error types ──────────────────────────────────────────────────────────────

#[derive(thiserror::Error, Debug)]
enum WorkerError {
    #[error("failed to read goals file: {0}")]
    GoalsRead(#[source] std::io::Error),
    #[error("failed to write goals file: {0}")]
    GoalsWrite(#[source] std::io::Error),
    #[error("failed to spawn claude process: {0}")]
    ClaudeSpawn(#[source] std::io::Error),
    #[error("goal not found")]
    GoalNotFound,
}

impl axum::response::IntoResponse for WorkerError {
    fn into_response(self) -> axum::response::Response {
        let (status, message) = match &self {
            WorkerError::GoalNotFound => (StatusCode::NOT_FOUND, self.to_string()),
            _ => (StatusCode::INTERNAL_SERVER_ERROR, self.to_string()),
        };
        (status, message).into_response()
    }
}

// ── Goal types ──────────────────────────────────────────────────────────────

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum GoalStatus {
    Pending,
    InProgress,
    Done,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Goal {
    id: String,
    goal: String,
    status: GoalStatus,
    created_at: String,
    started_at: Option<String>,
    completed_at: Option<String>,
    #[serde(default)]
    reviewed_at: Option<String>,
    result: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateGoal {
    goal: String,
}

#[derive(Debug, Deserialize)]
struct UpdateGoal {
    status: Option<GoalStatus>,
    result: Option<String>,
}

// ── App state ───────────────────────────────────────────────────────────────

const REPLAY_BUFFER_SIZE: usize = 200;
const MAX_QUEUE_DEPTH: usize = 50;
const ARCHIVE_AFTER_DAYS: i64 = 7;

struct AppState {
    goals_file: PathBuf,
    workspace_dir: PathBuf,
    logs_dir: PathBuf,
    claude_running: Arc<AtomicBool>,
    log_tx: broadcast::Sender<String>,
    goals_lock: Mutex<()>,
    /// Rolling buffer of recent broadcast events for replay to late-joining SSE clients.
    replay_buffer: Mutex<VecDeque<String>>,
    metrics: Arc<WorkerMetrics>,
    queue_depth: Arc<AtomicU64>,
}

// ── Router builder (for testability) ─────────────────────────────────────────

fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/goals", get(list_goals).post(create_goal))
        .route("/goals/:id", put(update_goal))
        .route("/goals/:id/stream", get(stream_goal))
        .route("/events", post(post_event))
        .with_state(state)
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize OTel tracer for traces
    let otel_endpoint = env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
        .unwrap_or_else(|_| "http://192.168.10.204:4318".into());

    // Initialize tracing subscriber with JSON formatting
    tracing_subscriber::registry()
        .with(tracing_subscriber::fmt::layer().json())
        .with(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let base = PathBuf::from(
        env::var("CLAUDE_WORKER_HOME").unwrap_or_else(|_| "/var/lib/claude-worker".into()),
    );
    let workspace_dir = base.join("workspace");
    let logs_dir = base.join("logs");
    let goals_file = base.join("goals.json");

    // Ensure directories exist
    fs::create_dir_all(&workspace_dir).await?;
    fs::create_dir_all(&logs_dir).await?;

    // Initialise goals.json if missing
    if !goals_file.exists() {
        fs::write(&goals_file, "[]").await?;
    }

    let (log_tx, _) = broadcast::channel::<String>(1024);

    // Initialise OTLP metrics
    // Keep alive for the duration of main() — dropping shuts down OTLP export.
    let metrics_provider = crate::metrics::init(&otel_endpoint);
    let worker_metrics = Arc::new(crate::metrics::create_metrics());

    // Shared queue depth counter — updated on every goal write and observed by gauge
    let queue_depth = Arc::new(AtomicU64::new(0));

    // Register observable gauge for queue depth
    {
        let meter = opentelemetry::global::meter("claude-worker");
        let gauge_queue = Arc::clone(&queue_depth);
        meter
            .u64_observable_gauge("claude_worker_goal_queue_depth")
            .with_description("Number of goals currently pending")
            .with_callback(move |observer| {
                observer.observe(gauge_queue.load(Ordering::Relaxed), &[]);
            })
            .build();
    }

    let state = Arc::new(AppState {
        goals_file,
        workspace_dir,
        logs_dir,
        claude_running: Arc::new(AtomicBool::new(false)),
        log_tx,
        goals_lock: Mutex::new(()),
        replay_buffer: Mutex::new(VecDeque::with_capacity(REPLAY_BUFFER_SIZE)),
        metrics: worker_metrics,
        queue_depth,
    });

    let app = build_router(Arc::clone(&state));

    let addr = env::var("CLAUDE_WORKER_LISTEN").unwrap_or_else(|_| "127.0.0.1:4200".into());
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!(addr = %addr, "claude-worker listening");
    axum::serve(listener, app).await?;
    drop(metrics_provider);
    Ok(())
}

// ── Handlers ─────────────────────────────────────────────────────────────────

#[instrument(skip(state))]
async fn health(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let goals = read_goals(&state.goals_file).await;
    let pending = goals.iter().filter(|g| g.status == GoalStatus::Pending).count();
    let in_progress = goals.iter().filter(|g| g.status == GoalStatus::InProgress).count();
    let claude_running = state.claude_running.load(Ordering::SeqCst);
    Json(serde_json::json!({
        "status": "ok",
        "claude_running": claude_running,
        "pending_goals": pending,
        "in_progress_goals": in_progress,
    }))
}

#[instrument(skip(state))]
async fn list_goals(
    State(state): State<Arc<AppState>>,
) -> Json<Vec<Goal>> {
    let goals = read_goals(&state.goals_file).await;
    Json(goals)
}

#[instrument(skip(state))]
async fn create_goal(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateGoal>,
) -> Result<impl IntoResponse, WorkerError> {
    let goal = Goal {
        id: Uuid::new_v4().to_string(),
        goal: payload.goal,
        status: GoalStatus::Pending,
        created_at: Utc::now().to_rfc3339(),
        started_at: None,
        completed_at: None,
        reviewed_at: None,
        result: None,
    };

    let _lock = state.goals_lock.lock().await;
    let mut goals = read_goals(&state.goals_file).await;

    let pending_count = goals.iter().filter(|g| g.status == GoalStatus::Pending).count();
    if pending_count >= MAX_QUEUE_DEPTH {
        warn!(pending = pending_count, "Queue full, rejecting new goal");
        return Ok((
            StatusCode::TOO_MANY_REQUESTS,
            axum::Json(serde_json::json!({
                "error": "queue full",
                "pending": pending_count,
            })),
        ).into_response());
    }

    goals.push(goal.clone());
    if let Err(e) = write_goals(&state.goals_file, &goals).await {
        error!(error = %e, "Failed to write goals.json");
        return Err(WorkerError::GoalsWrite(e));
    }
    let pending = goals.iter().filter(|g| g.status == GoalStatus::Pending).count();
    drop(_lock);
    state.queue_depth.store(pending as u64, Ordering::Relaxed);

    info!(goal_id = %goal.id, "Goal created");

    // Spawn claude if not already running
    maybe_spawn_claude(Arc::clone(&state)).await;

    Ok((StatusCode::CREATED, Json(goal)).into_response())
}

#[instrument(skip(state))]
async fn update_goal(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<UpdateGoal>,
) -> Result<Json<Goal>, WorkerError> {
    let _lock = state.goals_lock.lock().await;
    let mut goals = read_goals(&state.goals_file).await;
    let goal = goals.iter_mut().find(|g| g.id == id).ok_or(WorkerError::GoalNotFound)?;

    let mut record_done = false;
    let mut record_failed = false;
    let mut started_at_snapshot: Option<String> = None;

    if let Some(status) = payload.status {
        let now = Utc::now().to_rfc3339();
        match &status {
            GoalStatus::InProgress => goal.started_at = Some(now),
            GoalStatus::Done => {
                goal.completed_at = Some(now);
                record_done = true;
                started_at_snapshot = goal.started_at.clone();
            }
            GoalStatus::Failed => {
                goal.completed_at = Some(now);
                record_failed = true;
                started_at_snapshot = goal.started_at.clone();
            }
            _ => {}
        }
        goal.status = status;
    }
    if let Some(result) = payload.result {
        goal.result = Some(result);
    }

    let updated = goal.clone();
    let goals_file = state.goals_file.clone();
    if let Err(e) = write_goals(&goals_file, &goals).await {
        error!(error = %e, goal_id = %id, "Failed to write goals.json");
        return Err(WorkerError::GoalsWrite(e));
    }
    let pending = goals.iter().filter(|g| g.status == GoalStatus::Pending).count();
    drop(_lock);
    state.queue_depth.store(pending as u64, Ordering::Relaxed);

    // Record metrics for terminal state transitions
    if record_done || record_failed {
        if let Some(elapsed) = started_at_snapshot
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|start| {
                (Utc::now() - start.with_timezone(&Utc))
                    .num_milliseconds()
                    .max(0) as f64
                    / 1000.0
            })
        {
            state.metrics.goal_duration_seconds.record(elapsed, &[]);
        }
        if record_done {
            state.metrics.goals_completed_total.add(1, &[]);
            info!(goal_id = %id, "Goal completed");

            // Archive old goals after each completion
            let goals_file_for_archive = state.goals_file.clone();
            tokio::spawn(async move {
                if let Err(e) = archive_old_goals(&goals_file_for_archive).await {
                    warn!(error = %e, "Failed to archive old goals");
                }
            });
        } else {
            state.metrics.goals_failed_total.add(1, &[]);
            warn!(goal_id = %id, "Goal failed");
        }
    }

    Ok(Json(updated))
}

/// RAII guard that decrements the SSE active connections counter on drop.
struct SseGuard(Arc<AppState>);
impl Drop for SseGuard {
    fn drop(&mut self) {
        self.0.metrics.sse_connections_active.add(-1, &[]);
    }
}

#[instrument(skip(state))]
async fn stream_goal(
    State(state): State<Arc<AppState>>,
    Path(_id): Path<String>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    // Track active SSE connections — guard decrements when stream is dropped
    state.metrics.sse_connections_active.add(1, &[]);
    let guard = SseGuard(Arc::clone(&state));

    // Snapshot the replay buffer so late-joining clients get history
    let buffered: Vec<String> = {
        let buf = state.replay_buffer.lock().await;
        buf.iter().cloned().collect()
    };
    let rx = state.log_tx.subscribe();

    fn line_to_event(line: String) -> Option<Result<Event, Infallible>> {
        if line.starts_with("HOOK:") {
            let data = line["HOOK:".len()..].to_string();
            Some(Ok(Event::default().event("hook").data(data)))
        } else {
            Some(Ok(Event::default().data(line)))
        }
    }

    let replay_stream = futures_util::stream::iter(
        buffered.into_iter().filter_map(line_to_event)
    );
    // Move the guard into the live stream closure so it lives until the stream is dropped.
    let live_stream = BroadcastStream::new(rx).filter_map(move |msg| {
        let _guard = &guard; // keep guard alive in this closure
        futures_util::future::ready(match msg {
            Ok(line) => line_to_event(line),
            Err(_) => None,
        })
    });
    let combined = replay_stream.chain(live_stream);

    Sse::new(combined).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

async fn post_event(
    State(state): State<Arc<AppState>>,
    Json(body): Json<serde_json::Value>,
) -> StatusCode {
    let json = serde_json::to_string(&body).unwrap_or_default();
    let msg = format!("HOOK:{}", json);
    // Push to replay buffer so late-joining SSE clients get progress history
    {
        let mut buf = state.replay_buffer.lock().await;
        if buf.len() >= REPLAY_BUFFER_SIZE {
            buf.pop_front();
        }
        buf.push_back(msg.clone());
    }
    let _ = state.log_tx.send(msg);
    StatusCode::NO_CONTENT
}

// ── Claude spawning ───────────────────────────────────────────────────────────

async fn maybe_spawn_claude(state: Arc<AppState>) {
    if state.claude_running
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }

    let state_clone = Arc::clone(&state);
    tokio::spawn(async move {
        run_claude(state_clone).await;
    });
}

#[instrument(skip(state))]
async fn run_claude(state: Arc<AppState>) {
    let log_file_path = state.logs_dir.join("current.log");

    write_report_script().await;

    let mut child = match spawn_claude_process(&state.workspace_dir, &state.goals_file) {
        Ok(c) => c,
        Err(e) => {
            error!(error = %e, "Failed to spawn claude process");
            state.claude_running.store(false, Ordering::SeqCst);
            return;
        }
    };

    let done_msg = stream_output_to_log_and_wait(&mut child, &log_file_path, &state).await;

    // Push done signal to replay buffer so page reloads after completion see it
    {
        let mut buf = state.replay_buffer.lock().await;
        if buf.len() >= REPLAY_BUFFER_SIZE {
            buf.pop_front();
        }
        buf.push_back(done_msg.clone());
    }
    let _ = state.log_tx.send(done_msg);

    state.claude_running.store(false, Ordering::SeqCst);
}

// ── Claude process helpers ────────────────────────────────────────────────────

async fn write_report_script() {
    // Write /usr/local/bin/report so Claude can call it from any subshell without
    // re-defining a bash function. Uses jq for safe JSON construction (handles
    // quotes, backslashes, and other special characters in the message).
    const REPORT_SCRIPT: &str = "#!/bin/sh\n\
msg=$(printf '%s' \"$1\" | jq -Rs .)\n\
curl -sf -X POST \"http://localhost:4200/events\" \\\n\
  -H \"Content-Type: application/json\" \\\n\
  -d \"{\\\"type\\\":\\\"progress\\\",\\\"message\\\":${msg}}\" \\\n\
  --max-time 5 -o /dev/null 2>/dev/null || echo \"WARN: report failed - activity not visible to user\" >&2\n";
    fs::create_dir_all("/usr/local/bin").await.ok();
    if let Err(e) = fs::write("/usr/local/bin/report", REPORT_SCRIPT).await {
        warn!(error = %e, "Failed to write /usr/local/bin/report");
    } else {
        let perms = std::fs::Permissions::from_mode(0o755);
        if let Err(e) = fs::set_permissions("/usr/local/bin/report", perms).await {
            warn!(error = %e, "Failed to chmod /usr/local/bin/report");
        }
    }
}

fn spawn_claude_process(workspace_dir: &StdPath, goals_file: &StdPath) -> Result<tokio::process::Child, WorkerError> {
    let goals_path = goals_file.display().to_string();
    let startup_prompt = format!(
        "Begin autonomous work session. Check {goals_path} for any in_progress goal \
        first (resume it if found), otherwise find the first pending goal, mark it \
        in_progress using `jq`, and work on it until complete. \
        Follow all instructions in your CLAUDE.md.",
        goals_path = goals_path
    );

    // Pass playwright MCP config explicitly — SDK mode (claude -p) skips
    // settings.json mcpServers; --mcp-config is the only way to inject stdio servers.
    let mcp_config_path = "/etc/workstation/mcp-config.json";
    let has_mcp_config = std::path::Path::new(mcp_config_path).exists();

    let mut cmd = tokio::process::Command::new("claude");
    cmd.arg("-p")
        .arg(&startup_prompt)
        .arg("--dangerously-skip-permissions")
        .arg("--verbose")
        .arg("--output-format")
        .arg("stream-json");
    if has_mcp_config {
        cmd.arg("--mcp-config").arg(mcp_config_path);
    }
    let parent_dir = workspace_dir.parent().unwrap_or(workspace_dir);
    cmd.current_dir(workspace_dir)
        .env("HOME", parent_dir)
        .env("PATH", format!("/usr/local/bin:{}", std::env::var("PATH").unwrap_or_default()))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let span = tracing::info_span!("claude_invocation");
    let _enter = span.enter();

    cmd.spawn().map_err(WorkerError::ClaudeSpawn)
}

async fn stream_output_to_log_and_wait(
    child: &mut tokio::process::Child,
    log_file_path: &StdPath,
    state: &Arc<AppState>,
) -> String {
    // Stream stdout: write every line to the log file.
    // Activity reporting is handled exclusively by the PreToolUse report-activity.sh
    // hook via POST /events — forwarding raw tool_use JSON here would produce
    // duplicate, lower-quality items alongside the hook's authoritative messages.
    let stdout = child.stdout.take().expect("piped stdout");
    let log_path = log_file_path.to_path_buf();
    let stdout_tx = state.log_tx.clone();
    let stdout_replay = Arc::clone(state);

    let stdout_done = tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        let mut log_file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .await
            .expect("open log file");

        let mut reader = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            let _ = log_file.write_all(line.as_bytes()).await;
            let _ = log_file.write_all(b"\n").await;

            let _ = &stdout_tx;        // keep sender alive until loop exits
            let _ = &stdout_replay;    // keep Arc alive for potential future reuse
        }
    });

    // Stream stderr to log file as well
    let stderr = child.stderr.take().expect("piped stderr");
    let log_path2 = log_file_path.to_path_buf();
    tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        let mut log_file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path2)
            .await
            .expect("open log file for stderr");

        let mut reader = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = reader.next_line().await {
            let _ = log_file.write_all(b"[stderr] ").await;
            let _ = log_file.write_all(line.as_bytes()).await;
            let _ = log_file.write_all(b"\n").await;
        }
    });

    // Wait for claude to finish, then drain stdout before signalling watchers
    let exit_status = child.wait().await;
    let done_msg = match exit_status {
        Ok(status) if status.success() => {
            info!("claude exited successfully");
            "[DONE]".to_string()
        }
        Ok(status) => {
            warn!(code = ?status.code(), "claude exited with non-zero status");
            format!("[FAILED:{}]", status.code().unwrap_or(-1))
        }
        Err(e) => {
            error!(error = %e, "claude wait error");
            format!("[FAILED:{}]", e)
        }
    };
    let _ = stdout_done.await;
    done_msg
}

// ── Goals archival ────────────────────────────────────────────────────────────

async fn archive_old_goals(goals_file: &StdPath) -> Result<(), WorkerError> {
    let goals = read_goals_from_path(goals_file).await
        .map_err(WorkerError::GoalsRead)?;

    let cutoff = Utc::now() - chrono::Duration::days(ARCHIVE_AFTER_DAYS);

    let (recent, old): (Vec<Goal>, Vec<Goal>) = goals.into_iter().partition(|g| {
        // Keep pending and in_progress regardless of age
        if g.status == GoalStatus::Pending || g.status == GoalStatus::InProgress {
            return true;
        }
        // Keep completed/failed goals that are newer than cutoff
        g.completed_at
            .as_deref()
            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.with_timezone(&Utc) > cutoff)
            .unwrap_or(true) // if no completed_at, keep it
    });

    if old.is_empty() {
        return Ok(());
    }

    // Write recent back to goals_file via atomic rename
    let content = serde_json::to_string_pretty(&recent)
        .map_err(|e| WorkerError::GoalsWrite(std::io::Error::new(std::io::ErrorKind::InvalidData, e)))?;
    let tmp = goals_file.with_extension("json.tmp");
    fs::write(&tmp, &content).await.map_err(WorkerError::GoalsWrite)?;
    fs::rename(&tmp, goals_file).await.map_err(WorkerError::GoalsWrite)?;

    // Append old to goals.archive.json
    let archive_file = goals_file.with_file_name("goals.archive.json");
    let mut existing_archive: Vec<Goal> = if archive_file.exists() {
        match fs::read_to_string(&archive_file).await {
            Ok(c) => serde_json::from_str(&c).unwrap_or_default(),
            Err(_) => vec![],
        }
    } else {
        vec![]
    };
    existing_archive.extend(old);

    let archive_content = serde_json::to_string_pretty(&existing_archive)
        .map_err(|e| WorkerError::GoalsWrite(std::io::Error::new(std::io::ErrorKind::InvalidData, e)))?;
    let archive_tmp = archive_file.with_extension("archive.json.tmp");
    fs::write(&archive_tmp, &archive_content).await.map_err(WorkerError::GoalsWrite)?;
    fs::rename(&archive_tmp, &archive_file).await.map_err(WorkerError::GoalsWrite)?;

    info!(archived = existing_archive.len(), "Archived old goals");
    Ok(())
}

// ── Claude stream filter ─────────────────────────────────────────────────────

/// Decide whether a line from Claude's stream-json stdout should be forwarded
/// to SSE clients.
///
/// Rules:
/// - `tool_use` events for Write / Edit / MultiEdit / NotebookEdit / Bash → allow
/// - All other `tool_use` events (MCP tools, etc.) → suppress
/// - Text / thinking content blocks → suppress
/// - Everything else (e.g. `result`, `message_start`) → suppress
///
/// Returns `Some(line)` if the line should be broadcast, `None` to suppress.
#[allow(dead_code)]
fn filter_claude_line(line: &str) -> Option<String> {
    // Fast path: must start with '{' to be a JSON object worth parsing
    let trimmed = line.trim();
    if !trimmed.starts_with('{') {
        return None;
    }

    // Parse the JSON — if it fails, drop the line
    let v: serde_json::Value = match serde_json::from_str(trimmed) {
        Ok(v) => v,
        Err(_) => return None,
    };

    // Only forward tool_use events for the allowed set of tools
    if v.get("type").and_then(|t| t.as_str()) == Some("tool_use") {
        const ALLOWED: &[&str] = &["Write", "Edit", "MultiEdit", "NotebookEdit", "Bash"];
        let name = v.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if ALLOWED.contains(&name) {
            return Some(line.to_string());
        }
    }

    // Everything else is suppressed
    None
}

// ── Goals file helpers ────────────────────────────────────────────────────────

async fn read_goals(path: &PathBuf) -> Vec<Goal> {
    read_goals_from_path(path.as_path()).await.unwrap_or_default()
}

async fn read_goals_from_path(path: &StdPath) -> Result<Vec<Goal>, std::io::Error> {
    let content = fs::read_to_string(path).await?;
    Ok(serde_json::from_str(&content).unwrap_or_default())
}

async fn write_goals(path: &PathBuf, goals: &[Goal]) -> Result<(), std::io::Error> {
    let content = serde_json::to_string_pretty(goals).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, e)
    })?;
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, &content).await?;
    fs::rename(&tmp, path).await?;
    Ok(())
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use tempfile::TempDir;
    use tower::ServiceExt;

    fn build_test_state(dir: &TempDir) -> Arc<AppState> {
        let goals_file = dir.path().join("goals.json");
        let workspace_dir = dir.path().join("workspace");
        let logs_dir = dir.path().join("logs");
        let (log_tx, _) = broadcast::channel::<String>(1024);

        // Write empty goals file
        std::fs::write(&goals_file, "[]").unwrap();

        // Initialize a no-op metrics provider (no OTLP endpoint in tests)
        let worker_metrics = Arc::new(crate::metrics::create_metrics());

        Arc::new(AppState {
            goals_file,
            workspace_dir,
            logs_dir,
            claude_running: Arc::new(AtomicBool::new(false)),
            log_tx,
            goals_lock: Mutex::new(()),
            replay_buffer: Mutex::new(VecDeque::with_capacity(REPLAY_BUFFER_SIZE)),
            metrics: worker_metrics,
            queue_depth: Arc::new(AtomicU64::new(0)),
        })
    }

    async fn post_goal(app: Router, goal_text: &str) -> axum::response::Response {
        let body = serde_json::json!({ "goal": goal_text }).to_string();
        app.oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/goals")
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn test_health_returns_200() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);
        let app = build_router(state);
        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_get_goals_empty() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);
        let app = build_router(state);
        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/goals")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let goals: Vec<Goal> = serde_json::from_slice(&body).unwrap();
        assert!(goals.is_empty());
    }

    #[tokio::test]
    async fn test_create_goal_writes_to_file() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);
        let goals_file = state.goals_file.clone();
        let app = build_router(state);

        let response = post_goal(app, "Test goal alpha").await;
        assert_eq!(response.status(), StatusCode::CREATED);

        let goals: Vec<Goal> = serde_json::from_str(
            &std::fs::read_to_string(&goals_file).unwrap()
        ).unwrap();
        assert_eq!(goals.len(), 1);
        assert_eq!(goals[0].goal, "Test goal alpha");
        assert_eq!(goals[0].status, GoalStatus::Pending);
    }

    #[tokio::test]
    async fn test_concurrent_goal_writes() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);
        let goals_file = state.goals_file.clone();

        let mut handles = vec![];
        for i in 0..5 {
            let state_clone = Arc::clone(&state);
            handles.push(tokio::spawn(async move {
                let _lock = state_clone.goals_lock.lock().await;
                let mut goals = read_goals(&state_clone.goals_file).await;
                goals.push(Goal {
                    id: Uuid::new_v4().to_string(),
                    goal: format!("concurrent goal {i}"),
                    status: GoalStatus::Pending,
                    created_at: Utc::now().to_rfc3339(),
                    started_at: None,
                    completed_at: None,
                    reviewed_at: None,
                    result: None,
                });
                write_goals(&state_clone.goals_file, &goals).await.unwrap();
            }));
        }
        for h in handles {
            h.await.unwrap();
        }

        let goals: Vec<Goal> = serde_json::from_str(
            &std::fs::read_to_string(&goals_file).unwrap()
        ).unwrap();
        assert_eq!(goals.len(), 5, "Expected exactly 5 goals, got {}", goals.len());
    }

    #[tokio::test]
    async fn test_queue_depth_limit() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);

        // POST 50 goals — all should succeed
        for i in 0..MAX_QUEUE_DEPTH {
            let app = build_router(Arc::clone(&state));
            let response = post_goal(app, &format!("goal {i}")).await;
            assert_eq!(
                response.status(),
                StatusCode::CREATED,
                "Goal {i} should be accepted"
            );
        }

        // 51st goal should be rejected with 429
        let app = build_router(Arc::clone(&state));
        let response = post_goal(app, "overflow goal").await;
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);

        let body = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["error"], "queue full");
    }

    #[tokio::test]
    async fn test_archive_old_goals() {
        let dir = TempDir::new().unwrap();
        let goals_file = dir.path().join("goals.json");

        let old_time = (Utc::now() - chrono::Duration::days(8)).to_rfc3339();
        let goals = vec![
            Goal {
                id: "old-1".to_string(),
                goal: "old completed goal".to_string(),
                status: GoalStatus::Done,
                created_at: old_time.clone(),
                started_at: Some(old_time.clone()),
                completed_at: Some(old_time.clone()),
                reviewed_at: None,
                result: Some("done".to_string()),
            },
            Goal {
                id: "new-1".to_string(),
                goal: "pending goal".to_string(),
                status: GoalStatus::Pending,
                created_at: Utc::now().to_rfc3339(),
                started_at: None,
                completed_at: None,
                reviewed_at: None,
                result: None,
            },
        ];
        std::fs::write(&goals_file, serde_json::to_string_pretty(&goals).unwrap()).unwrap();

        archive_old_goals(&goals_file).await.unwrap();

        // goals.json should only have the pending goal
        let remaining: Vec<Goal> = serde_json::from_str(
            &std::fs::read_to_string(&goals_file).unwrap()
        ).unwrap();
        assert_eq!(remaining.len(), 1);
        assert_eq!(remaining[0].id, "new-1");

        // goals.archive.json should have the old completed goal
        let archive_file = goals_file.with_file_name("goals.archive.json");
        let archived: Vec<Goal> = serde_json::from_str(
            &std::fs::read_to_string(&archive_file).unwrap()
        ).unwrap();
        assert_eq!(archived.len(), 1);
        assert_eq!(archived[0].id, "old-1");
    }

    #[tokio::test]
    async fn test_goal_not_found_returns_404() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);
        let app = build_router(state);

        let response = app
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri("/goals/nonexistent-id")
                    .header("content-type", "application/json")
                    .body(Body::from(r#"{"status":"done"}"#))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_update_goal_status() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);

        // Create a goal
        let create_response = post_goal(build_router(Arc::clone(&state)), "Status test goal").await;
        assert_eq!(create_response.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(create_response.into_body(), usize::MAX)
            .await
            .unwrap();
        let created_goal: Goal = serde_json::from_slice(&body).unwrap();
        let goal_id = created_goal.id;

        // Update its status to Done
        let update_body = serde_json::json!({"status": "done"}).to_string();
        let update_response = build_router(Arc::clone(&state))
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri(format!("/goals/{goal_id}"))
                    .header("content-type", "application/json")
                    .body(Body::from(update_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(update_response.status(), StatusCode::OK);

        // GET /goals and confirm status is done
        let list_response = build_router(Arc::clone(&state))
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/goals")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let list_body = axum::body::to_bytes(list_response.into_body(), usize::MAX)
            .await
            .unwrap();
        let goals: Vec<Goal> = serde_json::from_slice(&list_body).unwrap();
        let updated = goals.iter().find(|g| g.id == goal_id).unwrap();
        assert_eq!(updated.status, GoalStatus::Done);
    }

    #[tokio::test]
    async fn test_sse_replay_buffer_bounded() {
        let dir = TempDir::new().unwrap();
        let state = build_test_state(&dir);

        // Fill the replay buffer beyond capacity
        {
            let mut buf = state.replay_buffer.lock().await;
            for i in 0..(REPLAY_BUFFER_SIZE + 10) {
                if buf.len() >= REPLAY_BUFFER_SIZE {
                    buf.pop_front();
                }
                buf.push_back(format!("event {i}"));
            }
        }

        let buf = state.replay_buffer.lock().await;
        assert_eq!(buf.len(), REPLAY_BUFFER_SIZE);
        // The first 10 should have been evicted; buffer starts at event 10
        assert_eq!(buf.front().unwrap(), "event 10");
    }
}
