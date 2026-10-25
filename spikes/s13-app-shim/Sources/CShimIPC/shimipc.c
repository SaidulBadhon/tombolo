// SPDX-License-Identifier: GPL-3.0-or-later
// Spike S13: raw Mach messaging helpers. See include/CShimIPC.h.
#include "CShimIPC.h"

#include <bsm/libbsm.h>
#include <mach/notify.h>
#include <notify.h>
#include <servers/bootstrap.h>
#include <string.h>
#include <time.h>

// Wire layout (always a "complex" message so parsing is uniform):
//   header | body(descriptor count) | N port descriptors | uint32 payload_len | payload bytes (padded to 4)
#define SIPC_SEND_CAP (sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + \
                       SIPC_MAX_PORTS * sizeof(mach_msg_port_descriptor_t) + 4 + SIPC_MAX_PAYLOAD)
#define SIPC_RECV_CAP (SIPC_SEND_CAP + sizeof(mach_msg_max_trailer_t) + 64)

kern_return_t sipc_checkin(const char *name, mach_port_t *out_receive) {
    return bootstrap_check_in(bootstrap_port, name, out_receive);
}

kern_return_t sipc_lookup(const char *name, mach_port_t *out_send) {
    return bootstrap_look_up(bootstrap_port, name, out_send);
}

kern_return_t sipc_set_qlimit(mach_port_t port, uint32_t qlimit) {
    mach_port_limits_t limits = {.mpl_qlimit = qlimit};
    return mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO,
                                    (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
}

kern_return_t sipc_make_port(mach_port_t *out, uint32_t qlimit) {
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &p);
    if (kr != KERN_SUCCESS) return kr;
    kr = mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) return kr;
    if (qlimit) sipc_set_qlimit(p, qlimit);
    *out = p;
    return KERN_SUCCESS;
}

kern_return_t sipc_send(mach_port_t dest, mach_port_t reply, int32_t msgid,
                        const mach_port_t *ports, uint32_t nports,
                        const void *payload, uint32_t len, uint32_t timeout_ms) {
    if (nports > SIPC_MAX_PORTS || len > SIPC_MAX_PAYLOAD) return KERN_INVALID_ARGUMENT;
    union { mach_msg_header_t h; uint8_t bytes[SIPC_SEND_CAP]; } buf;
    memset(&buf, 0, sizeof buf);
    mach_msg_header_t *h = &buf.h;
    mach_msg_body_t *body = (mach_msg_body_t *)(h + 1);
    mach_msg_port_descriptor_t *d = (mach_msg_port_descriptor_t *)(body + 1);
    body->msgh_descriptor_count = nports;
    for (uint32_t i = 0; i < nports; i++) {
        d[i].name = ports[i];
        d[i].disposition = MACH_MSG_TYPE_MOVE_SEND;
        d[i].type = MACH_MSG_PORT_DESCRIPTOR;
    }
    uint8_t *p = (uint8_t *)(d + nports);
    memcpy(p, &len, 4);
    if (len) memcpy(p + 4, payload, len);
    size_t size = (size_t)(p + 4 + len - buf.bytes);
    size = (size + 3) & ~(size_t)3;

    h->msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                      reply != MACH_PORT_NULL ? MACH_MSG_TYPE_MAKE_SEND : 0, 0,
                                      MACH_MSGH_BITS_COMPLEX);
    h->msgh_size = (mach_msg_size_t)size;
    h->msgh_remote_port = dest;
    h->msgh_local_port = reply;
    h->msgh_id = msgid;
    mach_msg_option_t opts = MACH_SEND_MSG | (timeout_ms != UINT32_MAX ? MACH_SEND_TIMEOUT : 0);
    kern_return_t kr = mach_msg(h, opts, (mach_msg_size_t)size, 0, MACH_PORT_NULL,
                                timeout_ms == UINT32_MAX ? MACH_MSG_TIMEOUT_NONE : timeout_ms,
                                MACH_PORT_NULL);
    if (kr == MACH_SEND_TIMED_OUT || kr == MACH_SEND_INTERRUPTED) {
        // The kernel pseudo-received the message back into our space; destroy the carried rights.
        mach_msg_destroy(h);
    }
    return kr;
}

