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
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::Duration,
};
use std::collections::VecDeque;
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

const REPLAY_BUFFER_SIZE: usize = 200;

struct AppState {
    goals_file: PathBuf,
    workspace_dir: PathBuf,
    logs_dir: PathBuf,
    claude_running: Mutex<bool>,
    log_tx: broadcast::Sender<String>,
    goals_lock: Mutex<()>,
    /// Rolling buffer of recent broadcast events for replay to late-joining SSE clients.
    replay_buffer: Mutex<VecDeque<String>>,
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
        replay_buffer: Mutex::new(VecDeque::with_capacity(REPLAY_BUFFER_SIZE)),
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
    let live_stream = BroadcastStream::new(rx).filter_map(|msg| {
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

    // Write /usr/local/bin/report so Claude can call it from any subshell without
    // re-defining a bash function. Uses jq for safe JSON construction (handles
    // quotes, backslashes, and other special characters in the message).
    const REPORT_SCRIPT: &str = "#!/bin/sh\n\
msg=$(printf '%s' \"$1\" | jq -Rs .)\n\
curl -sf -X POST \"http://localhost:4200/events\" \\\n\
  -H \"Content-Type: application/json\" \\\n\
  -d \"{\\\"type\\\":\\\"progress\\\",\\\"message\\\":${msg}}\" \\\n\
  --max-time 1 -o /dev/null 2>/dev/null || true\n";
    fs::create_dir_all("/usr/local/bin").await.ok();
    if let Err(e) = fs::write("/usr/local/bin/report", REPORT_SCRIPT).await {
        eprintln!("Warning: failed to write /usr/local/bin/report: {}", e);
    } else {
        let perms = std::fs::Permissions::from_mode(0o755);
        if let Err(e) = fs::set_permissions("/usr/local/bin/report", perms).await {
            eprintln!("Warning: failed to chmod /usr/local/bin/report: {}", e);
        }
    }

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
        .env("PATH", format!("/usr/local/bin:{}", std::env::var("PATH").unwrap_or_default()))
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

    // Stream stdout to log file only — progress events come via POST /events
    let stdout = child.stdout.take().expect("piped stdout");
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
            let _ = log_file.write_all(line.as_bytes()).await;
            let _ = log_file.write_all(b"\n").await;
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
    // Push done signal to replay buffer so page reloads after completion see it
    {
        let mut buf = state.replay_buffer.lock().await;
        if buf.len() >= REPLAY_BUFFER_SIZE {
            buf.pop_front();
        }
        buf.push_back(done_msg.clone());
    }
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
