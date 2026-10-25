//! Synthetic Tombolo session workload and its metrics.
//!
//! Phone → Mac: 1080p60-sized video (P-frames 25–40 KB, keyframe 200–300 KB every 2 s) with
//! the protocol's 24-byte media header and a ≤ 2-frame pre-transport queue (drop oldest);
//! 20 ms audio packets (4 B seq + 8 B capture time + 320 B ≈ Opus 128 kbit/s); bulk
//! transfer during the condition's bulk windows.
//! Mac → phone: 16-byte control pings every 10 ms, echoed by the phone (control RTT), and
//! a 16-byte frame acknowledgement per received video frame (frame-level flow control).
//! On one Mac all timestamps come from one system-wide clock (see clock.rs). Across two
//! devices (phone runs) the Mac estimates the phone's clock offset from the lowest-RTT
//! control pings (NTP-style) and maps phone timestamps into its own clock; on loopback the
//! estimate doubles as a self-check (it must come out ≈ 0).

use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use anyhow::Result;
use bytes::Bytes;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    sync::Notify,
};

use crate::{
    clock::{Rng, cpu_us, now_ns, sleep_until_ns},
    cond::Cond,
    session::{AudioRx, AudioTx, BoxW, MacCh, PhoneCh},
};

const FRAME_NS: u64 = 16_666_667;
const AUDIO_NS: u64 = 20_000_000;
const PING_NS: u64 = 10_000_000;
const WARMUP_NS: u64 = 2_000_000_000;
const BULK_CHUNK: usize = 64 * 1024;
const AUDIO_PAYLOAD: usize = 320;
/// Frame-level flow control: at most this many video frames written to the transport but
/// not yet acknowledged by the Mac (ReceiverFeedback on the control channel). Beyond it,
/// new frames wait in the 2-frame pre-transport queue, which drops the oldest. Same rule
/// for every transport, so capacity shortfalls show up as dropped frames rather than as
/// an unbounded queue inside the transport.
const MAX_INFLIGHT_FRAMES_DEFAULT: u64 = 4;

