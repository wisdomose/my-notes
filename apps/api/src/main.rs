use std::net::SocketAddr;
use std::sync::Arc;

use hey_notes_api::intron::Intron;
use hey_notes_api::rate_limit::RateLimiter;
use hey_notes_api::tidy::Tidier;
use hey_notes_api::{AppState, app};
use tracing_subscriber::EnvFilter;

/// Configuration (environment, or `.env` next to the binary in development):
/// - `INTRON_API_KEY` (required): never commit it; the repo is public.
/// - `PORT` (default 8080)
/// - `RATE_LIMIT_PER_MINUTE` (default 10): per client IP
/// - `TRUST_PROXY` (default true): read client IPs from X-Forwarded-For
/// - `INTRON_BASE_URL` (default https://infer.voice.intron.io)
/// - `OPENAI_API_KEY`: enables `/v1/tidy`; `OPENAI_MODEL` (default gpt-6-luna)
#[tokio::main]
async fn main() {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "hey_notes_api=info,tower_http=info".into()),
        )
        .init();

    let api_key = std::env::var("INTRON_API_KEY")
        .ok()
        .filter(|k| !k.trim().is_empty())
        .expect("INTRON_API_KEY must be set");
    let port: u16 = env_or("PORT", 8080);
    let state = AppState {
        intron: Intron::new(
            std::env::var("INTRON_BASE_URL")
                .unwrap_or_else(|_| "https://infer.voice.intron.io".into()),
            api_key.trim().to_string(),
        ),
        limiter: Arc::new(RateLimiter::new(env_or("RATE_LIMIT_PER_MINUTE", 10))),
        trust_proxy: env_or("TRUST_PROXY", true),
        tidier: std::env::var("OPENAI_API_KEY")
            .ok()
            .filter(|k| !k.trim().is_empty())
            .map(|key| {
                Tidier::new(
                    std::env::var("OPENAI_BASE_URL")
                        .unwrap_or_else(|_| "https://api.openai.com".into()),
                    key.trim().to_string(),
                    std::env::var("OPENAI_MODEL").unwrap_or_else(|_| "gpt-6-luna".into()),
                )
            }),
    };
    if state.tidier.is_none() {
        tracing::warn!("OPENAI_API_KEY not set: /v1/tidy is disabled");
    }

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    tracing::info!("listening on {addr}");
    axum::serve(
        listener,
        app(state).into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown())
    .await
    .expect("server");
}

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// Ctrl-C locally, SIGTERM from Docker/Coolify.
async fn shutdown() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = term => {}
    }
}
