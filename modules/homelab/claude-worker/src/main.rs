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
use serde::{Deserialize, Serialize};
use std::{
    convert::Infallible,
    env,
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use tokio::{
    fs,
    io::{AsyncBufReadExt, BufReader},
    sync::{broadcast, Mutex},
};
use tokio_stream::wrappers::BroadcastStream;
use uuid::Uuid;

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

#[derive(Deserialize)]
struct CreateGoal {
    goal: String,
}

#[derive(Deserialize)]
struct UpdateGoal {
    status: Option<GoalStatus>,
    result: Option<String>,
}

// ── App state ───────────────────────────────────────────────────────────────

struct AppState {
    goals_file: PathBuf,
    workspace_dir: PathBuf,
    logs_dir: PathBuf,
    claude_running: Mutex<bool>,
    log_tx: broadcast::Sender<String>,
    goals_lock: Mutex<()>,
}

// ── Main ─────────────────────────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    let base = PathBuf::from(
        env::var("CLAUDE_WORKER_HOME").unwrap_or_else(|_| "/var/lib/claude-worker".into()),
    );
    let workspace_dir = base.join("workspace");
    let logs_dir = base.join("logs");
    let goals_file = base.join("goals.json");

    // Ensure directories exist
    fs::create_dir_all(&workspace_dir).await.expect("create workspace dir");
    fs::create_dir_all(&logs_dir).await.expect("create logs dir");

    // Initialise goals.json if missing
    if !goals_file.exists() {
        fs::write(&goals_file, "[]").await.expect("init goals.json");
    }

    let (log_tx, _) = broadcast::channel::<String>(1024);

    let state = Arc::new(AppState {
        goals_file,
        workspace_dir,
        logs_dir,
        claude_running: Mutex::new(false),
        log_tx,
        goals_lock: Mutex::new(()),
    });

    let app = Router::new()
        .route("/health", get(health))
        .route("/goals", get(list_goals).post(create_goal))
        .route("/goals/:id", put(update_goal))
        .route("/goals/:id/stream", get(stream_goal))
        .route("/events", post(post_event))
        .with_state(state);

    let addr = env::var("CLAUDE_WORKER_LISTEN").unwrap_or_else(|_| "127.0.0.1:4200".into());
    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    eprintln!("claude-worker listening on {}", addr);
    axum::serve(listener, app).await.expect("serve");
}

// ── Handlers ─────────────────────────────────────────────────────────────────

async fn health(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let goals = read_goals(&state.goals_file).await;
    let pending = goals.iter().filter(|g| g.status == GoalStatus::Pending).count();
    let in_progress = goals.iter().filter(|g| g.status == GoalStatus::InProgress).count();
    let claude_running = *state.claude_running.lock().await;
    Json(serde_json::json!({
        "status": "ok",
        "claude_running": claude_running,
        "pending_goals": pending,
        "in_progress_goals": in_progress,
    }))
}

async fn list_goals(
    State(state): State<Arc<AppState>>,
) -> Json<Vec<Goal>> {
    let goals = read_goals(&state.goals_file).await;
    Json(goals)
}

async fn create_goal(
    State(state): State<Arc<AppState>>,
    Json(payload): Json<CreateGoal>,
) -> Result<impl IntoResponse, StatusCode> {
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
    goals.push(goal.clone());
    if let Err(e) = write_goals(&state.goals_file, &goals).await {
        eprintln!("Failed to write goals.json: {}", e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    drop(_lock);

    // Spawn claude if not already running
    maybe_spawn_claude(Arc::clone(&state)).await;

    Ok((StatusCode::CREATED, Json(goal)))
}

async fn update_goal(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    Json(payload): Json<UpdateGoal>,
) -> Result<Json<Goal>, StatusCode> {
    let _lock = state.goals_lock.lock().await;
    let mut goals = read_goals(&state.goals_file).await;
    let goal = goals.iter_mut().find(|g| g.id == id).ok_or(StatusCode::NOT_FOUND)?;

    if let Some(status) = payload.status {
        let now = Utc::now().to_rfc3339();
        match &status {
            GoalStatus::InProgress => goal.started_at = Some(now),
            GoalStatus::Done | GoalStatus::Failed => goal.completed_at = Some(now),
            _ => {}
        }
        goal.status = status;
    }
    if let Some(result) = payload.result {
        goal.result = Some(result);
    }

    let updated = goal.clone();
    if let Err(e) = write_goals(&state.goals_file, &goals).await {
        eprintln!("Failed to write goals.json: {}", e);
        return Err(StatusCode::INTERNAL_SERVER_ERROR);
    }
    drop(_lock);

    Ok(Json(updated))
}

async fn stream_goal(
    State(state): State<Arc<AppState>>,
    Path(_id): Path<String>,
) -> Sse<impl Stream<Item = Result<Event, Infallible>>> {
    let rx = state.log_tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|msg| {
        futures_util::future::ready(match msg {
            Ok(line) if line.starts_with("HOOK:") => {
                let data = line["HOOK:".len()..].to_string();
                Some(Ok(Event::default().event("hook").data(data)))
            }
            Ok(line) => Some(Ok(Event::default().data(line))),
            Err(_) => None,
        })
    });

    Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15)))
}

