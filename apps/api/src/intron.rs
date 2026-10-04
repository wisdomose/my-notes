//! Client for Intron's Sahara speech-to-text API.
//!
//! Uses the synchronous upload endpoint (audio up to 120 s). If Intron times
//! out (503) it hands back a `file_id`; we then poll the status endpoint.
//! Docs: <https://docs.voice.intron.io/docs/stt/file-upload-sync>

use std::time::Duration;

use reqwest::multipart::{Form, Part};
use serde::Serialize;
use serde_json::Value;

/// How long to keep polling after a sync timeout.
const POLL_FOR: Duration = Duration::from_secs(90);
const POLL_EVERY: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct Intron {
    http: reqwest::Client,
    base_url: String,
    api_key: String,
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Transcript {
    pub text: String,
    pub file_id: Option<String>,
    pub duration_seconds: Option<f64>,
    pub language: String,
}

#[derive(Debug, PartialEq)]
pub enum IntronError {
    /// Intron rejected the audio (e.g. longer than 120 s). Safe to show.
    Rejected(String),
    /// Intron is rate-limiting us.
    RateLimited,
    /// Still not transcribed after polling.
    TimedOut,
    /// Anything else: network, auth, unexpected responses.
    Upstream(String),
}

impl Intron {
    pub fn new(base_url: String, api_key: String) -> Self {
        let http = reqwest::Client::builder()
            // Intron's own sync limit is 120 s; leave headroom.
            .timeout(Duration::from_secs(150))
            .build()
            .expect("HTTP client");
        Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key,
        }
    }

    pub async fn transcribe(
        &self,
        audio: Vec<u8>,
        file_name: &str,
        content_type: &str,
        language: &str,
    ) -> Result<Transcript, IntronError> {
        let part = Part::bytes(audio)
            .file_name(file_name.to_string())
            .mime_str(content_type)
            .map_err(|e| IntronError::Rejected(format!("bad content type: {e}")))?;
        let form = Form::new()
            .text("audio_file_name", file_name.to_string())
            .text("use_language_asr_input", language.to_string())
            .part("audio_file_blob", part);

        let res = self
            .http
            .post(format!("{}/file/v1/upload/sync", self.base_url))
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()
            .await
            .map_err(|e| IntronError::Upstream(format!("upload failed: {e}")))?;

        let status = res.status();
        let body: Value = res.json().await.unwrap_or(Value::Null);
        match status.as_u16() {
            200..=299 => match parse(&body, language) {
                Some(Ok(t)) => Ok(t),
                Some(Err(e)) => Err(e),
                // Accepted but not finished: poll it.
                None => match file_id(&body) {
                    Some(id) => self.poll(&id, language).await,
                    None => Err(IntronError::Upstream(format!(
                        "unexpected response: {body}"
                    ))),
                },
            },
            503 => match file_id(&body) {
                Some(id) => self.poll(&id, language).await,
                None => Err(IntronError::TimedOut),
            },
            400 | 413 | 415 | 422 => Err(IntronError::Rejected(message(&body))),
            429 => Err(IntronError::RateLimited),
            code => Err(IntronError::Upstream(format!(
                "HTTP {code}: {}",
                message(&body)
            ))),
        }
    }

    async fn poll(&self, file_id: &str, language: &str) -> Result<Transcript, IntronError> {
        let deadline = tokio::time::Instant::now() + POLL_FOR;
        loop {
            tokio::time::sleep(POLL_EVERY).await;
            let res = self
                .http
                .get(format!("{}/file/v1/status/{file_id}", self.base_url))
                .bearer_auth(&self.api_key)
                .send()
                .await
                .map_err(|e| IntronError::Upstream(format!("status failed: {e}")))?;
            if res.status().as_u16() == 429 {
                // Respect their limit and keep waiting.
            } else if !res.status().is_success() {
                return Err(IntronError::Upstream(format!(
                    "status HTTP {}",
                    res.status()
                )));
            } else {
                let body: Value = res.json().await.unwrap_or(Value::Null);
                if let Some(result) = parse(&body, language) {
                    return result;
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(IntronError::TimedOut);
            }
        }
    }
}

/// `Some(Ok)` when transcribed, `Some(Err)` when Intron says it failed,
/// `None` while it's still queued or processing.
fn parse(body: &Value, language: &str) -> Option<Result<Transcript, IntronError>> {
    let data = body.get("data")?;
    match data.get("processing_status").and_then(Value::as_str) {
        Some("FILE_TRANSCRIBED") => Some(Ok(Transcript {
            text: data
                .get("audio_transcript")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string(),
            file_id: file_id(body),
            duration_seconds: data
                .get("processed_audio_duration_in_seconds")
                .and_then(Value::as_f64),
            language: data
                .get("use_language_asr_input")
                .and_then(Value::as_str)
                .unwrap_or(language)
                .to_string(),
        })),
        Some("FILE_PROCESSING_FAILED") => Some(Err(IntronError::Upstream(
            "Intron could not process the audio".into(),
        ))),
        _ => None,
    }
}

fn file_id(body: &Value) -> Option<String> {
    body.get("data")
        .and_then(|d| d.get("file_id"))
        .or_else(|| body.get("file_id"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn message(body: &Value) -> String {
    body.get("message")
        .and_then(Value::as_str)
        .unwrap_or("request failed")
        .to_string()
}
