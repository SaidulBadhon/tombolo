// SPDX-License-Identifier: GPL-3.0-or-later
//! Network conditions and the shared per-direction link model used by both proxies.

use crate::clock::Rng;

#[derive(Clone, Copy, Debug)]
pub enum Loss {
    None,
    /// Independent loss with this probability.
    Random(f64),
    /// Two-state (Gilbert–Elliott) loss in *time*: bad periods with mean `bad_ms`, good
    /// periods with mean `good_ms` (exponential); every packet sent in a bad period is lost.
    /// Loss fraction for dense traffic = bad / (bad + good). Time-based on purpose: a
    /// per-packet chain keeps a quiet sender "in the burst" indefinitely, which turned
    /// QUIC's probe-timeout back-off into multi-second stalls (see results/s4/trial/).
    Burst { bad_ms: f64, good_ms: f64 },
}

#[derive(Clone, Debug)]
pub enum BulkPlan {
    /// Send continuously in [start, end) seconds after t0.
    Window { start: f64, end: f64 },
    /// 1-second-style bursts starting at these offsets.
    Bursts { starts: Vec<f64>, len: f64 },
}

impl BulkPlan {
    pub fn windows(&self) -> Vec<(f64, f64)> {
        match self {
            BulkPlan::Window { start, end } => vec![(*start, *end)],
            BulkPlan::Bursts { starts, len } => starts.iter().map(|s| (*s, s + len)).collect(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct Cond {
    pub name: &'static str,
    /// One-way base delay per direction (ms) and ± uniform jitter (ms).
    pub delay_ms: f64,
    pub jitter_ms: f64,
    pub loss: Loss,
    /// Bottleneck rate per direction (Mbit/s); `None` = no cap.
    pub rate_mbps: Option<f64>,
    /// Bottleneck buffer (bytes): drop-tail for UDP, back-pressure limit for the TCP relay.
    pub queue_bytes: usize,
    pub bulk: BulkPlan,
    /// Stop the bulk transfer after this many bytes (None = run for the whole window).
    pub bulk_max_bytes: Option<u64>,
    pub secs: f64,
}

impl Cond {
    pub fn by_name(name: &str) -> Option<Cond> {
        let window = BulkPlan::Window {
            start: 6.0,
            end: 14.0,
        };
        let base = Cond {
            name: "clean",
            delay_ms: 0.0,
            jitter_ms: 0.0,
            loss: Loss::None,
            rate_mbps: None,
            queue_bytes: 0,
            bulk: window.clone(),
            bulk_max_bytes: None,
            secs: 20.0,
        };
        // Lossless Wi-Fi-like conditions get an explicit bottleneck (300 Mbit/s, 10 ms
        // drop-tail buffer). Without one, the userland proxy's own CPU limit becomes an
        // unmodelled bottleneck with a multi-MB socket-buffer queue (see the trial run in
        // results/s4/trial/). Loss conditions stay uncapped: loss already limits QUIC's
        // congestion window, and the TCP model has no congestion window to limit.
        let wifi_cap = Cond {
            rate_mbps: Some(300.0),
            queue_bytes: 375_000,
            ..base.clone()
        };
        let wifi = Cond {
            delay_ms: 5.0,
            jitter_ms: 3.0,
            ..base.clone()
        };
        Some(match name {
            "clean" => wifi_cap,
            "clean-uncapped" => Cond {
                name: "clean-uncapped",
                ..base
            },
            "jitter" => Cond {
                name: "jitter",
                delay_ms: 5.0,
                jitter_ms: 3.0,
                ..wifi_cap
            },
            "loss1" => Cond {
                name: "loss1",
                loss: Loss::Random(0.01),
                ..wifi
            },
            // 3 % of time in loss bursts averaging 3 ms (≈ 4 packets of a 16 Mbit/s stream)
            "burst3" => Cond {
                name: "burst3",
                loss: Loss::Burst {
                    bad_ms: 3.0,
                    good_ms: 97.0,
                },
                ..wifi
            },
            "cap100" => Cond {
                name: "cap100",
                rate_mbps: Some(100.0),
                queue_bytes: 250_000, // 20 ms at 100 Mbit/s
                bulk: BulkPlan::Bursts {
                    starts: vec![4.0, 8.0, 12.0, 16.0],
                    len: 1.0,
                },
                ..wifi
            },
            // adb-forward-over-USB model: lossless, ~0.5 ms RTT, USB 2-class adb throughput.
            "usb" => Cond {
                name: "usb",
                delay_ms: 0.25,
                jitter_ms: 0.0,
                rate_mbps: Some(320.0),
                queue_bytes: 256_000,
                ..base
            },
            // Phone runs (no proxy: the real Wi-Fi / USB link is the impairment). 45 s with a
            // concurrent 1 GiB transfer, as in the S4 acceptance criterion.
            "real" => Cond {
                name: "real",
                bulk: BulkPlan::Window {
                    start: 6.0,
                    end: 40.0,
                },
                bulk_max_bytes: Some(1 << 30),
                secs: 45.0,
                ..base
            },
            _ => return None,
        })
    }

    pub fn base_rtt_ms(&self) -> f64 {
        2.0 * self.delay_ms
    }

    /// TCP loss model: a lost segment stalls its connection for one fast-recovery round
    /// (RACK: ~1.25 RTT, plus 1 ms detection slack). Deliberately optimistic for TCP — no
    /// tail-loss probe or RTO, no cwnd reduction.
    pub fn tcp_loss_stall_ns(&self) -> u64 {
        ((1.25 * self.base_rtt_ms() + 1.0) * 1e6) as u64
    }

    /// Loss-limited TCP throughput per connection (Mathis et al.: rate = 1.22·MSS / (RTT·√p),
    /// window = 1.22/√p segments), with p = congestion events per packet (a burst of
    /// consecutive losses is one event with SACK). CUBIC runs in its Reno-friendly region at
    /// these small BDPs, so Reno's response function is the right first-order model.
    /// Returns (bits/s, window bytes), or None for lossless conditions.
    pub fn tcp_loss_limit(&self) -> Option<(f64, usize)> {
        let p = match self.loss {
            Loss::None => return None,
            Loss::Random(p) => p,
            // ~10 bursts/s; for a ~1450 packet/s flow that is ≈ 0.7 % congestion events per
            // packet (each burst is one event with SACK).
            Loss::Burst { bad_ms, good_ms } => (1000.0 / (bad_ms + good_ms)) / 1450.0,
        };
        let w_segs = 1.22 / p.sqrt();
        let rtt_s = self.base_rtt_ms().max(0.1) / 1e3;
        Some((w_segs * 1448.0 * 8.0 / rtt_s, (w_segs * 1448.0) as usize))
    }
}

/// Per-direction link: loss → bottleneck queue (rate) → delay/jitter, FIFO (no reordering).
pub struct Link {
    pub cond: Cond,
    rng: Rng,
    bad: bool,
    state_end_ns: u64,
    link_free_ns: u64,
    prev_deliver_ns: u64,
    slot: u64,
    slot_delay_ns: u64,
    // counters
    pub pkts_in: u64,
    pub bytes_in: u64,
    pub lost: u64,
    pub queue_dropped: u64,
}

pub enum Verdict {
    /// Deliver at this time.
    Deliver(u64),
    /// Lost on the link: UDP drops it; the TCP relay stalls its connection.
    Lost(u64),
    /// Bottleneck buffer full (UDP only).
    QueueDrop,
}

const JITTER_SLOT_NS: u64 = 5_000_000;

impl Link {
    pub fn new(cond: Cond, seed: u64) -> Self {
        Self {
            cond,
            rng: Rng::new(seed),
            bad: false,
            state_end_ns: 0,
            link_free_ns: 0,
            prev_deliver_ns: 0,
            slot: u64::MAX,
            slot_delay_ns: 0,
            pkts_in: 0,
            bytes_in: 0,
            lost: 0,
            queue_dropped: 0,
        }
    }

    fn exp_ns(&mut self, mean_ms: f64) -> u64 {
        let u = self.rng.f64().max(1e-12);
        (-u.ln() * mean_ms * 1e6) as u64
    }

    /// Bytes waiting in the bottleneck at time `now` (0 if uncapped).
    pub fn backlog_bytes(&self, now: u64) -> usize {
        match self.cond.rate_mbps {
            Some(r) if self.link_free_ns > now => {
                ((self.link_free_ns - now) as f64 * r * 1e6 / 8.0 / 1e9) as usize
            }
            _ => 0,
        }
    }

    /// Decide the fate of one packet/segment of `len` bytes arriving at `now`.
    /// `drop_tail`: true for UDP (drop when the buffer is full), false for the TCP relay
    /// (which applies back-pressure before reading instead).
    pub fn admit(&mut self, now: u64, len: usize, drop_tail: bool) -> Verdict {
        self.admit_ext(now, len, drop_tail, true)
    }

    /// `fifo = false`: don't serialise against other connections' delivery times (used when
    /// the TCP model paces each connection itself, so admissions are not in time order).
    pub fn admit_ext(&mut self, now: u64, len: usize, drop_tail: bool, fifo: bool) -> Verdict {
        self.pkts_in += 1;
        self.bytes_in += len as u64;
        let lost = match self.cond.loss {
            Loss::None => false,
            Loss::Random(p) => self.rng.f64() < p,
            Loss::Burst { bad_ms, good_ms } => {
                if self.state_end_ns == 0 {
                    self.state_end_ns = now + self.exp_ns(good_ms);
                }
                while now >= self.state_end_ns {
                    self.bad = !self.bad;
                    let mean = if self.bad { bad_ms } else { good_ms };
                    self.state_end_ns += self.exp_ns(mean);
                }
                self.bad
            }
        };
        if drop_tail
            && self.cond.rate_mbps.is_some()
            && self.backlog_bytes(now) + len > self.cond.queue_bytes
        {
            self.queue_dropped += 1;
            return Verdict::QueueDrop;
        }
        if lost && drop_tail {
            // UDP: lost on the air after it was queued — it still used link time.
            self.lost += 1;
        }
        let out = match self.cond.rate_mbps {
            Some(r) => {
                let start = self.link_free_ns.max(now);
                let ser = (len as f64 * 8.0 / (r * 1e6) * 1e9) as u64;
                self.link_free_ns = start + ser;
                self.link_free_ns
            }
            None => now,
        };
        // Piecewise-constant jitter (one draw per 5 ms slot) keeps the mean delay at
        // `delay_ms` even for dense packet trains, while never reordering.
        let slot = out / JITTER_SLOT_NS;
        if slot != self.slot {
            self.slot = slot;
            let j = (self.rng.f64() * 2.0 - 1.0) * self.cond.jitter_ms;
            self.slot_delay_ns = ((self.cond.delay_ms + j).max(0.0) * 1e6) as u64;
        }
        let deliver = if fifo {
            (out + self.slot_delay_ns).max(self.prev_deliver_ns)
        } else {
            out + self.slot_delay_ns
        };
        if fifo {
            self.prev_deliver_ns = deliver;
        }
        if lost {
            if !drop_tail {
                self.lost += 1;
            }
            Verdict::Lost(deliver)
        } else {
            Verdict::Deliver(deliver)
        }
    }
}
