//! End-to-end through the real router against a fake Intron server.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::extract::{Multipart, Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use hey_notes_api::intron::Intron;
use hey_notes_api::rate_limit::RateLimiter;
use hey_notes_api::{AppState, app};
use serde_json::{Value, json};

/// Fake Intron: the file name picks the behaviour.
/// - `ok.wav`: transcribed synchronously
/// - `slow.wav`: 503 with a file_id; the status endpoint finishes on the 2nd poll
/// - `long.wav`: 400 (too long)
#[derive(Clone, Default)]
struct Fake {
    polls: Arc<AtomicUsize>,
    last_form: Arc<std::sync::Mutex<Vec<(String, String)>>>,
}

async fn fake_upload(
    State(fake): State<Fake>,
    headers: axum::http::HeaderMap,
    mut form: Multipart,
) -> (StatusCode, Json<Value>) {
    assert_eq!(headers["authorization"], "Bearer test-key");
    let mut name = String::new();
    let mut seen = vec![];
    while let Some(f) = form.next_field().await.unwrap() {
        let field = f.name().unwrap().to_string();
        if field == "audio_file_blob" {
            let bytes = f.bytes().await.unwrap();
            seen.push((field, format!("{} bytes", bytes.len())));
        } else {
            let v = f.text().await.unwrap();
            if field == "audio_file_name" {
                name = v.clone();
            }
            seen.push((field, v));
        }
    }
    *fake.last_form.lock().unwrap() = seen;
    match name.as_str() {
        "ok.wav" => (
            StatusCode::OK,
            Json(json!({"data": {
                "file_id": "f-ok", "processing_status": "FILE_TRANSCRIBED",
                "audio_transcript": " Buy bread and eggs on the way home. ",
                "processed_audio_duration_in_seconds": 4, "use_language_asr_input": "en"
            }, "message": "file status found", "status": "Ok"})),
        ),
        "slow.wav" => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"data": {"file_id": "f-slow"}, "message": "timeout"})),
        ),
        _ => (
            StatusCode::BAD_REQUEST,
            Json(json!({"message": "Max audio duration exceeded"})),
        ),
    }
}

async fn fake_status(State(fake): State<Fake>, Path(id): Path<String>) -> Json<Value> {
    assert_eq!(id, "f-slow");
    let n = fake.polls.fetch_add(1, Ordering::SeqCst);
    let status = if n == 0 {
        "FILE_PROCESSING"
    } else {
        "FILE_TRANSCRIBED"
    };
    Json(json!({"data": {
        "file_id": "f-slow", "processing_status": status,
        "audio_transcript": "Call the landlord about the gate.",
        "processed_audio_duration_in_seconds": 30
    }}))
}

async fn serve(router: Router) -> SocketAddr {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(
            l,
            router.into_make_service_with_connect_info::<SocketAddr>(),
        )
        .await
        .unwrap();
    });
    addr
}

async fn start(per_minute: usize) -> (String, Fake) {
    let fake = Fake::default();
    let intron = serve(
        Router::new()
            .route("/file/v1/upload/sync", post(fake_upload))
            .route("/file/v1/status/{id}", get(fake_status))
            .with_state(fake.clone()),
    )
    .await;
    let api = serve(app(AppState {
        intron: Intron::new(format!("http://{intron}"), "test-key".into()),
        limiter: Arc::new(RateLimiter::new(per_minute)),
        trust_proxy: false,
        tidier: None,
    }))
    .await;
    (format!("http://{api}"), fake)
}

async fn post_audio(base: &str, name: &str, language: Option<&str>) -> (u16, Value) {
    let part = reqwest::multipart::Part::bytes(vec![0u8; 3200])
        .file_name(name.to_string())
        .mime_str("audio/wav")
        .unwrap();
    let mut form = reqwest::multipart::Form::new().part("audio", part);
    if let Some(l) = language {
        form = form.text("language", l.to_string());
    }
    let res = reqwest::Client::new()
        .post(format!("{base}/v1/transcribe"))
        .multipart(form)
        .send()
        .await
        .unwrap();
    (res.status().as_u16(), res.json().await.unwrap())
}

#[tokio::test]
async fn transcribes_and_forwards_the_right_form() {
    let (base, fake) = start(10).await;
    let (code, body) = post_audio(&base, "ok.wav", Some("pcm")).await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["text"], "Buy bread and eggs on the way home.");
    assert_eq!(body["fileId"], "f-ok");
    assert_eq!(body["durationSeconds"], 4.0);
    let form = fake.last_form.lock().unwrap().clone();
    assert!(form.contains(&("audio_file_name".into(), "ok.wav".into())));
    assert!(form.contains(&("use_language_asr_input".into(), "pcm".into())));
    assert!(form.contains(&("audio_file_blob".into(), "3200 bytes".into())));
}

#[tokio::test]
async fn polls_when_intron_times_out() {
    let (base, fake) = start(10).await;
    let (code, body) = post_audio(&base, "slow.wav", None).await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["text"], "Call the landlord about the gate.");
    assert_eq!(fake.polls.load(Ordering::SeqCst), 2);
}

#[tokio::test]
async fn passes_on_rejections() {
    let (base, _) = start(10).await;
    let (code, body) = post_audio(&base, "long.wav", None).await;
    assert_eq!(code, 422);
    assert_eq!(body["error"], "Max audio duration exceeded");
}

#[tokio::test]
async fn validates_input_and_rate_limits() {
    let (base, _) = start(2).await;
    let res = reqwest::Client::new()
        .post(format!("{base}/v1/transcribe"))
        .multipart(reqwest::multipart::Form::new().text("language", "en"))
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 400);
    // That request counted; one more is allowed, then 429.
    assert_eq!(post_audio(&base, "ok.wav", None).await.0, 200);
    let res = reqwest::Client::new()
        .post(format!("{base}/v1/transcribe"))
        .multipart(reqwest::multipart::Form::new().text("language", "en"))
        .send()
        .await
        .unwrap();
    assert_eq!(res.status(), 429);
    assert!(res.headers().contains_key("retry-after"));
}

#[tokio::test]
async fn health() {
    let (base, _) = start(1).await;
    let body: Value = reqwest::get(format!("{base}/health"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(body["ok"], true);
}
