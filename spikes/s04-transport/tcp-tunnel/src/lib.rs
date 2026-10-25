//! Spike: an iroh **custom transport** that carries QUIC packets over one TCP stream.
//!
//! This models Tombolo's USB path: `adb forward` only carries TCP, so QUIC packets are
//! framed as `u16 big-endian length || packet` on a single TCP connection (research 04,
//! §2.5 / open question P1).
//!
//! Uses iroh's `unstable-custom-transports` feature (iroh 1.4.1:
//! `iroh::endpoint::transports::{CustomTransport, CustomEndpoint, CustomSender}`), which
//! is explicitly *not* covered by semver.
//!
//! Send-side policy: packets go into a bounded queue in front of the TCP socket. When the
//! queue is full the packet is **dropped**, exactly like a full UDP socket buffer, so that
//! QUIC's congestion controller sees loss instead of an ever-growing FIFO below its
//! stream scheduler. `TCP_NODELAY` is set; `TCP_NOTSENT_LOWAT` keeps the kernel's unsent
//! backlog small.

use std::{
    io,
    num::NonZeroUsize,
    os::fd::AsRawFd,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    task::{Context, Poll},
};

use bytes::{Bytes, BytesMut};
use iroh::endpoint::transports::{
    CustomEndpoint, CustomSender, CustomTransport, RecvInfo, Transmit,
};
use iroh_base::CustomAddr;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader, BufWriter},
    net::TcpStream,
    sync::mpsc,
};

/// Transport id used in [`CustomAddr`]s for this spike ("tomb").
pub const TUNNEL_TRANSPORT_ID: u64 = 0x746f_6d62;

/// The custom address of a tunnel side. Only two exist: 0 = listener side
/// ("phone"), 1 = connector side ("Mac").
pub fn tunnel_addr(side: u8) -> CustomAddr {
    CustomAddr::from_parts(TUNNEL_TRANSPORT_ID, &[side])
}

/// Counters shared with the caller for reporting.
#[derive(Debug, Default)]
pub struct TunnelStats {
    pub tx_packets: AtomicU64,
    pub tx_bytes: AtomicU64,
    pub tx_dropped: AtomicU64,
    pub rx_packets: AtomicU64,
    pub rx_bytes: AtomicU64,
}

#[derive(Debug, Clone, Copy)]
pub struct TunnelConfig {
    /// Packets that may wait in front of the TCP socket before new ones are dropped.
    pub send_queue_packets: usize,
    /// `TCP_NOTSENT_LOWAT` in bytes (0 = leave the OS default).
    pub notsent_lowat: u32,
}

impl Default for TunnelConfig {
    fn default() -> Self {
        Self {
            send_queue_packets: 128,
            notsent_lowat: 128 * 1024,
        }
    }
}

/// A connected TCP stream turned into an iroh custom transport.
#[derive(Debug)]
pub struct TcpTunnelTransport {
    local: CustomAddr,
    remote: CustomAddr,
    inner: std::sync::Mutex<Option<(mpsc::Sender<Bytes>, mpsc::Receiver<Bytes>)>>,
    pub stats: Arc<TunnelStats>,
}

impl TcpTunnelTransport {
    /// `side`: 0 = listener ("phone"), 1 = connector ("Mac").
    pub fn new(stream: TcpStream, side: u8, cfg: TunnelConfig) -> io::Result<Arc<Self>> {
        stream.set_nodelay(true)?;
        if cfg.notsent_lowat > 0 {
            set_notsent_lowat(&stream, cfg.notsent_lowat)?;
        }
        let stats = Arc::new(TunnelStats::default());
        let (rd, wr) = stream.into_split();
        let (tx_out, mut rx_out) = mpsc::channel::<Bytes>(cfg.send_queue_packets);
        let (tx_in, rx_in) = mpsc::channel::<Bytes>(1024);

        // Writer: drain the queue, batch into one buffered write, flush when idle.
        tokio::spawn(async move {
            let mut w = BufWriter::with_capacity(256 * 1024, wr);
            while let Some(pkt) = rx_out.recv().await {
                if write_frame(&mut w, &pkt).await.is_err() {
                    return;
                }
                while let Ok(pkt) = rx_out.try_recv() {
                    if write_frame(&mut w, &pkt).await.is_err() {
                        return;
                    }
                }
                if w.flush().await.is_err() {
                    return;
                }
            }
        });

        // Reader: parse length-prefixed frames into packets.
        let rstats = stats.clone();
        tokio::spawn(async move {
            let mut r = BufReader::with_capacity(256 * 1024, rd);
            loop {
                let len = match r.read_u16().await {
                    Ok(l) => l as usize,
                    Err(_) => return,
                };
                let mut buf = BytesMut::zeroed(len);
                if r.read_exact(&mut buf).await.is_err() {
                    return;
                }
                rstats.rx_packets.fetch_add(1, Ordering::Relaxed);
                rstats.rx_bytes.fetch_add(len as u64, Ordering::Relaxed);
                if tx_in.send(buf.freeze()).await.is_err() {
                    return;
                }
            }
        });

        Ok(Arc::new(Self {
            local: tunnel_addr(side),
            remote: tunnel_addr(1 - side),
            inner: std::sync::Mutex::new(Some((tx_out, rx_in))),
            stats,
        }))
    }

    pub fn remote_addr(&self) -> CustomAddr {
        self.remote.clone()
    }
}

async fn write_frame<W: tokio::io::AsyncWrite + Unpin>(w: &mut W, pkt: &[u8]) -> io::Result<()> {
    w.write_u16(pkt.len() as u16).await?;
    w.write_all(pkt).await
}

