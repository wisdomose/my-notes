//! Hey Notes API. For now one job: transcribe a voice note with Intron's
//! Sahara model (built for African-accented English), keeping the Intron
//! API key on the server.
//!
//! `POST /v1/transcribe` (open, rate-limited per IP), multipart form:
//! - `audio`: the recording (wav, mp3, m4a, ogg, webm, flac; up to 120 s)
//! - `language`: optional Intron language code, default `en`
//!
//! 200 → `{"text", "fileId", "durationSeconds", "language"}`;
//! errors → `{"error": "..."}` with 400/413/422/429/502/504.

pub mod cloudflare;
pub mod intron;
pub mod rate_limit;
pub mod tidy;

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use axum::extract::{ConnectInfo, DefaultBodyLimit, Multipart, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use tower_http::trace::TraceLayer;

use intron::{Intron, IntronError};
use rate_limit::RateLimiter;
use tidy::{Tidier, TidyError};

/// Generous for 120 s of 16 kHz mono WAV (~3.8 MB) or any compressed format.
pub const MAX_UPLOAD_BYTES: usize = 15 * 1024 * 1024;

#[derive(Clone)]
pub struct AppState {
    pub intron: Intron,
    pub limiter: Arc<RateLimiter>,
    /// Behind a reverse proxy (Coolify/Traefik): take the client IP from the
    /// last `X-Forwarded-For` entry, the one our proxy appended.
    pub trust_proxy: bool,
    /// Note tidying (titles + cleanup); None when no OpenAI key is set.
    pub tidier: Option<Tidier>,
}

pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/health", get(|| async { Json(json!({ "ok": true })) }))
        .route("/v1/transcribe", post(transcribe))
        .route("/v1/tidy", post(tidy_note))
        .layer(DefaultBodyLimit::max(MAX_UPLOAD_BYTES))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

async fn transcribe(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    mut form: Multipart,
) -> Response {
    let ip = client_ip(&headers, peer, state.trust_proxy);
    if let Err(retry_after) = state.limiter.check(ip) {
        let mut res = error(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many requests, slow down",
        );
        if let Ok(v) = HeaderValue::from_str(&retry_after.to_string()) {
            res.headers_mut().insert(header::RETRY_AFTER, v);
        }
        return res;
    }

    let mut audio: Option<(Vec<u8>, String, String)> = None;
    let mut language = "en".to_string();
    loop {
        let field = match form.next_field().await {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(e) => return error(e.status(), &e.body_text()),
        };
        match field.name() {
            Some("audio") => {
                let name = field.file_name().unwrap_or("note.wav").to_string();
                let mime = field
                    .content_type()
                    .map(str::to_string)
                    .unwrap_or_else(|| guess_mime(&name).to_string());
                match field.bytes().await {
                    Ok(b) if !b.is_empty() => audio = Some((b.to_vec(), name, mime)),
                    Ok(_) => return error(StatusCode::BAD_REQUEST, "The audio file is empty"),
                    Err(e) => return error(e.status(), &e.body_text()),
                }
            }
            Some("language") => match field.text().await {
                Ok(l) if valid_language(&l) => language = l,
                _ => return error(StatusCode::BAD_REQUEST, "Invalid language code"),
            },
            _ => {}
        }
    }
    let Some((bytes, name, mime)) = audio else {
        return error(StatusCode::BAD_REQUEST, "Missing the `audio` file field");
    };

    let size = bytes.len();
    match state
        .intron
        .transcribe(bytes, &name, &mime, &language)
        .await
    {
        Ok(t) => {
            tracing::info!(%ip, size, seconds = t.duration_seconds, "transcribed");
            Json(t).into_response()
        }
        Err(e) => {
            tracing::warn!(%ip, size, error = ?e, "transcription failed");
            match e {
                IntronError::Rejected(m) => error(StatusCode::UNPROCESSABLE_ENTITY, &m),
                IntronError::RateLimited => error(
                    StatusCode::TOO_MANY_REQUESTS,
                    "The speech service is busy, try again in a minute",
                ),
                IntronError::TimedOut => {
                    error(StatusCode::GATEWAY_TIMEOUT, "Transcription took too long")
                }
                // Don't leak upstream details to an open route.
                IntronError::Upstream(_) => {
                    error(StatusCode::BAD_GATEWAY, "The speech service failed")
                }
            }
        }
    }
}

#[derive(serde::Deserialize)]
struct TidyRequest {
    text: String,
}

/// `POST /v1/tidy` `{"text": "<transcript>"}` → `{"title", "text"}`.
async fn tidy_note(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Result<Json<TidyRequest>, axum::extract::rejection::JsonRejection>,
) -> Response {
    let ip = client_ip(&headers, peer, state.trust_proxy);
    if let Err(retry_after) = state.limiter.check(ip) {
        let mut res = error(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many requests, slow down",
        );
        if let Ok(v) = HeaderValue::from_str(&retry_after.to_string()) {
            res.headers_mut().insert(header::RETRY_AFTER, v);
        }
        return res;
    }
    let Some(tidier) = state.tidier.as_ref() else {
        return error(StatusCode::SERVICE_UNAVAILABLE, "Tidying isn't configured");
    };
    let Ok(Json(req)) = body else {
        return error(StatusCode::BAD_REQUEST, "Send JSON: {\"text\": \"...\"}");
    };
    let text = req.text.trim();
    if text.is_empty() || text.chars().count() > 20_000 {
        return error(
            StatusCode::BAD_REQUEST,
            "Text must be 1 to 20,000 characters",
        );
    }
    match tidier.tidy(text).await {
        Ok(t) => {
            tracing::info!(%ip, chars = text.len(), "tidied");
            Json(t).into_response()
        }
        Err(e) => {
            tracing::warn!(%ip, error = ?e, "tidy failed");
            match e {
                TidyError::RateLimited => error(
                    StatusCode::TOO_MANY_REQUESTS,
                    "The AI service is busy, try again in a minute",
                ),
                TidyError::Upstream(_) => error(StatusCode::BAD_GATEWAY, "Tidying failed"),
            }
        }
    }
}

fn error(status: StatusCode, message: &str) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}

