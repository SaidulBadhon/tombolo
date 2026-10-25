//! Transport setup. Three ways to carry the same four channels (control, video, audio,
//! bulk) between "phone" (listener, media sender) and "Mac" (connector, controller):
//!
//! * `quic`   — iroh/noq over UDP: 1 bidi stream (control), 2 uni streams (video, bulk)
//!              with priorities, RFC 9221 datagrams for audio.
//! * `tcp`    — TLS 1.3 (rustls, ring) over TCP, one connection per channel; audio is a
//!              length-prefixed stream on its own connection.
//! * `tunnel` — the `quic` layout, but QUIC packets ride length-prefixed on ONE TCP
//!              connection (iroh custom transport) — the adb-forward USB model.

use std::{net::SocketAddr, path::Path, sync::Arc};

use anyhow::{Context, Result, bail};
use iroh::{
    Endpoint, EndpointAddr, SecretKey, TransportAddr,
    endpoint::{Builder, Connection, NetReportConfig, PortmapperConfig, presets},
};
use tcp_tunnel::{TcpTunnelTransport, TunnelConfig, tcp_notsent_lowat, tunnel_addr};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

pub const ALPN: &[u8] = b"tombolo/1";
pub const NOTSENT_LOWAT: u32 = 128 * 1024;

pub type BoxR = Box<dyn AsyncRead + Unpin + Send>;
pub type BoxW = Box<dyn AsyncWrite + Unpin + Send>;

pub enum AudioTx {
    Dgram(Connection),
    Stream(BoxW),
}
pub enum AudioRx {
    Dgram(Connection),
    Stream(BoxR),
}

pub struct PhoneCh {
    pub ctrl_r: BoxR,
    pub ctrl_w: BoxW,
    pub video: BoxW,
    pub audio: AudioTx,
    pub bulk: BoxW,
    pub keep: Keep,
}

pub struct MacCh {
    pub ctrl_r: BoxR,
    pub ctrl_w: BoxW,
    pub video: BoxR,
    pub audio: AudioRx,
    pub bulk: BoxR,
    pub keep: Keep,
}

pub enum Keep {
    Quic {
        ep: Endpoint,
        conn: Connection,
        tunnel: Option<Arc<TcpTunnelTransport>>,
    },
    Tcp,
}

impl Keep {
    pub fn json(&self) -> serde_json::Value {
        match self {
            Keep::Tcp => serde_json::json!({}),
            Keep::Quic { conn, tunnel, .. } => {
                let st = conn.stats();
                let paths: Vec<String> = conn
                    .paths()
                    .iter()
                    .map(|p| {
                        format!(
                            "{:?} selected={} rtt={:?} cwnd={}",
                            p.remote_addr(),
                            p.is_selected(),
                            p.rtt(),
                            p.stats().cwnd
                        )
                    })
                    .collect();
                let mut v = serde_json::json!({
                    "quic_sent_packets": st.sent_packets,
                    "quic_lost_packets": st.lost_packets,
                    "quic_lost_bytes": st.lost_bytes,
                    "quic_udp_tx_bytes": st.udp_tx.bytes,
                    "quic_udp_rx_bytes": st.udp_rx.bytes,
                    "paths": paths,
                });
                if let Some(t) = tunnel {
                    use std::sync::atomic::Ordering::Relaxed;
                    v["tunnel_tx_packets"] = t.stats.tx_packets.load(Relaxed).into();
                    v["tunnel_tx_dropped"] = t.stats.tx_dropped.load(Relaxed).into();
                }
                v
            }
        }
    }

    pub async fn close(&self) {
        if let Keep::Quic { ep, conn, .. } = self {
            conn.close(0u32.into(), b"done");
            let _ = tokio::time::timeout(std::time::Duration::from_secs(2), ep.close()).await;
        }
    }
}

