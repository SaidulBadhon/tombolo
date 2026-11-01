// SPDX-License-Identifier: GPL-3.0-or-later
//! Spike S5 — iroh 1.4.1 / noq 1.4.0 API probe for Tombolo.
//!
//! Subcommands:
//!   probe api    [--preset tombolo|n0] [--bind any|loopback] [--hold SECS]
//!   probe tunnel [--mb N] [--mtu BYTES] [--role both|listen|connect] [--port P]
//!
//! `api` creates two endpoints in one process and connects them **by direct address only**,
//! then exercises the TLS exporter, streams (priority, reset, stop), RFC 9221 datagrams
//! and stats/RTT. With `--preset tombolo` (default) the endpoints have relays disabled,
//! no address lookup (DNS/pkarr/mDNS), no portmapper and a minimal net report. With
//! `--preset n0` they use iroh's public defaults — the *positive control* for the egress
//! check (it must show outbound traffic, proving the detector works).
//!
//! `tunnel` runs QUIC (iroh) over **one TCP stream** using the custom transport from the
//! `tcp-tunnel` crate — the adb-forward model for USB.

use std::{
    net::{Ipv4Addr, SocketAddr, SocketAddrV4},
    sync::{Arc, atomic::Ordering},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use bytes::Bytes;
use iroh::{
    Endpoint, EndpointAddr, SecretKey, TransportAddr,
    endpoint::{
        Builder, Connection, NetReportConfig, PathId, PortmapperConfig, QuicTransportConfig,
        ReadError, SendDatagramError, VarInt, presets,
    },
};
use tcp_tunnel::{TcpTunnelTransport, TunnelConfig, tunnel_addr};

const ALPN: &[u8] = b"tombolo/1";
const EXPORTER_LABEL: &[u8] = b"EXPORTER-tombolo-session-v0";

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1).cloned())
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "warn".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("api") => api(&args).await,
        Some("tunnel") => tunnel(&args).await,
        _ => {
            eprintln!("usage: probe api|tunnel [options]");
            std::process::exit(2)
        }
    }
}

/// Tombolo's endpoint configuration: nothing public, direct addresses only.
fn tombolo_builder() -> Builder {
    // `presets::Minimal` only sets the rustls crypto provider (ring). `Builder::empty()`
    // already means RelayMode::Disabled and no address lookup services.
    Endpoint::builder(presets::Minimal)
        .relay_mode(iroh::RelayMode::Disabled)
        .clear_address_lookup()
        .portmapper_config(PortmapperConfig::Disabled)
        .net_report_config(NetReportConfig::minimal())
}

fn print(k: &str, v: impl std::fmt::Display) {
    println!("RESULT {k}={v}");
}

