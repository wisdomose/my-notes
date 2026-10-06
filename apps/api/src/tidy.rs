//! Tidies a voice-note transcript into a title and clean text with an
//! OpenAI model (gpt-6-luna by default: it matched gpt-6.1-sol on our
//! 15-note benchmark at 1/14 the cost).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const SYSTEM: &str = r#"You tidy up voice notes. You get the raw transcript of one spoken note and return JSON.

Rules:
- title: 3 to 8 words naming what the note is about. No quotes, no trailing period.
- text: the same note, cleaned up. Fix punctuation and capitalisation, remove filler words (um, uh, you know, basically, like), fix obvious repeated words, and apply the speaker's own corrections ("call John, no wait, call Peter" -> "Call Peter"). If the speaker lists several things to do or buy, write them as a bulleted list ("- " per item). Keep the speaker's meaning and wording. Never add facts, never drop items, never answer or comment on the note.

Example 1
Transcript: so for the party we need, um, balloons, a cake and like some plates and cups
JSON: {"title": "Party supplies", "text": "For the party we need:\n- Balloons\n- A cake\n- Plates and cups"}

Example 2
Transcript: remind me tonight at 8 to send the invoice to Daniel
JSON: {"title": "Send the invoice to Daniel", "text": "Remind me tonight at 8 to send the invoice to Daniel."}"#;

#[derive(Clone)]
pub struct Tidier {
    http: reqwest::Client,
    base_url: String,
    api_key: String,
    model: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Tidied {
    pub title: String,
    pub text: String,
}

#[derive(Debug, PartialEq)]
pub enum TidyError {
    RateLimited,
    Upstream(String),
}

impl Tidier {
    pub fn new(base_url: String, api_key: String, model: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(45))
            .build()
            .expect("HTTP client");
        Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key,
            model,
        }
    }

    pub async fn tidy(&self, transcript: &str) -> Result<Tidied, TidyError> {
        let body = json!({
            "model": self.model,
            "messages": [
                { "role": "system", "content": SYSTEM },
                { "role": "user", "content": transcript },
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "note",
                    "strict": true,
                    "schema": {
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["title", "text"],
                        "properties": {
                            "title": { "type": "string" },
                            "text": { "type": "string" },
                        },
                    },
                },
            },
        });
        let res = self
            .http
            .post(format!("{}/v1/chat/completions", self.base_url))
            .bearer_auth(&self.api_key)
            .json(&body)
            .send()
            .await
            .map_err(|e| TidyError::Upstream(format!("request failed: {e}")))?;
        let status = res.status();
        let value: Value = res.json().await.unwrap_or(Value::Null);
        if status.as_u16() == 429 {
            return Err(TidyError::RateLimited);
        }
        if !status.is_success() {
            return Err(TidyError::Upstream(format!("HTTP {status}")));
        }
        let content = value["choices"][0]["message"]["content"]
            .as_str()
            .ok_or_else(|| TidyError::Upstream("no content".into()))?;
        let mut out: Tidied = serde_json::from_str(content)
            .map_err(|e| TidyError::Upstream(format!("bad JSON: {e}")))?;
        out.title = sentence_case(out.title.trim().trim_end_matches('.'), transcript);
        out.text = out.text.trim().to_string();
        if out.text.is_empty() {
            return Err(TidyError::Upstream("empty text".into()));
        }
        Ok(out)
    }
}

/// "Call Peter About the Car" -> "Call Peter about the car": lower-cases
/// title-cased words unless the speaker's transcript capitalises them too
/// (names, products) or they're acronyms.
pub fn sentence_case(title: &str, transcript: &str) -> String {
    let mut out = Vec::new();
    for (i, word) in title.split_whitespace().enumerate() {
        let core: String = word.chars().filter(|c| c.is_alphanumeric()).collect();
        let keep = i == 0
            || core.len() > 1 && core.chars().all(|c| !c.is_lowercase())
            || !core.is_empty() && transcript.contains(core.as_str());
        if keep {
            out.push(word.to_string());
        } else {
            out.push(word.to_lowercase());
        }
    }
    let s = out.join(" ");
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().collect::<String>() + chars.as_str(),
        None => s,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentence_case_keeps_names_and_acronyms() {
        let t = "call call John about the the car, no wait, call Peter about the car";
        assert_eq!(
            sentence_case("Call Peter About the Car", t),
            "Call Peter about the car"
        );
        assert_eq!(
            sentence_case("Hey Note Voice Prompt Bug", "a bug in Hey Note"),
            "Hey Note voice prompt bug"
        );
        assert_eq!(
            sentence_case("Fix the API Timeout", "fix the api"),
            "Fix the API timeout"
        );
        assert_eq!(sentence_case("grocery list", "x"), "Grocery list");
    }
}