/// Congestion controller for QUIC endpoints, from `S4_CC` (cubic = noq default).
fn transport_config() -> iroh::endpoint::QuicTransportConfig {
    let b = iroh::endpoint::QuicTransportConfig::builder();
    match std::env::var("S4_CC").as_deref() {
        Ok("bbr3") => b.congestion_controller_factory(Arc::new(
            noq_proto::congestion::Bbr3Config::default(),
        )),
        Ok("newreno") => b.congestion_controller_factory(Arc::new(
            noq_proto::congestion::NewRenoConfig::default(),
        )),
        _ => b,
    }
    .build()
}

fn tombolo_builder(secret: SecretKey) -> Builder {
    Endpoint::builder(presets::Minimal)
        .transport_config(transport_config())
        .secret_key(secret)
        .relay_mode(iroh::RelayMode::Disabled)
        .clear_address_lookup()
        .portmapper_config(PortmapperConfig::Disabled)
        .net_report_config(NetReportConfig::minimal())
        .clear_ip_transports()
}

pub fn phone_key() -> SecretKey {
    SecretKey::from([7u8; 32])
}
fn mac_key() -> SecretKey {
    SecretKey::from([8u8; 32])
}

// ------------------------------------------------------------------------------------
// Phone (listener)
// ------------------------------------------------------------------------------------

pub enum PhoneListener {
    Quic(Endpoint),
    Tunnel(TcpListener, TunnelConfig),
    Tcp(TcpListener, tokio_rustls::TlsAcceptor),
    RawTcp(TcpListener),
}

fn tunnel_cfg(kind: &str) -> TunnelConfig {
    if kind == "tunnel-lean" {
        TunnelConfig::lean()
    } else {
        TunnelConfig::default()
    }
}

impl PhoneListener {
    pub async fn bind(kind: &str, cert_dir: &Path) -> Result<(Self, SocketAddr)> {
        Ok(match kind {
            "quic" => {
                // IPv6 loopback only (the Mac side is IPv4 only) — see proxy.rs.
                let ep = tombolo_builder(phone_key())
                    .bind_addr("[::1]:0")?
                    .alpns(vec![ALPN.to_vec()])
                    .bind()
                    .await?;
                let a = ep.bound_sockets()[0];
                (PhoneListener::Quic(ep), a)
            }
            "tunnel" | "tunnel-lean" => {
                let l = TcpListener::bind("127.0.0.1:0").await?;
                let a = l.local_addr()?;
                (PhoneListener::Tunnel(l, tunnel_cfg(kind)), a)
            }
            "rawtcp" => {
                let l = TcpListener::bind("127.0.0.1:0").await?;
                let a = l.local_addr()?;
                (PhoneListener::RawTcp(l), a)
            }
            "tcp" => {
                let l = TcpListener::bind("127.0.0.1:0").await?;
                let a = l.local_addr()?;
                (PhoneListener::Tcp(l, tls_acceptor(cert_dir)?), a)
            }
            k => bail!("unknown transport {k}"),
        })
    }

