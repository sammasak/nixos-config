use opentelemetry::{global, metrics::Meter, KeyValue};
use opentelemetry_otlp::{Protocol, WithExportConfig};
use opentelemetry_sdk::{
    metrics::SdkMeterProvider,
    Resource,
};
use std::time::Duration;

pub struct WorkerMetrics {
    pub goals_completed_total: opentelemetry::metrics::Counter<u64>,
    pub goals_failed_total: opentelemetry::metrics::Counter<u64>,
    pub goal_duration_seconds: opentelemetry::metrics::Histogram<f64>,
    pub sse_connections_active: opentelemetry::metrics::UpDownCounter<i64>,
}

/// Initialise the OTLP metrics provider. Returns the provider (must be kept alive).
pub fn init(otel_endpoint: &str) -> SdkMeterProvider {
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .with_endpoint(format!("{}/v1/metrics", otel_endpoint))
        .with_timeout(Duration::from_secs(5))
        .build()
        .expect("failed to build OTLP metric exporter");

    let resource = Resource::builder()
        .with_attribute(KeyValue::new("service.name", "claude-worker"))
        .build();

    let provider = SdkMeterProvider::builder()
        .with_periodic_exporter(exporter)
        .with_resource(resource)
        .build();

    global::set_meter_provider(provider.clone());
    provider
}

pub fn create_metrics() -> WorkerMetrics {
    let meter: Meter = global::meter("claude-worker");
    WorkerMetrics {
        goals_completed_total: meter
            .u64_counter("claude_worker_goals_completed_total")
            .with_description("Total goals completed successfully")
            .build(),
        goals_failed_total: meter
            .u64_counter("claude_worker_goals_failed_total")
            .with_description("Total goals that failed")
            .build(),
        goal_duration_seconds: meter
            .f64_histogram("claude_worker_goal_duration_seconds")
            .with_description("Time from goal start to completion or failure")
            .with_unit("s")
            .build(),
        sse_connections_active: meter
            .i64_up_down_counter("claude_worker_sse_connections_active")
            .with_description("Currently active SSE goal-stream connections")
            .build(),
    }
}
