// SPDX-License-Identifier: GPL-3.0-or-later
//! Media payload delivery across the FFI — seven designs, one simulated producer.
//!
//! The producer thread stands in for the QUIC receive task: per frame it performs exactly one
//! "reassembly" copy from a static receive buffer into the frame's destination (a fresh `Vec`, a
//! `Box` owned by a `FrameHandle`, or a slot in the shared ring). That copy is common to every
//! design; what differs is what happens *after* it, at the FFI boundary:
//!
//! | design        | Rust -> Swift                                   | payload copies at the FFI |
//! |---------------|-------------------------------------------------|---------------------------|
//! | VecPull       | blocking `next_vec()` returns `VecFrame{data: Vec<u8>}` | 3 (see doc)       |
//! | VecAsync      | `async next_vec_async()` returns the same       | 3                         |
//! | VecCallback   | Rust thread calls `FrameSink.on_frame(VecFrame)`| 3                         |
//! | HandlePull    | blocking `next_handle()` returns `FrameRef{handle, ptr, len}` | 0           |
//! | RingPull      | blocking `ring_wait(next)` returns head; Swift reads slot descriptors + payload in the shared region | 0 |
//! | RingAsync     | `async ring_wait_async(next)`                   | 0                         |
//! | RingCallback  | Rust thread calls `SlotSink.on_slots(from, to)` | 0                         |
//!
//! Every payload carries a 32-byte header `seq | address of the Rust buffer | len | MAGIC` and a
//! trailing `seq`, so Swift can prove (by comparing addresses) whether it is reading Rust's memory
//! or a copy, and detect torn/overwritten frames.

use std::alloc::{Layout, alloc_zeroed, dealloc};
use std::collections::VecDeque;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use parking_lot::{Condvar, Mutex};

use crate::CoreError;
use crate::util::now_ns;

pub const HEADER_LEN: u64 = 32;
pub const MAGIC: u64 = 0x5331_305f_4652_414d; // "S10_FRAM"
const DESC_STRIDE: u32 = 128;