async fn post_event(
    State(state): State<Arc<AppState>>,
    Json(body): Json<serde_json::Value>,
) -> StatusCode {
    let json = serde_json::to_string(&body).unwrap_or_default();
    let _ = state.log_tx.send(format!("HOOK:{}", json));
    StatusCode::NO_CONTENT
}

// ── Claude spawning ───────────────────────────────────────────────────────────

async fn maybe_spawn_claude(state: Arc<AppState>) {
    let mut running = state.claude_running.lock().await;
    if *running {
        return;
    }
    *running = true;
    drop(running);

    let state_clone = Arc::clone(&state);
    tokio::spawn(async move {
        run_claude(state_clone).await;
    });
}

/// Filter a single line from claude's stdout before broadcasting to SSE clients.
/// Returns None to suppress, Some(line) to broadcast.
fn filter_claude_line(line: &str) -> Option<String> {
    // Always pass through terminal signals
    if line == "[DONE]" || line.starts_with("[FAILED:") {
        return Some(line.to_string());
    }

    // Try to parse as JSON
    let Ok(mut val) = serde_json::from_str::<serde_json::Value>(line) else {
        // Non-JSON line (stderr noise, blank lines) — suppress
        return None;
    };

    // For assistant messages: keep only non-MCP tool_use blocks; suppress text blocks
    if val.get("type").and_then(|t| t.as_str()) == Some("assistant") {
        let has_content = val.pointer("/message/content").is_some();
        if !has_content {
            return None;
        }
        if let Some(content) = val
            .pointer_mut("/message/content")
            .and_then(|c| c.as_array_mut())
        {
            content.retain(|block| {
                block.get("type").and_then(|t| t.as_str()) == Some("tool_use")
                    && !block
                        .get("name")
                        .and_then(|n| n.as_str())
                        .unwrap_or("")
                        .starts_with("mcp__")
            });
            if content.is_empty() {
                return None; // No tool_use blocks worth showing — suppress
            }
        }
        return Some(serde_json::to_string(&val).unwrap_or_else(|_| line.to_string()));
    }

    // Pass through all other event types (result, system, tool, etc.)
    Some(serde_json::to_string(&val).unwrap_or_else(|_| line.to_string()))
}

async fn run_claude(state: Arc<AppState>) {
    let log_file_path = state.logs_dir.join("current.log");

    let goals_path = state.goals_file.display().to_string();
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
    cmd.current_dir(&state.workspace_dir)
        .env("HOME", state.workspace_dir.parent().unwrap_or(&state.workspace_dir))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = match cmd.spawn()
    {
        Ok(child) => child,
        Err(e) => {
            eprintln!("Failed to spawn claude: {}", e);
            *state.claude_running.lock().await = false;
            return;
        }
    };

    // Stream stdout to log file + broadcast channel
    let stdout = child.stdout.take().expect("piped stdout");
    let log_tx = state.log_tx.clone();
    let log_path = log_file_path.clone();

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
            // Always log the raw line for debugging
            let _ = log_file.write_all(line.as_bytes()).await;
            let _ = log_file.write_all(b"\n").await;
            // Only broadcast filtered output to SSE clients
            if let Some(filtered) = filter_claude_line(&line) {
                let _ = log_tx.send(filtered);
            }
        }
    });

    // Stream stderr to log file as well
    let stderr = child.stderr.take().expect("piped stderr");
    let log_path2 = log_file_path.clone();
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
            eprintln!("claude exited successfully");
            "[DONE]".to_string()
        }
        Ok(status) => {
            eprintln!("claude exited with status: {}", status);
            format!("[FAILED:{}]", status.code().unwrap_or(-1))
        }
        Err(e) => {
            eprintln!("claude wait error: {}", e);
            format!("[FAILED:{}]", e)
        }
    };
    let _ = stdout_done.await;
    let _ = state.log_tx.send(done_msg);

    *state.claude_running.lock().await = false;
}

// ── Goals file helpers ────────────────────────────────────────────────────────

async fn read_goals(path: &PathBuf) -> Vec<Goal> {
    match fs::read_to_string(path).await {
        Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
        Err(_) => vec![],
    }
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