kern_return_t sipc_receive(mach_port_t port, sipc_message_t *out, uint32_t timeout_ms) {
    union { mach_msg_header_t h; uint8_t bytes[SIPC_RECV_CAP]; } buf;
    mach_msg_header_t *h = &buf.h;
    memset(out, 0, sizeof *out);
    mach_msg_option_t opts = MACH_RCV_MSG | MACH_RCV_TIMEOUT |
                             MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
                             MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT);
    kern_return_t kr = mach_msg(h, opts, 0, sizeof buf, port, timeout_ms, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return kr;

    out->msgid = h->msgh_id;
    out->reply_port = h->msgh_remote_port;
    mach_msg_audit_trailer_t *tr = (mach_msg_audit_trailer_t *)((uint8_t *)h + round_msg(h->msgh_size));
    if (tr->msgh_trailer_size >= sizeof(mach_msg_audit_trailer_t)) {
        memcpy(out->audit, &tr->msgh_audit, sizeof out->audit);
        out->sender_pid = audit_token_to_pid(tr->msgh_audit);
    } else {
        out->sender_pid = -1;
    }

    if (h->msgh_id == MACH_NOTIFY_DEAD_NAME || h->msgh_id == MACH_NOTIFY_PORT_DELETED) {
        // Same layout for both: header, NDR, mach_port_name_t.
        mach_dead_name_notification_t *n = (mach_dead_name_notification_t *)h;
        out->notify_name = n->not_port;
        return KERN_SUCCESS;
    }
    if (!(h->msgh_bits & MACH_MSGH_BITS_COMPLEX)) return KERN_SUCCESS;

    uint8_t *end = (uint8_t *)h + h->msgh_size;
    mach_msg_body_t *body = (mach_msg_body_t *)(h + 1);
    uint8_t *p = (uint8_t *)(body + 1);
    for (uint32_t i = 0; i < body->msgh_descriptor_count; i++) {
        mach_msg_type_descriptor_t *td = (mach_msg_type_descriptor_t *)p;
        if (td->type == MACH_MSG_PORT_DESCRIPTOR) {
            mach_msg_port_descriptor_t *pd = (mach_msg_port_descriptor_t *)p;
            if (out->nports < SIPC_MAX_PORTS) out->ports[out->nports++] = pd->name;
            else mach_port_deallocate(mach_task_self(), pd->name);
            p += sizeof(mach_msg_port_descriptor_t);
        } else {
            // We never send OOL memory; refuse anything else.
            mach_msg_destroy(h);
            memset(out, 0, sizeof *out);
            return KERN_INVALID_ARGUMENT;
        }
    }
    if (p + 4 <= end) {
        uint32_t len;
        memcpy(&len, p, 4);
        if (len > SIPC_MAX_PAYLOAD || p + 4 + len > end) len = 0;
        out->payload_len = len;
        memcpy(out->payload, p + 4, len);
    }
    return KERN_SUCCESS;
}

kern_return_t sipc_request_dead_name(mach_port_t name, mach_port_t notify_port) {
    mach_port_t previous = MACH_PORT_NULL;
    kern_return_t kr = mach_port_request_notification(mach_task_self(), name, MACH_NOTIFY_DEAD_NAME,
                                                      1 /* fire now if already dead */, notify_port,
                                                      MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
    if (previous != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), previous);
    return kr;
}

void sipc_release(mach_port_t name) {
    if (name == MACH_PORT_NULL) return;
    mach_port_type_t type = 0;
    if (mach_port_type(mach_task_self(), name, &type) != KERN_SUCCESS) return;
    mach_port_urefs_t refs = 0;
    if (type & MACH_PORT_TYPE_DEAD_NAME &&
        mach_port_get_refs(mach_task_self(), name, MACH_PORT_RIGHT_DEAD_NAME, &refs) == KERN_SUCCESS && refs)
        mach_port_mod_refs(mach_task_self(), name, MACH_PORT_RIGHT_DEAD_NAME, -(mach_port_delta_t)refs);
    if (type & MACH_PORT_TYPE_SEND &&
        mach_port_get_refs(mach_task_self(), name, MACH_PORT_RIGHT_SEND, &refs) == KERN_SUCCESS && refs)
        mach_port_mod_refs(mach_task_self(), name, MACH_PORT_RIGHT_SEND, -(mach_port_delta_t)refs);
}

const char *sipc_strerror(kern_return_t kr) { return mach_error_string(kr); }
const char *sipc_bootstrap_strerror(kern_return_t kr) { return bootstrap_strerror(kr); }

uint32_t sipc_notify_post(const char *name) { return notify_post(name); }

int sipc_notify_register(const char *name, dispatch_queue_t queue, void (^handler)(void)) {
    int token = 0;
    uint32_t st = notify_register_dispatch(name, &token, queue, ^(int t) { (void)t; handler(); });
    return st == NOTIFY_STATUS_OK ? token : -1;
}

uint64_t sipc_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