static LIVE_HANDLES: AtomicI64 = AtomicI64::new(0);

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Delivery {
    VecPull,
    VecAsync,
    VecCallback,
    HandlePull,
    RingPull,
    RingAsync,
    RingCallback,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct StreamConfig {
    /// Frames per second; 0 = unpaced.
    pub fps: u32,
    pub frame_count: u64,
    pub p_frame_min: u32,
    pub p_frame_max: u32,
    pub keyframe_bytes: u32,
    /// Keyframe every N frames (0 = never).
    pub keyframe_interval: u32,
    /// Produce every frame before delivery starts (throughput benchmark: isolates consumer cost).
    pub prefill: bool,
    pub ring_bytes: u64,
    pub ring_slots: u32,
    /// Max queued frames for the Vec/handle designs before the producer drops (paced mode).
    pub queue_depth: u32,
    pub seed: u64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct FrameFormat {
    pub header_len: u64,
    pub magic: u64,
    pub desc_stride: u32,
}

#[uniffi::export]
pub fn frame_format() -> FrameFormat {
    FrameFormat { header_len: HEADER_LEN, magic: MAGIC, desc_stride: DESC_STRIDE }
}

#[derive(uniffi::Record)]
pub struct VecFrame {
    pub seq: u64,
    pub produced_ns: u64,
    /// Stamped by Rust at hand-off to Swift (after the consumer woke up, before lowering).
    pub delivered_ns: u64,
    pub is_key: bool,
    pub data: Vec<u8>,
}

/// Owns one frame's bytes. Swift keeps the object alive while it uses `ptr`; when Swift releases
/// it, UniFFI calls Rust's free and the buffer is dropped — refcounted zero-copy.
#[derive(uniffi::Object)]
pub struct FrameHandle {
    buf: Box<[u8]>,
}

#[uniffi::export]
impl FrameHandle {
    pub fn len(&self) -> u64 {
        self.buf.len() as u64
    }
    pub fn ptr(&self) -> u64 {
        self.buf.as_ptr() as u64
    }
}

impl Drop for FrameHandle {
    fn drop(&mut self) {
        LIVE_HANDLES.fetch_sub(1, Ordering::Relaxed);
    }
}

#[uniffi::export]
pub fn live_frame_handles() -> i64 {
    LIVE_HANDLES.load(Ordering::Relaxed)
}

#[derive(uniffi::Record)]
pub struct FrameRef {
    pub handle: Arc<FrameHandle>,
    pub seq: u64,
    pub produced_ns: u64,
    pub delivered_ns: u64,
    pub is_key: bool,
    pub ptr: u64,
    pub len: u64,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct RingLayout {
    pub data_base: u64,
    pub data_len: u64,
    pub desc_base: u64,
    pub desc_count: u32,
    pub desc_stride: u32,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct StreamStats {
    pub produced: u64,
    pub dropped_full: u64,
    pub payload_bytes: u64,
    pub keyframes: u64,
    pub live_frame_handles: i64,
    pub producer_finished: bool,
    /// Producer time spent creating + publishing frames (the reassembly copy + hand-off).
    pub producer_busy_ns: u64,
}

#[uniffi::export(with_foreign)]
pub trait FrameSink: Send + Sync {
    fn on_frame(&self, frame: VecFrame);
    fn on_end(&self);
}

#[uniffi::export(with_foreign)]
pub trait SlotSink: Send + Sync {
    /// Ring slots `[from_seq, to_seq)` are readable; Swift must call `ring_release` for each, in order.
    fn on_slots(&self, from_seq: u64, to_seq: u64);
    fn on_end(&self);
}

// ---------------------------------------------------------------------------------------------
// simulated receive buffer + frame generation

fn xorshift(mut x: u64) -> u64 {
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    x
}

fn net_buf() -> &'static [u8] {
    static NET: OnceLock<Box<[u8]>> = OnceLock::new();
    NET.get_or_init(|| {
        let mut v = vec![0u8; 4 << 20];
        let mut s = 0x9E37_79B9_7F4A_7C15u64;
        for chunk in v.chunks_mut(8) {
            s = xorshift(s);
            chunk.copy_from_slice(&s.to_le_bytes()[..chunk.len()]);
        }
        v.into_boxed_slice()
    })
}

fn frame_len(cfg: &StreamConfig, seq: u64) -> (usize, bool) {
    let key = cfg.keyframe_interval > 0 && seq % cfg.keyframe_interval as u64 == 0;
    let len = if key {
        cfg.keyframe_bytes as u64
    } else {
        let span = (cfg.p_frame_max.saturating_sub(cfg.p_frame_min) as u64) + 1;
        cfg.p_frame_min as u64 + xorshift(cfg.seed ^ (seq + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15)) % span
    };
    ((len.max(HEADER_LEN + 8)) as usize, key)
}

/// The bytes the "network" delivered for frame `seq`.
fn received(seq: u64, len: usize) -> &'static [u8] {
    let net = net_buf();
    let off = (seq.wrapping_mul(4099) as usize) % (net.len() - len);
    &net[off..off + len]
}

fn stamp(dst: &mut [u8], seq: u64) {
    let addr = dst.as_ptr() as u64;
    let len = dst.len() as u64;
    dst[0..8].copy_from_slice(&seq.to_le_bytes());
    dst[8..16].copy_from_slice(&addr.to_le_bytes());
    dst[16..24].copy_from_slice(&len.to_le_bytes());
    dst[24..32].copy_from_slice(&MAGIC.to_le_bytes());
    let n = dst.len();
    dst[n - 8..].copy_from_slice(&seq.to_le_bytes());
}

// ---------------------------------------------------------------------------------------------
// shared-memory ring (single producer, single consumer)

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
struct SlotDesc {
    seq: u64,
    frame_seq: u64,
    produced_ns: u64,
    offset: u64,
    len: u64,
    flags: u64,
    end_pos: u64,
    seq_check: u64,
    /// Offset 64: stamped by the consumer side of Rust when the slot is handed to Swift.
    delivered_ns: u64,
    _pad: [u64; 7],
}
const _: () = assert!(std::mem::size_of::<SlotDesc>() == DESC_STRIDE as usize);

struct Ring {
    data: NonNull<u8>,
    data_layout: Layout,
    descs: NonNull<SlotDesc>,
    desc_layout: Layout,
    desc_count: u64,
    /// Next ring sequence to publish (slots < head are readable).
    head: AtomicU64,
    /// Next ring sequence to release (slots < tail are free).
    tail: AtomicU64,
    released_pos: AtomicU64,
    write_pos: AtomicU64,
}

unsafe impl Send for Ring {}
unsafe impl Sync for Ring {}

impl Ring {
    fn new(bytes: u64, slots: u32) -> Result<Ring, CoreError> {
        const PAGE: usize = 16 * 1024;
        let data_len = (bytes as usize).div_ceil(PAGE).max(1) * PAGE;
        let data_layout = Layout::from_size_align(data_len, PAGE).map_err(CoreError::internal)?;
        let desc_layout = Layout::from_size_align(slots.max(1) as usize * DESC_STRIDE as usize, PAGE)
            .map_err(CoreError::internal)?;
        let data = NonNull::new(unsafe { alloc_zeroed(data_layout) })
            .ok_or_else(|| CoreError::internal("ring alloc"))?;
        let descs = NonNull::new(unsafe { alloc_zeroed(desc_layout) } as *mut SlotDesc)
            .ok_or_else(|| CoreError::internal("desc alloc"))?;
        Ok(Ring {
            data,
            data_layout,
            descs,
            desc_layout,
            desc_count: slots.max(1) as u64,
            head: AtomicU64::new(0),
            tail: AtomicU64::new(0),
            released_pos: AtomicU64::new(0),
            write_pos: AtomicU64::new(0),
        })
    }

    fn cap(&self) -> u64 {
        self.data_layout.size() as u64
    }

    fn try_publish(&self, frame_seq: u64, src: &[u8], key: bool) -> bool {
        let seq = self.head.load(Ordering::Relaxed);
        if seq - self.tail.load(Ordering::Acquire) >= self.desc_count {
            return false;
        }
        let (len, cap) = (src.len() as u64, self.cap());
        if len > cap {
            return false;
        }
        let mut start = self.write_pos.load(Ordering::Relaxed);
        let off = start % cap;
        if off + len > cap {
            start += cap - off; // don't split a frame across the wrap: skip to the next lap
        }
        let end = start + len;
        if end - self.released_pos.load(Ordering::Acquire) > cap {
            return false;
        }
        let off = start % cap;
        unsafe {
            let dst = self.data.as_ptr().add(off as usize);
            std::ptr::copy_nonoverlapping(src.as_ptr(), dst, src.len()); // the reassembly copy
            stamp(std::slice::from_raw_parts_mut(dst, src.len()), frame_seq);
            let d = SlotDesc {
                seq,
                frame_seq,
                produced_ns: now_ns(),
                offset: off,
                len,
                flags: key as u64,
                end_pos: end,
                seq_check: seq,
                delivered_ns: 0,
                _pad: [0; 7],
            };
            self.descs.as_ptr().add((seq % self.desc_count) as usize).write(d);
        }
        self.write_pos.store(end, Ordering::Relaxed);
        self.head.store(seq + 1, Ordering::Release);
        true
    }

    /// Marks slots `[from, to)` as handed to the consumer now (latency split: wake vs crossing).
    fn stamp_delivered(&self, from: u64, to: u64) {
        let t = now_ns();
        for s in from..to {
            unsafe {
                let d = self.descs.as_ptr().add((s % self.desc_count) as usize);
                std::ptr::addr_of_mut!((*d).delivered_ns).write(t);
            }
        }
    }

    fn release(&self, seq: u64) -> bool {
        if seq != self.tail.load(Ordering::Relaxed) || seq >= self.head.load(Ordering::Acquire) {
            return false; // spike: strictly in-order release by a single consumer
        }
        let d = unsafe { self.descs.as_ptr().add((seq % self.desc_count) as usize).read() };
        self.released_pos.store(d.end_pos, Ordering::Release);
        self.tail.store(seq + 1, Ordering::Release);
        true
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        unsafe {
            dealloc(self.data.as_ptr(), self.data_layout);
            dealloc(self.descs.as_ptr() as *mut u8, self.desc_layout);
        }
    }
}

// ---------------------------------------------------------------------------------------------

enum Item {
    Vec(VecFrame),
    Handle(FrameRef),
}

struct Inner {
    delivery: Delivery,
    cfg: StreamConfig,
    started: Mutex<bool>,
    started_cv: Condvar,
    prefilled: Mutex<bool>,
    prefilled_cv: Condvar,
    stop: AtomicBool,
    finished: AtomicBool,
    queue: Mutex<VecDeque<Item>>,
    queue_cv: Condvar,
    async_tx: Mutex<Option<tokio::sync::mpsc::Sender<VecFrame>>>,
    async_rx: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<VecFrame>>,
    ring: Option<Ring>,
    sig: Mutex<()>,
    sig_cv: Condvar,
    notify: tokio::sync::Notify,
    produced: AtomicU64,
    dropped: AtomicU64,
    bytes: AtomicU64,
    keyframes: AtomicU64,
    busy_ns: AtomicU64,
}

impl Inner {
    fn done(&self) -> bool {
        self.finished.load(Ordering::Acquire) || self.stop.load(Ordering::Acquire)
    }

    fn signal_ring(&self) {
        drop(self.sig.lock());
        self.sig_cv.notify_all();
        self.notify.notify_waiters();
    }

    fn signal_all(&self) {
        drop(self.queue.lock());
        self.queue_cv.notify_all();
        self.signal_ring();
    }

    fn push(&self, item: Item, backpressure: bool) -> bool {
        let cap = if self.cfg.prefill { usize::MAX } else { self.cfg.queue_depth.max(1) as usize };
        loop {
            let mut q = self.queue.lock();
            if q.len() < cap {
                q.push_back(item);
                drop(q);
                self.queue_cv.notify_one();
                return true;
            }
            drop(q);
            if !backpressure || self.stop.load(Ordering::Relaxed) {
                return false;
            }
            std::thread::sleep(Duration::from_micros(20));
        }
    }

    fn pop(&self) -> Option<Item> {
        let mut q = self.queue.lock();
        loop {
            if let Some(i) = q.pop_front() {
                return Some(i);
            }
            if self.done() {
                return None;
            }
            self.queue_cv.wait_for(&mut q, Duration::from_millis(500));
        }
    }

    fn wait_started(&self) {
        let mut s = self.started.lock();
        while !*s && !self.stop.load(Ordering::Relaxed) {
            self.started_cv.wait_for(&mut s, Duration::from_millis(100));
        }
    }

    /// Returns the ring head once it is > `next`; `u64::MAX` when the stream ended; `next` on timeout.
    fn ring_wait(&self, next: u64, timeout: Duration) -> u64 {
        let ring = self.ring.as_ref().expect("ring");
        let h = ring.head.load(Ordering::Acquire);
        if h > next {
            ring.stamp_delivered(next, h);
            return h;
        }
        let deadline = Instant::now() + timeout;
        let mut g = self.sig.lock();
        loop {
            let h = ring.head.load(Ordering::Acquire);
            if h > next {
                drop(g);
                ring.stamp_delivered(next, h);
                return h;
            }
            if self.done() {
                return u64::MAX;
            }
            if self.sig_cv.wait_until(&mut g, deadline).timed_out() {
                return next;
            }
        }
    }

    fn run_producer(self: Arc<Self>) {
        let cfg = self.cfg.clone();
        if !cfg.prefill {
            self.wait_started();
        }
        let period_ns = if cfg.fps > 0 && !cfg.prefill { 1_000_000_000 / cfg.fps as u64 } else { 0 };
        let backpressure = period_ns == 0;
        let tx = self.async_tx.lock().take();
        let t_start = now_ns();
        for seq in 0..cfg.frame_count {
            if self.stop.load(Ordering::Relaxed) {
                break;
            }
            if period_ns > 0 {
                let deadline = t_start + seq * period_ns;
                let now = now_ns();
                if deadline > now {
                    std::thread::sleep(Duration::from_nanos(deadline - now));
                }
            }
            let (len, key) = frame_len(&cfg, seq);
            let src = received(seq, len);
            let b0 = now_ns();
            let ok = match self.delivery {
                Delivery::VecPull | Delivery::VecCallback | Delivery::VecAsync => {
                    let mut v = src.to_vec(); // the reassembly copy
                    stamp(&mut v, seq);
                    let f = VecFrame { seq, produced_ns: now_ns(), delivered_ns: 0, is_key: key, data: v };
                    if self.delivery == Delivery::VecAsync {
                        let tx = tx.as_ref().expect("tx");
                        if backpressure { tx.blocking_send(f).is_ok() } else { tx.try_send(f).is_ok() }
                    } else {
                        self.push(Item::Vec(f), backpressure)
                    }
                }
                Delivery::HandlePull => {
                    let mut b: Box<[u8]> = src.into(); // the reassembly copy
                    stamp(&mut b, seq);
                    let ptr = b.as_ptr() as u64;
                    LIVE_HANDLES.fetch_add(1, Ordering::Relaxed);
                    let handle = Arc::new(FrameHandle { buf: b });
                    let r = FrameRef { handle, seq, produced_ns: now_ns(), delivered_ns: 0, is_key: key, ptr, len: len as u64 };
                    self.push(Item::Handle(r), backpressure)
                }
                Delivery::RingPull | Delivery::RingAsync | Delivery::RingCallback => {
                    let ring = self.ring.as_ref().expect("ring");
                    let ok = loop {
                        if ring.try_publish(seq, src, key) {
                            break true;
                        }
                        if !backpressure || self.stop.load(Ordering::Relaxed) {
                            break false;
                        }
                        std::thread::sleep(Duration::from_micros(20));
                    };
                    if ok && !cfg.prefill {
                        self.signal_ring();
                    }
                    ok
                }
            };
            self.busy_ns.fetch_add(now_ns() - b0, Ordering::Relaxed);
            if ok {
                self.produced.fetch_add(1, Ordering::Relaxed);
                self.bytes.fetch_add(len as u64, Ordering::Relaxed);
                if key {
                    self.keyframes.fetch_add(1, Ordering::Relaxed);
                }
            } else {
                self.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
        drop(tx); // closes the async channel -> next_vec_async() returns None after draining
        self.finished.store(true, Ordering::Release);
        self.signal_all();
        *self.prefilled.lock() = true;
        self.prefilled_cv.notify_all();
    }
}

#[derive(uniffi::Object)]
pub struct MediaStream {
    inner: Arc<Inner>,
    threads: Mutex<Vec<JoinHandle<()>>>,
}

#[uniffi::export]
impl MediaStream {
    #[uniffi::constructor]
    pub fn new(
        delivery: Delivery,
        config: StreamConfig,
        frame_sink: Option<Arc<dyn FrameSink>>,
        slot_sink: Option<Arc<dyn SlotSink>>,
    ) -> Result<Arc<Self>, CoreError> {
        let ring = match delivery {
            Delivery::RingPull | Delivery::RingAsync | Delivery::RingCallback => {
                Some(Ring::new(config.ring_bytes, config.ring_slots)?)
            }
            _ => None,
        };
        let chan_cap = if config.prefill { config.frame_count.max(1) as usize } else { config.queue_depth.max(1) as usize };
        let (tx, rx) = tokio::sync::mpsc::channel(chan_cap);
        let inner = Arc::new(Inner {
            delivery,
            cfg: config,
            started: Mutex::new(false),
            started_cv: Condvar::new(),
            prefilled: Mutex::new(false),
            prefilled_cv: Condvar::new(),
            stop: AtomicBool::new(false),
            finished: AtomicBool::new(false),
            queue: Mutex::new(VecDeque::new()),
            queue_cv: Condvar::new(),
            async_tx: Mutex::new(Some(tx)),
            async_rx: tokio::sync::Mutex::new(rx),
            ring,
            sig: Mutex::new(()),
            sig_cv: Condvar::new(),
            notify: tokio::sync::Notify::new(),
            produced: AtomicU64::new(0),
            dropped: AtomicU64::new(0),
            bytes: AtomicU64::new(0),
            keyframes: AtomicU64::new(0),
            busy_ns: AtomicU64::new(0),
        });

        let mut threads = Vec::new();
        let p = inner.clone();
        threads.push(
            std::thread::Builder::new()
                .name("s10-producer".into())
                .spawn(move || p.run_producer())
                .map_err(CoreError::internal)?,
        );
        match delivery {
            Delivery::VecCallback => {
                let sink = frame_sink.ok_or_else(|| CoreError::internal("VecCallback needs frame_sink"))?;
                let i = inner.clone();
                threads.push(
                    std::thread::Builder::new()
                        .name("s10-deliver".into())
                        .spawn(move || {
                            i.wait_started();
                            while let Some(item) = i.pop() {
                                if let Item::Vec(mut f) = item {
                                    f.delivered_ns = now_ns();
                                    sink.on_frame(f);
                                }
                            }
                            sink.on_end();
                        })
                        .map_err(CoreError::internal)?,
                );
            }
            Delivery::RingCallback => {
                let sink = slot_sink.ok_or_else(|| CoreError::internal("RingCallback needs slot_sink"))?;
                let i = inner.clone();
                threads.push(
                    std::thread::Builder::new()
                        .name("s10-deliver".into())
                        .spawn(move || {
                            i.wait_started();
                            let mut next = 0u64;
                            loop {
                                let h = i.ring_wait(next, Duration::from_millis(500));
                                if h == u64::MAX {
                                    break;
                                }
                                if h > next {
                                    sink.on_slots(next, h);
                                    next = h;
                                }
                            }
                            sink.on_end();
                        })
                        .map_err(CoreError::internal)?,
                );
            }
            _ => {}
        }
        Ok(Arc::new(MediaStream { inner, threads: Mutex::new(threads) }))
    }

    /// Blocks until the producer has generated every frame (prefill mode).
    pub fn wait_prefilled(&self) {
        let mut p = self.inner.prefilled.lock();
        while !*p {
            self.inner.prefilled_cv.wait_for(&mut p, Duration::from_millis(100));
        }
    }

    pub fn start(&self) {
        *self.inner.started.lock() = true;
        self.inner.started_cv.notify_all();
    }

    pub fn stop(&self) {
        self.inner.stop.store(true, Ordering::Release);
        self.inner.started_cv.notify_all();
        self.inner.signal_all();
    }

    /// Joins the producer/delivery threads (call after the stream ended).
    pub fn join(&self) {
        let ts: Vec<_> = self.threads.lock().drain(..).collect();
        for t in ts {
            let _ = t.join();
        }
    }

    /// Design VecPull: blocks the calling thread; None = end of stream.
    pub fn next_vec(&self) -> Option<VecFrame> {
        match self.inner.pop()? {
            Item::Vec(mut f) => {
                f.delivered_ns = now_ns();
                Some(f)
            }
            Item::Handle(_) => None,
        }
    }

    /// Design VecAsync.
    pub async fn next_vec_async(&self) -> Option<VecFrame> {
        let mut rx = self.inner.async_rx.lock().await;
        let mut f = rx.recv().await?;
        f.delivered_ns = now_ns(); // stamped in the poll that runs on Swift's executor after the wake
        Some(f)
    }

    /// Design HandlePull: blocks; None = end of stream.
    pub fn next_handle(&self) -> Option<FrameRef> {
        match self.inner.pop()? {
            Item::Handle(mut r) => {
                r.delivered_ns = now_ns();
                Some(r)
            }
            Item::Vec(_) => None,
        }
    }

    pub fn ring_layout(&self) -> Option<RingLayout> {
        self.inner.ring.as_ref().map(|r| RingLayout {
            data_base: r.data.as_ptr() as u64,
            data_len: r.cap(),
            desc_base: r.descs.as_ptr() as u64,
            desc_count: r.desc_count as u32,
            desc_stride: DESC_STRIDE,
        })
    }

    /// Design RingPull: blocks until slots `>= next` exist; returns the head, `u64::MAX` at end,
    /// or `next` on timeout.
    pub fn ring_wait(&self, next: u64, timeout_ms: u64) -> u64 {
        self.inner.ring_wait(next, Duration::from_millis(timeout_ms))
    }

    /// Design RingAsync.
    pub async fn ring_wait_async(&self, next: u64) -> u64 {
        let ring = self.inner.ring.as_ref().expect("ring");
        loop {
            let notified = self.inner.notify.notified();
            let mut notified = std::pin::pin!(notified);
            notified.as_mut().enable();
            let h = ring.head.load(Ordering::Acquire);
            if h > next {
                ring.stamp_delivered(next, h);
                return h;
            }
            if self.inner.done() {
                return u64::MAX;
            }
            notified.await;
        }
    }

    /// Returns ring slot `seq` to the producer. Must be called in order.
    pub fn ring_release(&self, seq: u64) -> bool {
        self.inner.ring.as_ref().map(|r| r.release(seq)).unwrap_or(false)
    }

    pub fn stats(&self) -> StreamStats {
        let i = &self.inner;
        StreamStats {
            produced: i.produced.load(Ordering::Relaxed),
            dropped_full: i.dropped.load(Ordering::Relaxed),
            payload_bytes: i.bytes.load(Ordering::Relaxed),
            keyframes: i.keyframes.load(Ordering::Relaxed),
            live_frame_handles: LIVE_HANDLES.load(Ordering::Relaxed),
            producer_finished: i.finished.load(Ordering::Acquire),
            producer_busy_ns: i.busy_ns.load(Ordering::Relaxed),
        }
    }
}

impl Drop for MediaStream {
    fn drop(&mut self) {
        self.stop();
    }
}
