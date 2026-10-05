//! Cloudflare's edge IP ranges, so `CF-Connecting-IP` is only trusted on
//! requests that really came through Cloudflare (anyone hitting the origin
//! directly could set that header to dodge the rate limit).
//! Source: <https://www.cloudflare.com/ips-v4>, <https://www.cloudflare.com/ips-v6>
//! (fetched 2026-10-05; they change rarely).

use std::net::IpAddr;

const V4: &[&str] = &[
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
];

const V6: &[&str] = &[
    "2400:cb00::/32",
    "2606:4700::/32",
    "2803:f800::/32",
    "2405:b500::/32",
    "2405:8100::/32",
    "2a06:98c0::/29",
    "2c0f:f248::/32",
];

pub fn is_cloudflare(ip: IpAddr) -> bool {
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(ip),
        v4 => v4,
    };
    match ip {
        IpAddr::V4(v4) => V4.iter().any(|c| in_cidr(u32::from(v4) as u128, 32, c)),
        IpAddr::V6(v6) => V6.iter().any(|c| in_cidr(u128::from(v6), 128, c)),
    }
}

fn in_cidr(ip: u128, bits: u32, cidr: &str) -> bool {
    let Some((net, len)) = cidr.split_once('/') else {
        return false;
    };
    let Ok(len) = len.parse::<u32>() else {
        return false;
    };
    let net = match net.parse::<IpAddr>() {
        Ok(IpAddr::V4(n)) if bits == 32 => u32::from(n) as u128,
        Ok(IpAddr::V6(n)) if bits == 128 => u128::from(n),
        _ => return false,
    };
    if len == 0 {
        return true;
    }
    let shift = bits - len;
    (ip >> shift) == (net >> shift)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_cloudflare_ranges_only() {
        for ip in [
            "172.67.140.75",
            "104.21.27.10",
            "2606:4700:3037::6815:1b0a",
            "162.159.1.1",
        ] {
            assert!(is_cloudflare(ip.parse().unwrap()), "{ip}");
        }
        for ip in [
            "80.241.218.79",
            "10.0.1.5",
            "8.8.8.8",
            "2001:db8::1",
            "172.72.0.1",
        ] {
            assert!(!is_cloudflare(ip.parse().unwrap()), "{ip}");
        }
    }
}