fn set_notsent_lowat(stream: &TcpStream, bytes: u32) -> io::Result<()> {
    // TCP_NOTSENT_LOWAT is 0x201 on Darwin (netinet/tcp.h) and 25 on Linux/Android;
    // the libc crate does not export the Darwin value.
    #[cfg(target_vendor = "apple")]
    const TCP_NOTSENT_LOWAT: libc::c_int = 0x201;
    #[cfg(not(target_vendor = "apple"))]
    const TCP_NOTSENT_LOWAT: libc::c_int = 25;
    let v: libc::c_int = bytes as libc::c_int;
    // SAFETY: valid fd owned by `stream`, pointer/len describe a live c_int.
    let rc = unsafe {
        libc::setsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_TCP,
            TCP_NOTSENT_LOWAT,
            &v as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Public helper so the benchmark can apply the same socket option to its TLS/TCP channels.
pub fn tcp_notsent_lowat(stream: &TcpStream, bytes: u32) -> io::Result<()> {
    set_notsent_lowat(stream, bytes)
}

impl CustomTransport for TcpTunnelTransport {
    fn bind(&self) -> io::Result<Box<dyn CustomEndpoint>> {
        let (tx, rx) = self
            .inner
            .lock()
            .unwrap()
            .take()
            .ok_or_else(|| io::Error::other("tunnel transport can only be bound once"))?;
        Ok(Box::new(TunnelEndpoint {
            local: self.local.clone(),
            remote: self.remote.clone(),
            addrs: n0_watcher::Watchable::new(vec![self.local.clone()]),
            tx,
            rx,
            stats: self.stats.clone(),
        }))
    }
}

#[derive(Debug)]
struct TunnelEndpoint {
    local: CustomAddr,
    remote: CustomAddr,
    addrs: n0_watcher::Watchable<Vec<CustomAddr>>,
    tx: mpsc::Sender<Bytes>,
    rx: mpsc::Receiver<Bytes>,
    stats: Arc<TunnelStats>,
}

#[derive(Debug)]
struct TunnelSender {
    remote: CustomAddr,
    tx: mpsc::Sender<Bytes>,
    stats: Arc<TunnelStats>,
}

impl CustomEndpoint for TunnelEndpoint {
    fn watch_local_addrs(&self) -> n0_watcher::Direct<Vec<CustomAddr>> {
        self.addrs.watch()
    }

    fn create_sender(&self) -> Arc<dyn CustomSender> {
        Arc::new(TunnelSender {
            remote: self.remote.clone(),
            tx: self.tx.clone(),
            stats: self.stats.clone(),
        })
    }

    fn poll_recv(
        &mut self,
        cx: &mut Context,
        bufs: &mut [io::IoSliceMut<'_>],
        metas: &mut [noq_udp::RecvMeta],
        recv_infos: &mut [RecvInfo],
    ) -> Poll<io::Result<usize>> {
        let n = bufs.len().min(metas.len()).min(recv_infos.len());
        if n == 0 {
            return Poll::Ready(Ok(0));
        }
        let mut filled = 0;
        while filled < n {
            let pkt = if filled == 0 {
                match self.rx.poll_recv(cx) {
                    Poll::Pending => return Poll::Pending,
                    Poll::Ready(None) => {
                        return Poll::Ready(Err(io::Error::other("tunnel closed")));
                    }
                    Poll::Ready(Some(p)) => p,
                }
            } else {
                match self.rx.try_recv() {
                    Ok(p) => p,
                    Err(_) => break,
                }
            };
            let buf = &mut bufs[filled];
            if buf.len() < pkt.len() {
                // Larger than the receive buffer: drop it like a truncated UDP datagram.
                tracing::warn!(len = pkt.len(), buf = buf.len(), "tunnel packet too large");
                continue;
            }
            buf[..pkt.len()].copy_from_slice(&pkt);
            metas[filled].len = pkt.len();
            metas[filled].stride = pkt.len();
            recv_infos[filled] = RecvInfo::new(self.remote.clone(), Some(self.local.clone()));
            filled += 1;
        }
        if filled == 0 {
            // Only oversize packets were available; ask to be polled again.
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        Poll::Ready(Ok(filled))
    }

    fn max_transmit_segments(&self) -> NonZeroUsize {
        NonZeroUsize::MIN
    }
}

impl CustomSender for TunnelSender {
    fn is_valid_send_addr(&self, addr: &CustomAddr) -> bool {
        addr == &self.remote
    }

    fn poll_send(
        &self,
        _cx: &mut Context,
        dst: &CustomAddr,
        _src: Option<&CustomAddr>,
        transmit: &Transmit<'_>,
    ) -> Poll<io::Result<()>> {
        if dst != &self.remote {
            return Poll::Ready(Err(io::Error::other("unknown tunnel destination")));
        }
        let seg = transmit.segment_size.unwrap_or(transmit.contents.len());
        for chunk in transmit.contents.chunks(seg.max(1)) {
            match self.tx.try_send(Bytes::copy_from_slice(chunk)) {
                Ok(()) => {
                    self.stats.tx_packets.fetch_add(1, Ordering::Relaxed);
                    self.stats
                        .tx_bytes
                        .fetch_add(chunk.len() as u64, Ordering::Relaxed);
                }
                Err(mpsc::error::TrySendError::Full(_)) => {
                    self.stats.tx_dropped.fetch_add(1, Ordering::Relaxed);
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    return Poll::Ready(Err(io::Error::other("tunnel closed")));
                }
            }
        }
        Poll::Ready(Ok(()))
    }
}
