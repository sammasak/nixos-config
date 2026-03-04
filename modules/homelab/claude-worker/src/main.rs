use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{
        sse::{Event, KeepAlive, Sse},
        IntoResponse,
    },
    routing::{get, put},
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
    api_key: String,
    goals_file: PathBuf,
    workspace_dir: PathBuf,
    logs_dir: PathBuf,
    claude_running: Mutex<bool>,
    log_tx: broadcast::Sender<String>,
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

    let api_key = env::var("CLAUDE_WORKER_API_KEY")
        .unwrap_or_else(|_| "a72a0859ceb97abfd1dac2ef6a890f79386974e6a133455b1cbbe9ca643f08ea".into());

    let (log_tx, _) = broadcast::channel::<String>(1024);

    let state = Arc::new(AppState {
        api_key,
        goals_file,
        workspace_dir,
        logs_dir,
        claude_running: Mutex::new(false),
        log_tx,
    });

    let app = Router::new()
        .route("/health", get(health))
        .route("/goals", get(list_goals).post(create_goal))
        .route("/goals/:id", put(update_goal))
        .route("/goals/:id/stream", get(stream_goal))
        .with_state(state);

    let addr = env::var("CLAUDE_WORKER_LISTEN").unwrap_or_else(|_| "0.0.0.0:4200".into());
    let listener = tokio::net::TcpListener::bind(&addr).await.expect("bind");
    eprintln!("claude-worker listening on {}", addr);
    axum::serve(listener, app).await.expect("serve");
}

// ── Handlers ─────────────────────────────────────────────────────────────────

async fn health() -> &'static str {
    "OK"
}

async fn list_goals(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Vec<Goal>>, StatusCode> {
    require_auth(&headers, &state.api_key)?;
    let goals = read_goals(&state.goals_file).await;
    Ok(Json(goals))
}

async fn create_goal(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(payload): Json<CreateGoal>,
) -> Result<impl IntoResponse, StatusCode> {
    require_auth(&headers, &state.api_key)?;

    let goal = Goal {
        id: Uuid::new_v4().to_string(),
        goal: payload.goal,
        status: GoalStatus::Pending,
        created_at: Utc::now().to_rfc3339(),
        started_at: None,
        completed_at: None,
        result: None,
    };

    let mut goals = read_goals(&state.goals_file).await;
    goals.push(goal.clone());
    write_goals(&state.goals_file, &goals).await;

    // Spawn claude if not already running
    maybe_spawn_claude(Arc::clone(&state)).await;

    Ok((StatusCode::CREATED, Json(goal)))
}

async fn update_goal(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(payload): Json<UpdateGoal>,
) -> Result<Json<Goal>, StatusCode> {
    require_auth(&headers, &state.api_key)?;

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
    write_goals(&state.goals_file, &goals).await;

    Ok(Json(updated))
}

async fn stream_goal(
    State(state): State<Arc<AppState>>,
    Path(_id): Path<String>,
    headers: HeaderMap,
) -> Result<Sse<impl Stream<Item = Result<Event, Infallible>>>, StatusCode> {
    require_auth(&headers, &state.api_key)?;

    let rx = state.log_tx.subscribe();
    let stream = BroadcastStream::new(rx).filter_map(|msg| {
        futures_util::future::ready(match msg {
            Ok(line) => Some(Ok(Event::default().data(line))),
            Err(_) => None,
        })
    });

    Ok(Sse::new(stream).keep_alive(KeepAlive::new().interval(Duration::from_secs(15))))
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

    let startup_prompt = "Begin autonomous work session. \
        Read /var/lib/claude-worker/goals.json, find the first pending goal, \
        update its status to in_progress, and work on it until done. \
        Follow all instructions in your CLAUDE.md.";

    let mut child = match tokio::process::Command::new("claude")
        .arg("-p")
        .arg(startup_prompt)
        .arg("--dangerously-skip-permissions")
        .arg("--output-format")
        .arg("stream-json")
        .current_dir(&state.workspace_dir)
        .env("HOME", state.workspace_dir.parent().unwrap_or(&state.workspace_dir))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
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
            let _ = log_file.write_all(line.as_bytes()).await;
            let _ = log_file.write_all(b"\n").await;
            let _ = log_tx.send(line);
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
    match child.wait().await {
        Ok(status) => eprintln!("claude exited with status: {}", status),
        Err(e) => eprintln!("claude wait error: {}", e),
    }
    let _ = stdout_done.await;
    let _ = state.log_tx.send("[DONE]".to_string());

    *state.claude_running.lock().await = false;
}

// ── Goals file helpers ────────────────────────────────────────────────────────

async fn read_goals(path: &PathBuf) -> Vec<Goal> {
    match fs::read_to_string(path).await {
        Ok(content) => serde_json::from_str(&content).unwrap_or_default(),
        Err(_) => vec![],
    }
}

async fn write_goals(path: &PathBuf, goals: &[Goal]) {
    let content = serde_json::to_string_pretty(goals).expect("serialize goals");
    fs::write(path, content).await.expect("write goals.json");
}

// ── Auth helper ───────────────────────────────────────────────────────────────

fn require_auth(headers: &HeaderMap, api_key: &str) -> Result<(), StatusCode> {
    let expected = format!("Bearer {}", api_key);
    let provided = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if provided == expected {
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}
