//! /v1/tidy through the real router against a fake OpenAI server.

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use hey_notes_api::intron::Intron;
use hey_notes_api::rate_limit::RateLimiter;
use hey_notes_api::tidy::Tidier;
use hey_notes_api::{AppState, app};
use serde_json::{Value, json};

type Seen = Arc<Mutex<Option<Value>>>;

async fn fake_openai(
    State(seen): State<Seen>,
    headers: axum::http::HeaderMap,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    assert_eq!(headers["authorization"], "Bearer sk-test");
    let transcript = body["messages"][1]["content"].as_str().unwrap().to_string();
    *seen.lock().unwrap() = Some(body);
    if transcript == "busy" {
        return (StatusCode::TOO_MANY_REQUESTS, Json(json!({"error": {}})));
    }
    let content = json!({
        "title": "Call Peter About the Car.",
        "text": "Call Peter about the car tomorrow."
    })
    .to_string();
    (
        StatusCode::OK,
        Json(json!({"choices": [{"message": {"role": "assistant", "content": content}}]})),
    )
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

async fn start(with_key: bool) -> (String, Seen) {
    let seen: Seen = Arc::default();
    let openai = serve(
        Router::new()
            .route("/v1/chat/completions", post(fake_openai))
            .with_state(seen.clone()),
    )
    .await;
    let api = serve(app(AppState {
        intron: Intron::new("http://127.0.0.1:9".into(), "unused".into()),
        limiter: Arc::new(RateLimiter::new(10)),
        trust_proxy: false,
        tidier: with_key.then(|| {
            Tidier::new(
                format!("http://{openai}"),
                "sk-test".into(),
                "gpt-6-luna".into(),
            )
        }),
    }))
    .await;
    (format!("http://{api}"), seen)
}

async fn tidy(base: &str, body: Value) -> (u16, Value) {
    let res = reqwest::Client::new()
        .post(format!("{base}/v1/tidy"))
        .json(&body)
        .send()
        .await
        .unwrap();
    (res.status().as_u16(), res.json().await.unwrap())
}

#[tokio::test]
async fn tidies_with_strict_schema_and_sentence_case_title() {
    let (base, seen) = start(true).await;
    let transcript = "call call John about the the car, no wait, call Peter about the car tomorrow";
    let (code, body) = tidy(&base, json!({ "text": transcript })).await;
    assert_eq!(code, 200, "{body}");
    assert_eq!(body["title"], "Call Peter about the car");
    assert_eq!(body["text"], "Call Peter about the car tomorrow.");

    let sent = seen.lock().unwrap().clone().unwrap();
    assert_eq!(sent["model"], "gpt-6-luna");
    assert_eq!(sent["response_format"]["json_schema"]["strict"], true);
    assert_eq!(sent["messages"][1]["content"], transcript);
}

#[tokio::test]
async fn reports_errors_and_validates_input() {
    let (base, _) = start(true).await;
    assert_eq!(tidy(&base, json!({ "text": "busy" })).await.0, 429);
    assert_eq!(tidy(&base, json!({ "text": "   " })).await.0, 400);
    assert_eq!(tidy(&base, json!({ "nope": 1 })).await.0, 400);

    let (no_key, _) = start(false).await;
    assert_eq!(tidy(&no_key, json!({ "text": "hello" })).await.0, 503);
}