fn max_inflight_frames() -> u64 {
    std::env::var("S4_INFLIGHT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(MAX_INFLIGHT_FRAMES_DEFAULT)
}
/// Control messages are 24 bytes: type, pad, seq (u32), Mac time or ack count (u64),
/// phone time (u64, filled in by the phone when it echoes a ping).
const CTRL_MSG: usize = 24;
const MSG_PING: u8 = 1;
const MSG_FRAME_ACK: u8 = 2;

fn secs_ns(s: f64) -> u64 {
    (s * 1e9) as u64
}

/// Per-second CPU samples (offset from t0 in s, process CPU µs).
fn spawn_cpu_sampler(t0: u64, secs: f64) -> tokio::task::JoinHandle<Vec<(f64, u64)>> {
    tokio::spawn(async move {
        let mut v = vec![];
        let n = secs.ceil() as u64 + 1;
        for i in 0..=n {
            sleep_until_ns(t0 + i * 1_000_000_000).await;
            v.push((i as f64, cpu_us()));
        }
        v
    })
}

// ------------------------------------------------------------------------------------
// Phone
// ------------------------------------------------------------------------------------

struct Frame {
    seq: u32,
    cap_ns: u64,
    size: usize,
    flags: u8,
}

struct DropQueue<T> {
    q: Mutex<(VecDeque<T>, bool, u64)>, // items, closed, dropped
    n: Notify,
    cap: usize,
}

impl<T> DropQueue<T> {
    fn new(cap: usize) -> Arc<Self> {
        Arc::new(Self {
            q: Mutex::new((VecDeque::new(), false, 0)),
            n: Notify::new(),
            cap,
        })
    }
    /// Push; drop the oldest item when full. Returns true if something was dropped.
    fn push(&self, t: T) -> bool {
        let mut g = self.q.lock().unwrap();
        let mut dropped = false;
        if g.0.len() >= self.cap {
            g.0.pop_front();
            g.2 += 1;
            dropped = true;
        }
        g.0.push_back(t);
        drop(g);
        self.n.notify_one();
        dropped
    }
    fn close(&self) {
        self.q.lock().unwrap().1 = true;
        self.n.notify_one();
    }
    async fn pop(&self) -> Option<T> {
        loop {
            {
                let mut g = self.q.lock().unwrap();
                if let Some(t) = g.0.pop_front() {
                    return Some(t);
                }
                if g.1 {
                    return None;
                }
            }
            self.n.notified().await;
        }
    }
    fn dropped(&self) -> u64 {
        self.q.lock().unwrap().2
    }
}

fn header(ty: u8, flags: u8, seq: u32, cap_ns: u64, len: u32) -> [u8; 24] {
    let mut h = [0u8; 24];
    h[0] = ty;
    h[1] = flags;
    h[2..4].copy_from_slice(&1u16.to_be_bytes()); // channel_id
    h[4..8].copy_from_slice(&seq.to_be_bytes());
    // capture time in ns here (the protocol draft says µs; ns keeps sub-µs precision)
    h[8..16].copy_from_slice(&cap_ns.to_be_bytes());
    h[16..20].copy_from_slice(&0u32.to_be_bytes()); // encode_us
    h[20..24].copy_from_slice(&len.to_be_bytes());
    h
}

pub async fn phone_run(ch: PhoneCh, cond: &Cond, t0: u64, seed: u64) -> Result<Value> {
    let PhoneCh {
        mut ctrl_r,
        mut ctrl_w,
        video,
        audio,
        mut bulk,
        keep,
    } = ch;
    let secs = cond.secs;
    let cpu = spawn_cpu_sampler(t0, secs);
    let payload = Arc::new({
        let mut r = Rng::new(seed ^ 0x55);
        (0..300_000).map(|_| r.next_u64() as u8).collect::<Vec<u8>>()
    });

    // ---- video
    let vq = DropQueue::<Frame>::new(2);
    let n_frames = (secs * 60.0) as u32;
    let gen_q = vq.clone();
    let video_gen = tokio::spawn(async move {
        let mut rng = Rng::new(seed);
        let mut disc = false;
        for i in 0..n_frames {
            sleep_until_ns(t0 + i as u64 * FRAME_NS).await;
            let key = i % 120 == 0;
            let size = if key {
                rng.range(200_000, 300_000)
            } else {
                rng.range(25_000, 40_000)
            } as usize;
            let flags = (key as u8) | if disc { 4 } else { 0 };
            disc = gen_q.push(Frame {
                seq: i,
                cap_ns: now_ns(),
                size,
                flags,
            });
        }
        gen_q.close();
    });
    let wq = vq.clone();
    let pl = payload.clone();
    let acked = Arc::new(AtomicU64::new(0));
    let ack_notify = Arc::new(Notify::new());
    let (acked2, ack_notify2) = (acked.clone(), ack_notify.clone());
    let max_inflight = max_inflight_frames();
    let video_tx = tokio::spawn(async move {
        let mut w: BoxW = video;
        let mut sent = 0u64;
        let mut fc_waits = 0u64;
        loop {
            // Wait for flow-control credit *before* taking a frame, so the pre-transport
            // queue keeps dropping stale frames while we wait.
            let mut waited = false;
            loop {
                let n = ack_notify2.notified();
                tokio::pin!(n);
                n.as_mut().enable();
                if sent - acked2.load(Ordering::Acquire).min(sent) < max_inflight {
                    break;
                }
                waited = true;
                n.await;
            }
            fc_waits += waited as u64;
            let Some(f) = wq.pop().await else { break };
            w.write_all(&header(1, f.flags, f.seq, f.cap_ns, f.size as u32))
                .await?;
            w.write_all(&pl[..f.size]).await?;
            sent += 1;
        }
        w.write_all(&header(5, 0, u32::MAX, now_ns(), 0)).await?;
        w.flush().await?;
        w.shutdown().await?;
        anyhow::Ok((sent, fc_waits))
    });

    // ---- audio
    let n_audio = (secs * 50.0) as u32;
    let audio_task = tokio::spawn(async move {
        let mk = |seq: u32| {
            let mut p = Vec::with_capacity(12 + AUDIO_PAYLOAD);
            p.extend_from_slice(&seq.to_be_bytes());
            p.extend_from_slice(&now_ns().to_be_bytes());
            p.resize(12 + AUDIO_PAYLOAD, 0xAB);
            p
        };
        match audio {
            AudioTx::Dgram(conn) => {
                let mut errs = 0u64;
                for i in 0..n_audio {
                    sleep_until_ns(t0 + i as u64 * AUDIO_NS).await;
                    if conn.send_datagram(Bytes::from(mk(i))).is_err() {
                        errs += 1;
                    }
                }
                anyhow::Ok(json!({"sent": n_audio, "send_errors": errs, "dropped_sender": 0}))
            }
            AudioTx::Stream(mut w) => {
                // ≤ 100 ms (5 packets) pre-transport queue, drop oldest (protocol §8).
                let q = DropQueue::<Vec<u8>>::new(5);
                let q2 = q.clone();
                let writer = tokio::spawn(async move {
                    while let Some(p) = q2.pop().await {
                        w.write_all(&(p.len() as u16).to_be_bytes()).await?;
                        w.write_all(&p).await?;
                    }
                    w.flush().await?;
                    w.shutdown().await?;
                    anyhow::Ok(())
                });
                for i in 0..n_audio {
                    sleep_until_ns(t0 + i as u64 * AUDIO_NS).await;
                    q.push(mk(i));
                }
                q.close();
                writer.await??;
                anyhow::Ok(json!({"sent": n_audio, "send_errors": 0, "dropped_sender": q.dropped()}))
            }
        }
    });

    // ---- control echo (Mac pings, phone echoes)
    let ctrl = tokio::spawn(async move {
        let mut b = [0u8; CTRL_MSG];
        let mut oneway = vec![];
        while ctrl_r.read_exact(&mut b).await.is_ok() {
            let v = u64::from_be_bytes(b[8..16].try_into().unwrap());
            if b[0] == MSG_FRAME_ACK {
                acked.fetch_max(v, Ordering::AcqRel);
                ack_notify.notify_waiters();
                continue;
            }
            let now = now_ns();
            oneway.push((v, now.saturating_sub(v)));
            b[16..24].copy_from_slice(&now.to_be_bytes());
            if ctrl_w.write_all(&b).await.is_err() {
                break;
            }
        }
        let _ = ctrl_w.shutdown().await;
        oneway
    });

    // ---- bulk
    let windows = cond.bulk.windows();
    let max_total = cond.bulk_max_bytes.unwrap_or(u64::MAX);
    let bulk_task = tokio::spawn(async move {
        let chunk = vec![0x5Au8; BULK_CHUNK];
        let mut per = vec![];
        let mut total = 0u64;
        for (bi, (s, e)) in windows.iter().enumerate() {
            sleep_until_ns(t0 + secs_ns(*s)).await;
            let end = t0 + secs_ns(*e);
            let mut bytes = 0u64;
            while now_ns() < end && total < max_total {
                total += BULK_CHUNK as u64;
                let mut h = [0u8; 16];
                h[0..4].copy_from_slice(&(bi as u32).to_be_bytes());
                h[4..8].copy_from_slice(&(BULK_CHUNK as u32).to_be_bytes());
                h[8..16].copy_from_slice(&now_ns().to_be_bytes());
                bulk.write_all(&h).await?;
                bulk.write_all(&chunk).await?;
                bytes += BULK_CHUNK as u64;
            }
            per.push(json!({"burst": bi, "bytes_written": bytes,
                            "last_write_returned_s": (now_ns() - t0) as f64 / 1e9}));
        }
        bulk.flush().await?;
        bulk.shutdown().await?;
        anyhow::Ok(per)
    });

    video_gen.await?;
    let (frames_sent, fc_waits) = video_tx.await??;
    let audio_res = audio_task.await??;
    let bulk_res = bulk_task.await??;
    // The Mac closes the session after it has received everything.
    let oneway = match tokio::time::timeout(Duration::from_secs(8), ctrl).await {
        Ok(r) => r?,
        Err(_) => vec![],
    };
    let cpu = cpu.await?;
    let input: Vec<f64> = oneway
        .iter()
        .filter(|(s, _)| *s >= t0 + WARMUP_NS)
        .map(|(_, d)| *d as f64 / 1e6)
        .collect();
    let out = json!({
        "frames_generated": n_frames,
        "frames_sent": frames_sent,
        "frames_dropped_sender": vq.dropped(),
        "frames_flow_control_waits": fc_waits,
        "max_inflight_frames": max_inflight,
        "audio": audio_res,
        "bulk": bulk_res,
        // valid only when phone and Mac share a clock (loopback); see mac "input_oneway_ms"
        "input_oneway_same_clock_ms": pct(&input),
        "cpu_samples": cpu,
        "transport": keep.json(),
    });
    keep.close().await;
    Ok(out)
}

// ------------------------------------------------------------------------------------
// Mac
// ------------------------------------------------------------------------------------

pub async fn mac_run(ch: MacCh, cond: &Cond, t0: u64) -> Result<Value> {
    let MacCh {
        mut ctrl_r,
        mut ctrl_w,
        mut video,
        audio,
        mut bulk,
        keep,
    } = ch;
    let secs = cond.secs;
    let end = t0 + secs_ns(secs);
    let cpu = spawn_cpu_sampler(t0, secs);

    // ---- control: one writer task; pings and frame acks are queued to it
    let (ctx, mut crx) = tokio::sync::mpsc::unbounded_channel::<[u8; CTRL_MSG]>();
    let ctrl_writer = tokio::spawn(async move {
        while let Some(b) = crx.recv().await {
            if ctrl_w.write_all(&b).await.is_err() {
                break;
            }
        }
        let _ = ctrl_w.shutdown().await;
    });
    let ping_tx = ctx.clone();
    let pinger = tokio::spawn(async move {
        let mut i = 0u64;
        while t0 + i * PING_NS < end {
            sleep_until_ns(t0 + i * PING_NS).await;
            let mut b = [0u8; CTRL_MSG];
            b[0] = MSG_PING;
            b[4..8].copy_from_slice(&(i as u32).to_be_bytes());
            b[8..16].copy_from_slice(&now_ns().to_be_bytes());
            if ping_tx.send(b).is_err() {
                break;
            }
            i += 1;
        }
        i
    });
    let ctrl_rx = tokio::spawn(async move {
        let mut b = [0u8; CTRL_MSG];
        let mut rtt = vec![]; // (mac send, rtt, phone time)
        while ctrl_r.read_exact(&mut b).await.is_ok() {
            let sent = u64::from_be_bytes(b[8..16].try_into().unwrap());
            let phone = u64::from_be_bytes(b[16..24].try_into().unwrap());
            rtt.push((sent, now_ns() - sent, phone));
        }
        rtt
    });

    // ---- video
    let ack_tx = ctx;
    let video_rx = tokio::spawn(async move {
        let mut h = [0u8; 24];
        let mut buf = vec![0u8; 400_000];
        let mut frames = vec![]; // (seq, cap_ns, recv_ns, size, flags)
        loop {
            if video.read_exact(&mut h).await.is_err() {
                break;
            }
            let ty = h[0];
            let seq = u32::from_be_bytes(h[4..8].try_into().unwrap());
            let cap = u64::from_be_bytes(h[8..16].try_into().unwrap());
            let len = u32::from_be_bytes(h[20..24].try_into().unwrap()) as usize;
            if ty == 5 {
                break;
            }
            if video.read_exact(&mut buf[..len]).await.is_err() {
                break;
            }
            frames.push((seq, cap, now_ns(), len, h[1]));
            let mut b = [0u8; CTRL_MSG];
            b[0] = MSG_FRAME_ACK;
            b[8..16].copy_from_slice(&(frames.len() as u64).to_be_bytes());
            let _ = ack_tx.send(b);
        }
        drop(ack_tx);
        frames
    });

    // ---- audio
    let audio_deadline = end + 2_000_000_000;
    let audio_rx = tokio::spawn(async move {
        let mut pk = vec![]; // (seq, cap_ns, recv_ns)
        match audio {
            AudioRx::Dgram(conn) => loop {
                let left = audio_deadline.saturating_sub(now_ns());
                match tokio::time::timeout(Duration::from_nanos(left), conn.read_datagram()).await
                {
                    Ok(Ok(d)) if d.len() >= 12 => {
                        let seq = u32::from_be_bytes(d[0..4].try_into().unwrap());
                        let cap = u64::from_be_bytes(d[4..12].try_into().unwrap());
                        pk.push((seq, cap, now_ns()));
                    }
                    Ok(Ok(_)) => {}
                    _ => break,
                }
            },
            AudioRx::Stream(mut r) => {
                let mut buf = vec![0u8; 2048];
                loop {
                    let Ok(len) = r.read_u16().await else { break };
                    if r.read_exact(&mut buf[..len as usize]).await.is_err() {
                        break;
                    }
                    let seq = u32::from_be_bytes(buf[0..4].try_into().unwrap());
                    let cap = u64::from_be_bytes(buf[4..12].try_into().unwrap());
                    pk.push((seq, cap, now_ns()));
                }
            }
        }
        pk
    });

    // ---- bulk
    let bulk_rx = tokio::spawn(async move {
        // per burst: (first_send_ns, first_recv_ns, last_recv_ns, bytes)
        let mut per: Vec<(u64, u64, u64, u64)> = vec![];
        let mut h = [0u8; 16];
        let mut buf = vec![0u8; BULK_CHUNK];
        loop {
            if bulk.read_exact(&mut h).await.is_err() {
                break;
            }
            let bi = u32::from_be_bytes(h[0..4].try_into().unwrap()) as usize;
            let len = u32::from_be_bytes(h[4..8].try_into().unwrap()) as usize;
            let sent = u64::from_be_bytes(h[8..16].try_into().unwrap());
            if len > buf.len() {
                buf.resize(len, 0);
            }
            if bulk.read_exact(&mut buf[..len]).await.is_err() {
                break;
            }
            let now = now_ns();
            while per.len() <= bi {
                per.push((sent, now, now, 0));
            }
            per[bi].2 = now;
            per[bi].3 += (len + 16) as u64;
        }
        per
    });

    let hard = Duration::from_nanos(end.saturating_sub(now_ns()) + 10_000_000_000);
    let frames = tokio::time::timeout(hard, video_rx).await.ok().transpose()?.unwrap_or_default();
    let per_burst = tokio::time::timeout(Duration::from_secs(10), bulk_rx)
        .await
        .ok()
        .transpose()?
        .unwrap_or_default();
    let audio_pk = audio_rx.await?;
    let pings_sent = pinger.await?;
    // all senders are gone now -> the writer drains and shuts the control channel down
    let _ = tokio::time::timeout(Duration::from_secs(3), ctrl_writer).await;
    let rtts = tokio::time::timeout(Duration::from_secs(3), ctrl_rx)
        .await
        .ok()
        .transpose()?
        .unwrap_or_default();
    let cpu = cpu.await?;
    let transport = keep.json();
    keep.close().await;

    // ---- metrics
    // Phone clock → Mac clock: offset = phone − Mac, from the 10 % lowest-RTT pings.
    let offset_ns: i64 = {
        let mut v: Vec<(u64, i64)> = rtts
            .iter()
            .map(|(s, r, p)| (*r, *p as i64 - *s as i64 - (*r / 2) as i64))
            .collect();
        v.sort();
        let k = (v.len() / 10).max(5).min(v.len());
        let mut o: Vec<i64> = v[..k].iter().map(|x| x.1).collect();
        o.sort();
        if o.is_empty() { 0 } else { o[o.len() / 2] }
    };
    let to_mac = |t_phone: u64| -> u64 { (t_phone as i64 - offset_ns) as u64 };
    let frames: Vec<(u32, u64, u64, usize, u8)> =
        frames.into_iter().map(|f| (f.0, to_mac(f.1), f.2, f.3, f.4)).collect();
    let audio_pk: Vec<(u32, u64, u64)> =
        audio_pk.into_iter().map(|a| (a.0, to_mac(a.1), a.2)).collect();
    let per_burst: Vec<(u64, u64, u64, u64)> =
        per_burst.into_iter().map(|b| (to_mac(b.0), b.1, b.2, b.3)).collect();
    let input: Vec<f64> = rtts
        .iter()
        .filter(|r| r.0 >= t0 + WARMUP_NS)
        .map(|r| (to_mac(r.2) as f64 - r.0 as f64) / 1e6)
        .collect();
    let warm = t0 + WARMUP_NS;
    // A sample is "under load" if it was produced while bulk data was in flight:
    // from the burst's first send to the receipt of its last byte.
    let load: Vec<(u64, u64)> = per_burst.iter().map(|b| (b.0, b.2)).collect();
    let in_load = |t: u64| load.iter().any(|(s, e)| t >= *s && t <= *e);
    let split = |v: &[(u64, f64)]| -> Value {
        let all: Vec<f64> = v.iter().map(|x| x.1).collect();
        let l: Vec<f64> = v.iter().filter(|x| in_load(x.0)).map(|x| x.1).collect();
        let nl: Vec<f64> = v.iter().filter(|x| !in_load(x.0)).map(|x| x.1).collect();
        json!({"all": pct(&all), "load": pct(&l), "noload": pct(&nl)})
    };

    let fl: Vec<(u64, f64)> = frames
        .iter()
        .filter(|f| f.1 >= warm)
        .map(|f| (f.1, (f.2 - f.1) as f64 / 1e6))
        .collect();
    let frames_disc = frames.iter().filter(|f| f.4 & 4 != 0).count();

    let first_audio = (WARMUP_NS / AUDIO_NS) as u32;
    let n_audio = (secs * 50.0) as u32;
    let expected = n_audio - first_audio;
    let mut seen = vec![false; n_audio as usize];
    let mut al: Vec<(u64, f64)> = vec![];
    for (seq, cap, rx) in &audio_pk {
        if *seq >= first_audio && (*seq as usize) < seen.len() && !seen[*seq as usize] {
            seen[*seq as usize] = true;
            al.push((*cap, (*rx - *cap) as f64 / 1e6));
        }
    }
    let received = al.len() as u32;
    let late40 = al.iter().filter(|x| x.1 > 40.0).count() as u32;

    let rl: Vec<(u64, f64)> = rtts
        .iter()
        .filter(|r| r.0 >= warm)
        .map(|r| (r.0, r.1 as f64 / 1e6))
        .collect();

    let bulk_json: Vec<Value> = per_burst
        .iter()
        .enumerate()
        .map(|(i, b)| {
            let dur = (b.2 - b.1) as f64 / 1e9;
            json!({"burst": i, "bytes": b.3, "first_send_s": (b.0 as f64 - t0 as f64) / 1e9,
                   "last_recv_s": (b.2 - t0) as f64 / 1e9,
                   "recv_span_s": dur,
                   "mbit_s": if dur > 0.0 { b.3 as f64 * 8.0 / dur / 1e6 } else { 0.0 }})
        })
        .collect();
    let bulk_bytes: u64 = per_burst.iter().map(|b| b.3).sum();
    let bulk_span: f64 = per_burst.iter().map(|b| (b.2 - b.1) as f64 / 1e9).sum();

    Ok(json!({
        "frames_received": frames.len(),
        "frames_discontinuity_flag": frames_disc,
        "frame_latency_ms": split(&fl),
        "audio": {
            "expected": expected, "received": received,
            "loss_pct": 100.0 * (expected - received.min(expected)) as f64 / expected as f64,
            "late40_pct": 100.0 * late40 as f64 / expected as f64,
            "lost_or_late40_pct": 100.0 * ((expected - received.min(expected)) + late40) as f64 / expected as f64,
            "latency_ms": split(&al),
        },
        "control_rtt_ms": split(&rl),
        "input_oneway_ms": pct(&input),
        "clock_offset_est_ms": offset_ns as f64 / 1e6,
        "pings_sent": pings_sent,
        "bulk": {"bytes": bulk_bytes, "recv_span_s": bulk_span,
                 "mbit_s": if bulk_span > 0.0 { bulk_bytes as f64 * 8.0 / bulk_span / 1e6 } else { 0.0 },
                 "bursts": bulk_json},
        "cpu_samples": cpu,
        "transport": transport,
    }))
}

pub fn pct(v: &[f64]) -> Value {
    if v.is_empty() {
        return json!({"n": 0});
    }
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| s[(((s.len() - 1) as f64) * p).round() as usize];
    json!({
        "n": s.len(),
        "p50": round3(q(0.5)), "p95": round3(q(0.95)), "p99": round3(q(0.99)),
        "max": round3(s[s.len() - 1]),
        "mean": round3(s.iter().sum::<f64>() / s.len() as f64),
    })
}

fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}
