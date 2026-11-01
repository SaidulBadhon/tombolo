// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: minimal Mach IPC used between the Tombolo host and its app shims.
//
// Rendezvous: the host claims a *dynamic* bootstrap name with bootstrap_check_in() (no launchd plist);
// shims find it with bootstrap_look_up(). This is the mechanism Chromium uses for its PWA app shims.
// Messages carry an optional set of port rights (IOSurface Mach ports) plus a small inline payload.
#pragma once
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <stdint.h>

#define SIPC_MAX_PORTS 4
#define SIPC_MAX_PAYLOAD 512

typedef struct {
    int32_t msgid;
    mach_port_t reply_port;   // right received in msgh_remote_port (MACH_PORT_NULL if none)
    uint32_t nports;
    mach_port_t ports[SIPC_MAX_PORTS];  // received send rights (caller owns them)
    uint32_t payload_len;
    uint8_t payload[SIPC_MAX_PAYLOAD];
    uint32_t audit[8];        // sender's audit token (kernel = all zero pid)
    int32_t sender_pid;
    mach_port_name_t notify_name;  // for MACH_NOTIFY_DEAD_NAME / PORT_DELETED
} sipc_message_t;

enum {
    SIPC_NOTIFY_DEAD_NAME = MACH_NOTIFY_DEAD_NAME,
    SIPC_NOTIFY_PORT_DELETED = MACH_NOTIFY_PORT_DELETED,
};

/// Claim a dynamic bootstrap name in the caller's (gui/$UID) domain. Returns the receive right.
kern_return_t sipc_checkin(const char *name, mach_port_t *out_receive);
/// Look up a bootstrap name. Returns a send right.
kern_return_t sipc_lookup(const char *name, mach_port_t *out_send);
/// New receive right with one send right inserted under the same name; queue limit raised.
kern_return_t sipc_make_port(mach_port_t *out, uint32_t qlimit);
kern_return_t sipc_set_qlimit(mach_port_t port, uint32_t qlimit);
/// Send. `ports` are moved (MACH_MSG_TYPE_MOVE_SEND). If `reply` is not null a send right to it is made.
kern_return_t sipc_send(mach_port_t dest, mach_port_t reply, int32_t msgid,
                        const mach_port_t *ports, uint32_t nports,
                        const void *payload, uint32_t len, uint32_t timeout_ms);
/// Receive one message (timeout 0 = poll). Returns MACH_RCV_TIMED_OUT when the queue is empty.
kern_return_t sipc_receive(mach_port_t port, sipc_message_t *out, uint32_t timeout_ms);
/// Ask the kernel to send MACH_NOTIFY_DEAD_NAME to `notify_port` when `name` (a send right) dies.
kern_return_t sipc_request_dead_name(mach_port_t name, mach_port_t notify_port);
/// Drop every send / dead-name reference held under `name`.
void sipc_release(mach_port_t name);
const char *sipc_strerror(kern_return_t kr);
const char *sipc_bootstrap_strerror(kern_return_t kr);

/// notify(3) helpers: wake waiting shims as soon as the host is ready.
uint32_t sipc_notify_post(const char *name);
int sipc_notify_register(const char *name, dispatch_queue_t queue, void (^handler)(void));

/// CLOCK_UPTIME_RAW in nanoseconds: one monotonic clock shared by all processes.
uint64_t sipc_now_ns(void);