    pub async fn accept(self) -> Result<PhoneCh> {
        match self {
            PhoneListener::Quic(ep) => quic_phone(ep, None).await,
            PhoneListener::Tunnel(l, cfg) => {
                let (tcp, _) = l.accept().await?;
                let t = TcpTunnelTransport::new(tcp, 0, cfg)?;
                let ep = tombolo_builder(phone_key())
                    .add_custom_transport(t.clone())
                    .alpns(vec![ALPN.to_vec()])
                    .bind()
                    .await?;
                quic_phone(ep, Some(t)).await
            }
            PhoneListener::RawTcp(l) => {
                // scrcpy-style baseline: plain TCP per channel, no TLS.
                let mut slots: [Option<TcpStream>; 4] = Default::default();
                for _ in 0..4 {
                    let (mut tcp, _) = l.accept().await?;
                    tcp.set_nodelay(true)?;
                    tcp_notsent_lowat(&tcp, NOTSENT_LOWAT)?;
                    let tag = tcp.read_u8().await?;
                    slots[tag_index(tag)?] = Some(tcp);
                }
                let [c, v, a, b] = slots.map(|s| s.expect("channel missing"));
                let (cr, cw) = c.into_split();
                Ok(PhoneCh {
                    ctrl_r: Box::new(cr),
                    ctrl_w: Box::new(cw),
                    video: Box::new(v),
                    audio: AudioTx::Stream(Box::new(a)),
                    bulk: Box::new(b),
                    keep: Keep::Tcp,
                })
            }
            PhoneListener::Tcp(l, acc) => {
                let mut slots: [Option<tokio_rustls::server::TlsStream<TcpStream>>; 4] =
                    Default::default();
                for _ in 0..4 {
                    let (tcp, _) = l.accept().await?;
                    tcp.set_nodelay(true)?;
                    tcp_notsent_lowat(&tcp, NOTSENT_LOWAT)?;
                    let mut tls = acc.accept(tcp).await?;
                    let tag = tls.read_u8().await?;
                    let i = tag_index(tag)?;
                    slots[i] = Some(tls);
                }
                let [c, v, a, b] = slots.map(|s| s.expect("channel missing"));
                let (cr, cw) = tokio::io::split(c);
                Ok(PhoneCh {
                    ctrl_r: Box::new(cr),
                    ctrl_w: Box::new(cw),
                    video: Box::new(v),
                    audio: AudioTx::Stream(Box::new(a)),
                    bulk: Box::new(b),
                    keep: Keep::Tcp,
                })
            }
        }
    }
}

fn tag_index(tag: u8) -> Result<usize> {
    Ok(match tag {
        b'C' => 0,
        b'V' => 1,
        b'A' => 2,
        b'B' => 3,
        t => bail!("bad channel tag {t}"),
    })
}

async fn quic_phone(ep: Endpoint, tunnel: Option<Arc<TcpTunnelTransport>>) -> Result<PhoneCh> {
    let conn = ep.accept().await.context("closed")?.await?;
    let (cw, mut cr) = conn.accept_bi().await?;
    let tag = cr.read_u8().await?;
    if tag != b'C' {
        bail!("expected control stream");
    }
    cw.set_priority(10)?;
    let mut v = conn.open_uni().await?;
    v.set_priority(5)?;
    v.write_all(b"V").await?;
    let mut b = conn.open_uni().await?;
    b.set_priority(-10)?;
    b.write_all(b"B").await?;
    Ok(PhoneCh {
        ctrl_r: Box::new(cr),
        ctrl_w: Box::new(cw),
        video: Box::new(v),
        audio: AudioTx::Dgram(conn.clone()),
        bulk: Box::new(b),
        keep: Keep::Quic { ep, conn, tunnel },
    })
}

// ------------------------------------------------------------------------------------
// Mac (connector)
// ------------------------------------------------------------------------------------

