//! What the three programs share: the loop over N calls, the check of each answer, the checksum and the timings,
//! the same as the load tool's and the other libraries' scripts.
use std::future::Future;
use std::time::Instant;

pub fn fnv(b: &[u8]) -> u64 {
    b.iter().fold(0xcbf29ce484222325u64, |h, x| (h ^ *x as u64).wrapping_mul(0x100000001b3))
}

/// The base URL, the number of calls and whether to stream, from the command line: `URL N [--stream]`.
pub fn args() -> (String, usize, bool) {
    let a: Vec<String> = std::env::args().collect();
    (a[1].clone(), a[2].parse().expect("N"), a.iter().any(|x| x == "--stream"))
}

pub fn key() -> String {
    std::env::var("LLM_KEY").unwrap_or_else(|_| "local".into())
}

/// Calls `call(i)` for each of `n` calls on the current thread and prints what the harness reads.
pub async fn run<F, Fut>(n: usize, mut call: F)
where
    F: FnMut(usize) -> Fut,
    Fut: Future<Output = String>,
{
    let (mut ok, mut bad, mut sum, mut lat) = (0u64, 0u64, 0u64, Vec::with_capacity(n));
    let t0 = Instant::now();
    for i in 0..n {
        let t = Instant::now();
        let text = call(i).await;
        lat.push(t.elapsed().as_micros() as u64);
        if text.starts_with(&format!("echo: call {i}")) { ok += 1 } else { bad += 1 }
        sum ^= fnv(text.as_bytes()).wrapping_mul(i as u64 + 1);
    }
    let s = t0.elapsed().as_secs_f64();
    println!("ok {ok}\nbad {bad}\nchecksum {sum:016x}");
    lat.sort();
    eprintln!("metric calls_per_s={:.1}\nmetric p50_us={}", n as f64 / s, lat[lat.len() / 2]);
    if bad > 0 {
        std::process::exit(1);
    }
}
