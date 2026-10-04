//! Per-IP sliding-window limit. The transcribe route is open, so this is
//! what stops one client from spending all the Intron credits.

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct RateLimiter {
    per_minute: usize,
    hits: Mutex<HashMap<IpAddr, VecDeque<Instant>>>,
}

impl RateLimiter {
    pub fn new(per_minute: usize) -> Self {
        Self {
            per_minute,
            hits: Mutex::new(HashMap::new()),
        }
    }

    /// Records a request; `Err(seconds)` says how long until one is allowed.
    pub fn check(&self, ip: IpAddr) -> Result<(), u64> {
        self.check_at(ip, Instant::now())
    }

    fn check_at(&self, ip: IpAddr, now: Instant) -> Result<(), u64> {
        let window = Duration::from_secs(60);
        let mut hits = self.hits.lock().expect("rate limiter lock");
        // Forget idle clients so the map can't grow without bound.
        if hits.len() > 10_000 {
            hits.retain(|_, q| q.back().is_some_and(|t| now.duration_since(*t) < window));
        }
        let q = hits.entry(ip).or_default();
        while q.front().is_some_and(|t| now.duration_since(*t) >= window) {
            q.pop_front();
        }
        if q.len() >= self.per_minute {
            let wait = window - now.duration_since(q[0]);
            return Err(wait.as_secs().max(1));
        }
        q.push_back(now);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn limits_per_ip_and_recovers_after_a_minute() {
        let rl = RateLimiter::new(2);
        let a: IpAddr = "10.0.0.1".parse().unwrap();
        let b: IpAddr = "10.0.0.2".parse().unwrap();
        let t0 = Instant::now();
        assert!(rl.check_at(a, t0).is_ok());
        assert!(rl.check_at(a, t0).is_ok());
        assert!(rl.check_at(a, t0).is_err());
        assert!(rl.check_at(b, t0).is_ok(), "other IPs are unaffected");
        assert!(rl.check_at(a, t0 + Duration::from_secs(61)).is_ok());
    }
}
