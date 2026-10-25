//! Userland impairment proxies (no root, no dummynet).
//!
//! * UDP proxy (QUIC over UDP): genuine packet-level impairment — loss, drop-tail
//!   bottleneck, delay/jitter — applied to every QUIC packet.
//! * TCP relay (TLS/TCP channels and QUIC-over-TCP): terminates TCP on both sides, so it
//!   cannot drop segments. It applies the same delay/jitter and a shared rate-limited FIFO
//!   with back-pressure, and turns each "lost" segment into a stall of that connection
//!   (see `Cond::tcp_loss_stall_ns`). This is a *model* of TCP loss recovery, documented
//!   as optimistic for TCP.

use std::{
    io::{Read, Write},
    net::{Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
};

use crate::{
    clock::{now_ns, thread_sleep_until_ns},
    cond::{Cond, Link, Verdict},
};

#[derive(Default, Debug)]
pub struct DirStats {
    pub pkts_out: AtomicU64,
    pub bytes_out: AtomicU64,
}

pub struct ProxyHandle {
    pub listen: SocketAddr,
    pub up: Arc<Mutex<Link>>,
    pub down: Arc<Mutex<Link>>,
    pub up_out: Arc<DirStats>,
    pub down_out: Arc<DirStats>,
    pub connections: Arc<AtomicU64>,
}

impl ProxyHandle {
    pub fn json(&self) -> serde_json::Value {
        let d = |l: &Arc<Mutex<Link>>, o: &Arc<DirStats>| {
            let l = l.lock().unwrap();
            serde_json::json!({
                "pkts_in": l.pkts_in, "bytes_in": l.bytes_in, "lost": l.lost,
                "queue_dropped": l.queue_dropped,
                "pkts_out": o.pkts_out.load(Ordering::Relaxed),
                "bytes_out": o.bytes_out.load(Ordering::Relaxed),
            })
        };
        serde_json::json!({
            "up_mac_to_phone": d(&self.up, &self.up_out),
            "down_phone_to_mac": d(&self.down, &self.down_out),
            "connections": self.connections.load(Ordering::Relaxed),
        })
    }
}

fn big_buffers(sock: &socket2::SockRef<'_>) {
    let _ = sock.set_recv_buffer_size(4 << 20);
    let _ = sock.set_send_buffer_size(4 << 20);
}

// ------------------------------------------------------------------------------------
// UDP
// ------------------------------------------------------------------------------------

/// Mac sends to `listen` (IPv4 loopback); the proxy forwards to `phone` (IPv6 loopback)
/// from its own IPv6 socket. Mac and phone endpoints are bound to different address
/// families, so iroh's hole-punching cannot open a direct path around the proxy.
pub fn udp_proxy(cond: &Cond, phone: SocketAddr, seed: u64) -> std::io::Result<ProxyHandle> {
    let a = UdpSocket::bind("127.0.0.1:0")?;
    let b = UdpSocket::bind("[::1]:0")?;
    big_buffers(&socket2::SockRef::from(&a));
    big_buffers(&socket2::SockRef::from(&b));
    let listen = a.local_addr()?;
    let up = Arc::new(Mutex::new(Link::new(cond.clone(), seed ^ 0xA)));
    let down = Arc::new(Mutex::new(Link::new(cond.clone(), seed ^ 0xB)));
    let up_out = Arc::new(DirStats::default());
    let down_out = Arc::new(DirStats::default());
    let mac_addr: Arc<Mutex<Option<SocketAddr>>> = Arc::default();

    // up: a -> b -> phone
    spawn_udp_dir(
        a.try_clone()?,
        b.try_clone()?,
        up.clone(),
        up_out.clone(),
        Some(mac_addr.clone()),
        Target::Fixed(phone),
    );
    // down: b -> a -> mac
    spawn_udp_dir(b, a, down.clone(), down_out.clone(), None, Target::Learned(mac_addr));
    Ok(ProxyHandle {
        listen,
        up,
        down,
        up_out,
        down_out,
        connections: Arc::new(AtomicU64::new(1)),
    })
}

enum Target {
    Fixed(SocketAddr),
    Learned(Arc<Mutex<Option<SocketAddr>>>),
}

fn spawn_udp_dir(
    rx_sock: UdpSocket,
    tx_sock: UdpSocket,
    link: Arc<Mutex<Link>>,
    out: Arc<DirStats>,
    learn: Option<Arc<Mutex<Option<SocketAddr>>>>,
    target: Target,
) {
    let (tx, rx) = mpsc::channel::<(u64, Vec<u8>)>();
    thread::spawn(move || {
        let mut buf = vec![0u8; 65536];
        loop {
            let Ok((n, from)) = rx_sock.recv_from(&mut buf) else {
                return;
            };
            if let Some(l) = &learn {
                *l.lock().unwrap() = Some(from);
            }
            let now = now_ns();
            let v = link.lock().unwrap().admit(now, n, true);
            if let Verdict::Deliver(t) = v
                && tx.send((t, buf[..n].to_vec())).is_err()
            {
                return;
            }
        }
    });
    thread::spawn(move || {
        while let Ok((t, data)) = rx.recv() {
            thread_sleep_until_ns(t);
            let dst = match &target {
                Target::Fixed(a) => *a,
                Target::Learned(m) => match *m.lock().unwrap() {
                    Some(a) => a,
                    None => continue,
                },
            };
            if tx_sock.send_to(&data, dst).is_ok() {
                out.pkts_out.fetch_add(1, Ordering::Relaxed);
                out.bytes_out.fetch_add(data.len() as u64, Ordering::Relaxed);
            }
        }
    });
}

// ------------------------------------------------------------------------------------
// TCP
// ------------------------------------------------------------------------------------

const SEG: usize = 1448;

/// Accepts connections from the Mac on `listen` and relays each to `phone`.
pub fn tcp_relay(cond: &Cond, phone: SocketAddr, seed: u64) -> std::io::Result<ProxyHandle> {
    let l = TcpListener::bind("127.0.0.1:0")?;
    let listen = l.local_addr()?;
    let up = Arc::new(Mutex::new(Link::new(cond.clone(), seed ^ 0xA)));
    let down = Arc::new(Mutex::new(Link::new(cond.clone(), seed ^ 0xB)));
    let up_out = Arc::new(DirStats::default());
    let down_out = Arc::new(DirStats::default());
    let connections = Arc::new(AtomicU64::new(0));
    let stall = cond.tcp_loss_stall_ns();
    let queue = cond.queue_bytes;
    {
        let (up, down, up_out, down_out, connections) = (
            up.clone(),
            down.clone(),
            up_out.clone(),
            down_out.clone(),
            connections.clone(),
        );
        thread::spawn(move || {
            for mac in l.incoming() {
                let Ok(mac) = mac else { return };
                let Ok(ph) = TcpStream::connect(phone) else {
                    continue;
                };
                connections.fetch_add(1, Ordering::Relaxed);
                for s in [&mac, &ph] {
                    let _ = s.set_nodelay(true);
                    // Small receive buffers keep the relay's hidden queue small: when the
                    // modelled bottleneck is full we stop reading and the sender blocks.
                    let _ = socket2::SockRef::from(s).set_recv_buffer_size(16 * 1024);
                }
                relay_dir(
                    mac.try_clone().unwrap(),
                    ph.try_clone().unwrap(),
                    up.clone(),
                    up_out.clone(),
                    stall,
                    queue,
                );
                relay_dir(ph, mac, down.clone(), down_out.clone(), stall, queue);
            }
        });
    }
    Ok(ProxyHandle {
        listen,
        up,
        down,
        up_out,
        down_out,
        connections,
    })
}

fn relay_dir(
    mut from: TcpStream,
    mut to: TcpStream,
    link: Arc<Mutex<Link>>,
    out: Arc<DirStats>,
    stall_ns: u64,
    queue_bytes: usize,
) {
    let (tx, rx) = mpsc::channel::<Option<(u64, Vec<u8>)>>();
    let (capped, loss_limit) = {
        let l = link.lock().unwrap();
        (l.cond.rate_mbps.is_some(), l.cond.tcp_loss_limit())
    };
    thread::spawn(move || {
        let mut buf = vec![0u8; 16 * 1024];
        let mut conn_prev = 0u64;
        // Per-connection pacing for the loss model (emulates a loss-limited cwnd).
        let mut conn_free = 0u64;
        loop {
            if capped {
                // Back-pressure: don't read while the shared bottleneck is full.
                while link.lock().unwrap().backlog_bytes(now_ns()) > queue_bytes {
                    thread::sleep(std::time::Duration::from_micros(100));
                }
            }
            if let Some((rate, window)) = loss_limit {
                // "cwnd": at most `window` bytes scheduled ahead of now on this connection;
                // the rest waits in the sender's socket buffer, as with real TCP.
                let ahead_ns = (window as f64 * 8.0 / rate * 1e9) as u64;
                while conn_free > now_ns() + ahead_ns {
                    thread::sleep(std::time::Duration::from_micros(100));
                }
            }
            let n = match from.read(&mut buf) {
                Ok(0) | Err(_) => {
                    let _ = tx.send(None);
                    return;
                }
                Ok(n) => n,
            };
            let now = now_ns();
            let mut l = link.lock().unwrap();
            for seg in buf[..n].chunks(SEG) {
                let v = match loss_limit {
                    Some((rate, _)) => {
                        let depart = conn_free.max(now) + (seg.len() as f64 * 8.0 / rate * 1e9) as u64;
                        conn_free = depart;
                        l.admit_ext(depart, seg.len(), false, false)
                    }
                    None => l.admit(now, seg.len(), false),
                };
                let t = match v {
                    Verdict::Deliver(t) => t,
                    Verdict::Lost(t) => t + stall_ns,
                    Verdict::QueueDrop => unreachable!("TCP relay never drop-tails"),
                };
                // TCP delivers in order per connection: a stalled segment holds back
                // everything behind it on *this* connection only.
                conn_prev = conn_prev.max(t);
                if tx.send(Some((conn_prev, seg.to_vec()))).is_err() {
                    return;
                }
            }
        }
    });
    thread::spawn(move || {
        let mut batch: Vec<u8> = Vec::with_capacity(256 * 1024);
        let mut peeked: Option<Option<(u64, Vec<u8>)>> = None;
        loop {
            let item = match peeked.take() {
                Some(i) => i,
                None => match rx.recv() {
                    Ok(i) => i,
                    Err(_) => return,
                },
            };
            let Some((t, data)) = item else {
                let _ = to.shutdown(Shutdown::Write);
                return;
            };
            thread_sleep_until_ns(t);
            batch.clear();
            batch.extend_from_slice(&data);
            // Coalesce whatever else is already due into one write (bounded).
            while batch.len() < 256 * 1024 {
                match rx.try_recv() {
                    Ok(Some((t2, d2))) if t2 <= now_ns() => batch.extend_from_slice(&d2),
                    Ok(other) => {
                        peeked = Some(other);
                        break;
                    }
                    Err(_) => break,
                }
            }
            if to.write_all(&batch).is_err() {
                return;
            }
            account(&out, &batch);
        }
    });
}

fn account(out: &DirStats, b: &[u8]) {
    out.pkts_out
        .fetch_add(b.len().div_ceil(SEG) as u64, Ordering::Relaxed);
    out.bytes_out.fetch_add(b.len() as u64, Ordering::Relaxed);
}
