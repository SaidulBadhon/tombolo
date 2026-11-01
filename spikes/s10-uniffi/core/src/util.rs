// SPDX-License-Identifier: GPL-3.0-or-later
//! Clock, thread identification and the probe log used to prove what happened where.

use std::ffi::{CStr, c_char, c_void};
use std::sync::Mutex;

/// Monotonic clock shared with Swift (`clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` on both sides).
pub fn now_ns() -> u64 {
    unsafe { clock_gettime_nsec_np(libc::CLOCK_UPTIME_RAW) }
}

#[uniffi::export]
pub fn clock_now_ns() -> u64 {
    now_ns()
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ThreadInfo {
    /// pthread name (Rust-spawned threads and some system threads have one).
    pub os_name: String,
    /// libdispatch queue label of the current thread (Swift's executors run on dispatch queues).
    pub queue_label: String,
    pub tid: u64,
    pub is_main: bool,
}

unsafe extern "C" {
    // libSystem (not bound by the libc crate)
    fn clock_gettime_nsec_np(clock_id: libc::clockid_t) -> u64;
    fn dispatch_queue_get_label(queue: *const c_void) -> *const c_char;
}

pub fn thread_info() -> ThreadInfo {
    let mut buf = [0 as c_char; 128];
    unsafe { libc::pthread_getname_np(libc::pthread_self(), buf.as_mut_ptr(), buf.len()) };
    let os_name = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned();
    let queue_label = unsafe {
        // DISPATCH_CURRENT_QUEUE_LABEL == NULL
        let p = dispatch_queue_get_label(std::ptr::null());
        if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
    };
    let mut tid = 0u64;
    unsafe { libc::pthread_threadid_np(0 as libc::pthread_t, &mut tid) };
    let is_main = unsafe { libc::pthread_main_np() } != 0;
    ThreadInfo { os_name, queue_label, tid, is_main }
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct ProbeEvent {
    pub probe: u64,
    pub event: String,
    pub t_ns: u64,
    pub thread: ThreadInfo,
}

static PROBES: Mutex<Vec<ProbeEvent>> = Mutex::new(Vec::new());

pub fn record(probe: u64, event: impl Into<String>) {
    let ev = ProbeEvent { probe, event: event.into(), t_ns: now_ns(), thread: thread_info() };
    PROBES.lock().unwrap().push(ev);
}

/// Returns (and removes) all events recorded for `probe`, in order.
#[uniffi::export]
pub fn take_probe_events(probe: u64) -> Vec<ProbeEvent> {
    let mut all = PROBES.lock().unwrap();
    let (mine, rest): (Vec<_>, Vec<_>) = all.drain(..).partition(|e| e.probe == probe);
    *all = rest;
    mine
}

/// Records creation, completion and drop of a future/task so we can prove *when* it was dropped.
pub struct Guard {
    probe: u64,
    label: &'static str,
    done: bool,
}

impl Guard {
    pub fn new(probe: u64, label: &'static str) -> Self {
        record(probe, format!("{label}:started"));
        Guard { probe, label, done: false }
    }
    pub fn done(&mut self) {
        self.done = true;
        record(self.probe, format!("{}:completed", self.label));
    }
}

impl Drop for Guard {
    fn drop(&mut self) {
        let what = if self.done { "dropped_after_completion" } else { "dropped_before_completion" };
        record(self.probe, format!("{}:{what}", self.label));
    }
}