pub async fn mac_connect(kind: &str, addr: SocketAddr, cert_dir: &Path) -> Result<MacCh> {
    match kind {
        "quic" => {
            let ep = tombolo_builder(mac_key()).bind_addr("127.0.0.1:0")?.bind().await?;
            let ea = EndpointAddr::from_parts(phone_key().public(), [TransportAddr::Ip(addr)]);
            let conn = ep.connect(ea, ALPN).await?;
            quic_mac(ep, conn, None).await
        }
        "tunnel" | "tunnel-lean" => {
            let tcp = TcpStream::connect(addr).await?;
            let t = TcpTunnelTransport::new(tcp, 1, tunnel_cfg(kind))?;
            let ep = tombolo_builder(mac_key())
                .add_custom_transport(t.clone())
                .bind()
                .await?;
            let ea = EndpointAddr::from_parts(
                phone_key().public(),
                [TransportAddr::Custom(tunnel_addr(0))],
            );
            let conn = ep.connect(ea, ALPN).await?;
            quic_mac(ep, conn, Some(t)).await
        }
        "rawtcp" => {
            let mut out: Vec<TcpStream> = vec![];
            for tag in [b'C', b'V', b'A', b'B'] {
                let mut tcp = TcpStream::connect(addr).await?;
                tcp.set_nodelay(true)?;
                tcp_notsent_lowat(&tcp, NOTSENT_LOWAT)?;
                tcp.write_u8(tag).await?;
                out.push(tcp);
            }
            let b = out.pop().unwrap();
            let a = out.pop().unwrap();
            let v = out.pop().unwrap();
            let (cr, cw) = out.pop().unwrap().into_split();
            Ok(MacCh {
                ctrl_r: Box::new(cr),
                ctrl_w: Box::new(cw),
                video: Box::new(v),
                audio: AudioRx::Stream(Box::new(a)),
                bulk: Box::new(b),
                keep: Keep::Tcp,
            })
        }
        "tcp" => {
            let cx = tls_connector(cert_dir)?;
            let mut out: Vec<tokio_rustls::client::TlsStream<TcpStream>> = vec![];
            for tag in [b'C', b'V', b'A', b'B'] {
                let tcp = TcpStream::connect(addr).await?;
                tcp.set_nodelay(true)?;
                tcp_notsent_lowat(&tcp, NOTSENT_LOWAT)?;
                let name = rustls::pki_types::ServerName::try_from("localhost")?.to_owned();
                let mut tls = cx.connect(name, tcp).await?;
                tls.write_u8(tag).await?;
                tls.flush().await?;
                out.push(tls);
            }
            let b = out.pop().unwrap();
            let a = out.pop().unwrap();
            let v = out.pop().unwrap();
            let c = out.pop().unwrap();
            let (cr, cw) = tokio::io::split(c);
            Ok(MacCh {
                ctrl_r: Box::new(cr),
                ctrl_w: Box::new(cw),
                video: Box::new(v),
                audio: AudioRx::Stream(Box::new(a)),
                bulk: Box::new(b),
                keep: Keep::Tcp,
            })
        }
        k => bail!("unknown transport {k}"),
    }
}

async fn quic_mac(
    ep: Endpoint,
    conn: Connection,
    tunnel: Option<Arc<TcpTunnelTransport>>,
) -> Result<MacCh> {
    let (mut cw, cr) = conn.open_bi().await?;
    cw.set_priority(10)?;
    cw.write_all(b"C").await?;
    let mut video = None;
    let mut bulk = None;
    for _ in 0..2 {
        let mut u = conn.accept_uni().await?;
        match u.read_u8().await? {
            b'V' => video = Some(u),
            b'B' => bulk = Some(u),
            t => bail!("bad uni tag {t}"),
        }
    }
    Ok(MacCh {
        ctrl_r: Box::new(cr),
        ctrl_w: Box::new(cw),
        video: Box::new(video.context("no video")?),
        audio: AudioRx::Dgram(conn.clone()),
        bulk: Box::new(bulk.context("no bulk")?),
        keep: Keep::Quic { ep, conn, tunnel },
    })
}

// ------------------------------------------------------------------------------------
// TLS (rustls + ring, TLS 1.3 only — same provider iroh uses)
// ------------------------------------------------------------------------------------

pub fn write_test_cert(dir: &Path) -> Result<()> {
    let ck = rcgen::generate_simple_self_signed(vec!["localhost".to_string()])?;
    std::fs::write(dir.join("cert.der"), ck.cert.der())?;
    std::fs::write(dir.join("key.der"), ck.signing_key.serialize_der())?;
    Ok(())
}

fn provider() -> Arc<rustls::crypto::CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn tls_acceptor(dir: &Path) -> Result<tokio_rustls::TlsAcceptor> {
    let cert = rustls::pki_types::CertificateDer::from(std::fs::read(dir.join("cert.der"))?);
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(
        std::fs::read(dir.join("key.der"))?.into(),
    );
    let cfg = rustls::ServerConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)?;
    Ok(tokio_rustls::TlsAcceptor::from(Arc::new(cfg)))
}

fn tls_connector(dir: &Path) -> Result<tokio_rustls::TlsConnector> {
    let cert = rustls::pki_types::CertificateDer::from(std::fs::read(dir.join("cert.der"))?);
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert)?;
    let cfg = rustls::ClientConfig::builder_with_provider(provider())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(tokio_rustls::TlsConnector::from(Arc::new(cfg)))
}