/// The caller's IP for rate limiting. Behind Coolify's proxy the TCP peer
/// is the proxy, so take the last `X-Forwarded-For` hop (the one our proxy
/// appended). If that hop is Cloudflare, the real client is in
/// `CF-Connecting-IP`; it's ignored otherwise, since anyone reaching the
/// origin directly could set it.
pub fn client_ip(headers: &HeaderMap, peer: SocketAddr, trust_proxy: bool) -> IpAddr {
    if !trust_proxy {
        return peer.ip();
    }
    let hop = headers
        .get_all("x-forwarded-for")
        .iter()
        .filter_map(|v| v.to_str().ok())
        .flat_map(|v| v.split(','))
        .filter_map(|s| s.trim().parse::<IpAddr>().ok())
        .next_back()
        .unwrap_or(peer.ip());
    if cloudflare::is_cloudflare(hop)
        && let Some(ip) = headers
            .get("cf-connecting-ip")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.trim().parse::<IpAddr>().ok())
    {
        return ip;
    }
    hop
}

fn valid_language(l: &str) -> bool {
    !l.is_empty()
        && l.len() <= 16
        && l.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn guess_mime(name: &str) -> &'static str {
    match name
        .rsplit('.')
        .next()
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("mp3") => "audio/mpeg",
        Some("m4a") | Some("mp4") => "audio/mp4",
        Some("ogg") => "audio/ogg",
        Some("webm") => "audio/webm",
        Some("flac") => "audio/flac",
        _ => "audio/wav",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn headers(pairs: &[(&'static str, &str)]) -> HeaderMap {
        let mut h = HeaderMap::new();
        for (k, v) in pairs {
            h.append(*k, v.parse().unwrap());
        }
        h
    }

    #[test]
    fn client_ip_through_cloudflare_and_the_proxy() {
        let proxy: SocketAddr = "10.0.1.5:443".parse().unwrap();
        // Phone → Cloudflare → Traefik → us.
        let via_cf = headers(&[
            ("x-forwarded-for", "41.58.1.2, 172.67.140.75"),
            ("cf-connecting-ip", "41.58.1.2"),
        ]);
        assert_eq!(
            client_ip(&via_cf, proxy, true),
            "41.58.1.2".parse::<IpAddr>().unwrap()
        );

        // Straight to the origin with a forged header: ignore the header.
        let forged = headers(&[
            ("x-forwarded-for", "203.0.113.9"),
            ("cf-connecting-ip", "1.2.3.4"),
        ]);
        assert_eq!(
            client_ip(&forged, proxy, true),
            "203.0.113.9".parse::<IpAddr>().unwrap()
        );

        // Not behind a proxy: the TCP peer, whatever the headers say.
        assert_eq!(client_ip(&via_cf, proxy, false), proxy.ip());
    }
}