async fn api(args: &[String]) -> Result<()> {
    let preset = arg(args, "--preset").unwrap_or_else(|| "tombolo".into());
    let bind = arg(args, "--bind").unwrap_or_else(|| "any".into());
    let hold: u64 = arg(args, "--hold").map(|s| s.parse()).transpose()?.unwrap_or(0);
    print("pid", std::process::id());
    print("preset", &preset);
    print("bind", &bind);

    let mk = |alpn: bool| -> Result<Builder> {
        let mut b = match preset.as_str() {
            "tombolo" => tombolo_builder(),
            "n0" => Endpoint::builder(presets::N0),
            other => bail!("unknown preset {other}"),
        };
        if bind == "loopback" {
            b = b.clear_ip_transports().bind_addr("127.0.0.1:0")?;
        }
        if alpn {
            b = b.alpns(vec![ALPN.to_vec()]);
        }
        Ok(b)
    };
    let server = mk(true)?.bind().await?;
    let client = mk(false)?.bind().await?;
    let port = server
        .bound_sockets()
        .into_iter()
        .find(|a| a.is_ipv4())
        .context("no ipv4 socket")?
        .port();
    let direct = SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port));
    print("server_bound", format!("{:?}", server.bound_sockets()));
    print("server_id", server.id());
    let addr = EndpointAddr::from_parts(server.id(), [TransportAddr::Ip(direct)]);

    // ---------------- server side ----------------
    let srv = server.clone();
    let server_task = tokio::spawn(async move {
        let incoming = srv.accept().await.context("endpoint closed")?;
        let conn: Connection = incoming.await?;
        // 1st bi stream: send our exporter output so the client can compare.
        let (mut s, mut r) = conn.accept_bi().await?;
        let _ = r.read_to_end(64).await?;
        let mut ekm = [0u8; 32];
        conn.export_keying_material(&mut ekm, EXPORTER_LABEL, b"pairing-transcript-hash")
            .map_err(|e| anyhow::anyhow!("exporter: {e:?}"))?;
        s.write_all(&ekm).await?;
        s.finish()?;
        // 2nd bi stream: echo.
        let (mut s, mut r) = conn.accept_bi().await?;
        let data = r.read_to_end(1 << 20).await?;
        s.write_all(&data).await?;
        s.finish()?;
        // uni stream that the client resets with code 42.
        let mut u = conn.accept_uni().await?;
        let mut buf = vec![0u8; 4096];
        let reset_code = loop {
            match u.read(&mut buf).await {
                Ok(Some(_)) => continue,
                Ok(None) => break None,
                Err(ReadError::Reset(code)) => break Some(code),
                Err(e) => return Err(e.into()),
            }
        };
        print("server_saw_reset_code", format!("{reset_code:?}"));
        // datagram echo forever (until close).
        loop {
            match conn.read_datagram().await {
                Ok(d) => {
                    let _ = conn.send_datagram(d);
                }
                Err(_) => break,
            }
        }
        anyhow::Ok(())
    });

    // ---------------- client side ----------------
    let t0 = Instant::now();
    let conn = client.connect(addr, ALPN).await?;
    print("connect_ms", format!("{:.2}", t0.elapsed().as_secs_f64() * 1e3));
    print("remote_id_matches", conn.remote_id() == server.id());
    print("alpn", String::from_utf8_lossy(conn.alpn()));

    // TLS exporter (RFC 5705 / RFC 8446 §7.5) on both sides must agree.
    let mut ekm = [0u8; 32];
    conn.export_keying_material(&mut ekm, EXPORTER_LABEL, b"pairing-transcript-hash")
        .map_err(|e| anyhow::anyhow!("exporter: {e:?}"))?;
    let (mut s, mut r) = conn.open_bi().await?;
    s.write_all(b"ekm?").await?;
    s.finish()?;
    let theirs = r.read_to_end(64).await?;
    print("exporter_client_prefix", hex(&ekm[..8]));
    print("exporter_match", theirs.as_slice() == ekm.as_slice());

    // Stream priority + echo.
    let (mut s, mut r) = conn.open_bi().await?;
    s.set_priority(7)?;
    print("stream_priority_roundtrip", s.priority()? == 7);
    let payload = vec![0xA5u8; 100_000];
    s.write_all(&payload).await?;
    s.finish()?;
    let echoed = r.read_to_end(1 << 20).await?;
    print("bi_echo_ok", echoed == payload);

    // Per-stream reset.
    let mut u = conn.open_uni().await?;
    u.write_all(&[1u8; 2000]).await?;
    u.reset(VarInt::from_u32(42))?;

    // Datagrams.
    let max = conn.max_datagram_size();
    print("max_datagram_size", format!("{max:?}"));
    print("datagram_send_buffer_space", conn.datagram_send_buffer_space());
    if let Some(max) = max {
        conn.send_datagram(Bytes::from(vec![9u8; max]))?;
        match tokio::time::timeout(Duration::from_secs(2), conn.read_datagram()).await {
            Ok(Ok(back)) => print("datagram_max_roundtrip_len", back.len()),
            other => print("datagram_max_roundtrip_len", format!("FAILED {other:?}")),
        }
        match conn.send_datagram(Bytes::from(vec![9u8; max + 1])) {
            Err(SendDatagramError::TooLarge) => print("datagram_oversize", "TooLarge"),
            other => print("datagram_oversize", format!("{other:?}")),
        }
    }
    // Small datagram RTT samples.
    let mut rtts = vec![];
    for i in 0..50u32 {
        let t = Instant::now();
        conn.send_datagram(Bytes::copy_from_slice(&i.to_be_bytes()))?;
        if let Ok(Ok(_)) = tokio::time::timeout(Duration::from_secs(1), conn.read_datagram()).await {
            rtts.push(t.elapsed().as_secs_f64() * 1e6);
        }
    }
    rtts.sort_by(|a, b| a.partial_cmp(b).unwrap());
    print("datagram_rtt_samples", rtts.len());
    if !rtts.is_empty() {
        print("datagram_app_rtt_us_p50", format!("{:.0}", rtts[rtts.len() / 2]));
    }

    // Stats / RTT.
    print("quic_rtt_path0", format!("{:?}", conn.rtt(PathId::ZERO)));
    let st = conn.stats();
    print("stats_sent_packets", st.sent_packets);
    print("stats_lost_packets", st.lost_packets);
    print("stats_udp_tx_bytes", st.udp_tx.bytes);
    for p in conn.paths().iter() {
        print(
            "path",
            format!(
                "id={:?} remote={:?} selected={} rtt={:?} cwnd={}",
                p.id(),
                p.remote_addr(),
                p.is_selected(),
                p.rtt(),
                p.stats().cwnd
            ),
        );
    }

    // Hold the connection open (keepalives flowing) so background tasks — net report,
    // address lookup, relay actors — get time to do whatever they would do.
    if hold > 0 {
        print("holding_secs", hold);
        let deadline = Instant::now() + Duration::from_secs(hold);
        while Instant::now() < deadline {
            conn.send_datagram(Bytes::from_static(b"keepalive"))?;
            let _ = tokio::time::timeout(Duration::from_secs(1), conn.read_datagram()).await;
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        for p in conn.paths().iter() {
            print(
                "path_after_hold",
                format!("remote={:?} selected={}", p.remote_addr(), p.is_selected()),
            );
        }
    }
    conn.close(0u32.into(), b"done");
    client.close().await;
    server.close().await;
    let _ = server_task.await;
    print("done", true);
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---------------------------------------------------------------------------------
// QUIC over one TCP stream (custom transport)
// ---------------------------------------------------------------------------------

fn tunnel_builder(secret: SecretKey, transport: Arc<TcpTunnelTransport>, mtu: u16) -> Builder {
    let mut tc = QuicTransportConfig::builder();
    if mtu > 0 {
        tc = tc.initial_mtu(mtu).mtu_discovery_config(None);
    }
    tombolo_builder()
        .secret_key(secret)
        .clear_ip_transports()
        .add_custom_transport(transport)
        .transport_config(tc.build())
}

async fn tunnel(args: &[String]) -> Result<()> {
    let role = arg(args, "--role").unwrap_or_else(|| "both".into());
    let mb: usize = arg(args, "--mb").map(|s| s.parse()).transpose()?.unwrap_or(256);
    let mtu: u16 = arg(args, "--mtu").map(|s| s.parse()).transpose()?.unwrap_or(0);
    let port: u16 = arg(args, "--port").map(|s| s.parse()).transpose()?.unwrap_or(0);
    let listen_key = SecretKey::from([7u8; 32]);
    let connect_key = SecretKey::from([8u8; 32]);
    print("pid", std::process::id());
    print("mtu", mtu);

    match role.as_str() {
        "both" => {
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
            let port = l.local_addr()?.port();
            let lk = listen_key.clone();
            let srv = tokio::spawn(async move { tunnel_listen(l, lk, mtu).await });
            tunnel_connect(port, listen_key.public(), connect_key, mtu, mb).await?;
            srv.await??;
        }
        "listen" => {
            let l = tokio::net::TcpListener::bind(("127.0.0.1", port)).await?;
            print("listening", l.local_addr()?);
            tunnel_listen(l, listen_key, mtu).await?;
        }
        "connect" => {
            tunnel_connect(port, listen_key.public(), connect_key, mtu, mb).await?;
        }
        r => bail!("unknown role {r}"),
    }
    Ok(())
}

/// "Phone" side: accepts the (adb-forwarded) TCP connection, then serves QUIC over it.
async fn tunnel_listen(l: tokio::net::TcpListener, key: SecretKey, mtu: u16) -> Result<()> {
    let (tcp, _) = l.accept().await?;
    let transport = TcpTunnelTransport::new(tcp, 0, TunnelConfig::default())?;
    let ep = tunnel_builder(key, transport.clone(), mtu)
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await?;
    let conn = ep.accept().await.context("closed")?.await?;
    let mut ekm = [0u8; 32];
    conn.export_keying_material(&mut ekm, EXPORTER_LABEL, b"ctx")
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    // control: echo pings on a bi stream
    let (mut cs, mut cr) = conn.accept_bi().await?;
    cs.write_all(&ekm).await?;
    let c2 = conn.clone();
    let echo = tokio::spawn(async move {
        let mut b = [0u8; 16];
        while cr.read_exact(&mut b).await.is_ok() {
            if cs.write_all(&b).await.is_err() {
                break;
            }
        }
        let _ = cs.finish();
    });
    // datagram echo
    let dg = tokio::spawn(async move {
        while let Ok(d) = c2.read_datagram().await {
            let _ = c2.send_datagram(d);
        }
    });
    // bulk sink
    let mut u = conn.accept_uni().await?;
    let mut total = 0usize;
    let mut buf = vec![0u8; 256 * 1024];
    while let Some(n) = u.read(&mut buf).await? {
        total += n;
    }
    print("listener_bulk_bytes", total);
    let _ = echo.await;
    conn.closed().await;
    dg.abort();
    print(
        "listener_tunnel_rx_packets",
        transport.stats.rx_packets.load(Ordering::Relaxed),
    );
    ep.close().await;
    Ok(())
}

/// "Mac" side: connects to the forwarded TCP port and runs QUIC over it.
async fn tunnel_connect(
    port: u16,
    listener_id: iroh::PublicKey,
    key: SecretKey,
    mtu: u16,
    mb: usize,
) -> Result<()> {
    let tcp = tokio::net::TcpStream::connect(("127.0.0.1", port)).await?;
    print("tcp_peer", tcp.peer_addr()?);
    let transport = TcpTunnelTransport::new(tcp, 1, TunnelConfig::default())?;
    let ep = tunnel_builder(key, transport.clone(), mtu).bind().await?;
    print("ip_sockets_bound", format!("{:?}", ep.bound_sockets()));
    let addr = EndpointAddr::from_parts(listener_id, [TransportAddr::Custom(tunnel_addr(0))]);
    let t0 = Instant::now();
    let conn = ep.connect(addr, ALPN).await?;
    print("tunnel_connect_ms", format!("{:.2}", t0.elapsed().as_secs_f64() * 1e3));
    for p in conn.paths().iter() {
        print(
            "tunnel_path",
            format!("remote={:?} selected={}", p.remote_addr(), p.is_selected()),
        );
    }
    let mut ekm = [0u8; 32];
    conn.export_keying_material(&mut ekm, EXPORTER_LABEL, b"ctx")
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    let (mut cs, mut cr) = conn.open_bi().await?;
    cs.set_priority(100)?;
    cs.write_all(&[0u8; 16]).await?; // opens the stream on the wire
    let mut theirs = [0u8; 32];
    cr.read_exact(&mut theirs).await?;
    let mut first = [0u8; 16];
    cr.read_exact(&mut first).await?;
    print("tunnel_exporter_match", theirs == ekm);
    print("tunnel_max_datagram_size", format!("{:?}", conn.max_datagram_size()));

    // Idle RTT: control-stream ping-pong and datagram ping-pong.
    let idle = ping_series(&mut cs, &mut cr, 200, Duration::from_millis(2)).await?;
    print("tunnel_idle_stream_rtt_us", summary(&idle));
    let mut d = vec![];
    for i in 0..200u32 {
        let t = Instant::now();
        conn.send_datagram(Bytes::copy_from_slice(&i.to_be_bytes()))?;
        let _ = tokio::time::timeout(Duration::from_secs(1), conn.read_datagram()).await??;
        d.push(t.elapsed().as_secs_f64() * 1e6);
    }
    print("tunnel_idle_datagram_rtt_us", summary(&d));

    // Bulk throughput on a low-priority uni stream, with control pings running alongside.
    let c2 = conn.clone();
    let bulk = tokio::spawn(async move {
        let mut u = c2.open_uni().await?;
        u.set_priority(-10)?;
        let chunk = Bytes::from(vec![0x5Au8; 1 << 20]);
        let t = Instant::now();
        for _ in 0..mb {
            u.write_chunk(chunk.clone()).await?;
        }
        u.finish()?;
        let _ = u.stopped().await;
        anyhow::Ok(t.elapsed())
    });
    // Ping only while the bulk transfer is in flight.
    let mut loaded = vec![];
    let mut b = [0u8; 16];
    let mut i = 0u64;
    while !bulk.is_finished() {
        let t = Instant::now();
        cs.write_all(&i.to_be_bytes().repeat(2)).await?;
        cr.read_exact(&mut b).await?;
        loaded.push(t.elapsed().as_secs_f64() * 1e6);
        i += 1;
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    let elapsed = bulk.await??;
    print("tunnel_loaded_ping_samples", loaded.len());
    let mbps = (mb as f64 * 8.0 * 1.048576) / elapsed.as_secs_f64();
    print("tunnel_bulk_mb", mb);
    print("tunnel_bulk_secs", format!("{:.3}", elapsed.as_secs_f64()));
    print("tunnel_bulk_mbit_s", format!("{mbps:.0}"));
    print("tunnel_loaded_stream_rtt_us", summary(&loaded));
    let st = conn.stats();
    print("tunnel_quic_lost_packets", st.lost_packets);
    print("tunnel_quic_sent_packets", st.sent_packets);
    print(
        "tunnel_tx_dropped",
        transport.stats.tx_dropped.load(Ordering::Relaxed),
    );
    print(
        "tunnel_tx_packets",
        transport.stats.tx_packets.load(Ordering::Relaxed),
    );
    cs.finish()?;
    tokio::time::sleep(Duration::from_millis(100)).await;
    conn.close(0u32.into(), b"done");
    ep.close().await;
    print("done", true);
    Ok(())
}

async fn ping_series(
    s: &mut iroh::endpoint::SendStream,
    r: &mut iroh::endpoint::RecvStream,
    n: usize,
    gap: Duration,
) -> Result<Vec<f64>> {
    let mut out = Vec::with_capacity(n);
    let mut b = [0u8; 16];
    for i in 0..n as u64 {
        let t = Instant::now();
        s.write_all(&i.to_be_bytes().repeat(2)).await?;
        r.read_exact(&mut b).await?;
        out.push(t.elapsed().as_secs_f64() * 1e6);
        tokio::time::sleep(gap).await;
    }
    Ok(out)
}

fn summary(v: &[f64]) -> String {
    let mut v = v.to_vec();
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let q = |p: f64| v[((v.len() as f64 - 1.0) * p).round() as usize];
    format!("p50={:.0} p95={:.0} p99={:.0} max={:.0}", q(0.5), q(0.95), q(0.99), v[v.len() - 1])
}
