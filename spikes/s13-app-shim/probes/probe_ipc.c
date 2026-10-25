// Probe: which Mach/XPC rendezvous mechanisms work between two processes
// that were NOT launched by launchd as a job (i.e. ordinary apps)?
//   probe_ipc xpc-listen  NAME   -> xpc_connection_create_mach_service(LISTENER) in an unmanaged process
//   probe_ipc xpc-connect NAME   -> client connect + send message, wait for reply
//   probe_ipc bs-checkin  NAME   -> bootstrap_check_in a dynamic name, receive one mach msg
//   probe_ipc bs-lookup   NAME   -> bootstrap_look_up + send one mach msg
#include <xpc/xpc.h>
#include <servers/bootstrap.h>
#include <mach/mach.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct { mach_msg_header_t h; int value; mach_msg_trailer_t t; } msg_t;

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage\n"); return 2; }
  const char *mode = argv[1], *name = argv[2];
  if (!strcmp(mode, "xpc-listen")) {
    xpc_connection_t l = xpc_connection_create_mach_service(name, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(l, ^(xpc_object_t peer) {
      if (xpc_get_type(peer) == XPC_TYPE_ERROR) { printf("listener error: %s\n", xpc_dictionary_get_string(peer, XPC_ERROR_KEY_DESCRIPTION)); fflush(stdout); return; }
      printf("listener: got peer pid=%d\n", xpc_connection_get_pid(peer)); fflush(stdout);
      xpc_connection_set_event_handler(peer, ^(xpc_object_t m) {
        if (xpc_get_type(m) == XPC_TYPE_DICTIONARY) {
          xpc_object_t r = xpc_dictionary_create_reply(m); xpc_dictionary_set_string(r, "pong", "ok");
          xpc_connection_send_message(peer, r); printf("listener: replied\n"); fflush(stdout);
        }
      });
      xpc_connection_resume(peer);
    });
    xpc_connection_resume(l);
    printf("xpc listener resumed on %s pid=%d\n", name, getpid()); fflush(stdout);
    sleep(8); return 0;
  }
  if (!strcmp(mode, "xpc-connect")) {
    xpc_connection_t c = xpc_connection_create_mach_service(name, NULL, 0);
    xpc_connection_set_event_handler(c, ^(xpc_object_t e) {
      if (xpc_get_type(e) == XPC_TYPE_ERROR) { printf("client error: %s\n", xpc_dictionary_get_string(e, XPC_ERROR_KEY_DESCRIPTION)); fflush(stdout); }
    });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0); xpc_dictionary_set_string(m, "ping", "hi");
    xpc_object_t r = xpc_connection_send_message_with_reply_sync(c, m);
    if (xpc_get_type(r) == XPC_TYPE_ERROR) printf("client: reply ERROR %s\n", xpc_dictionary_get_string(r, XPC_ERROR_KEY_DESCRIPTION));
    else printf("client: reply pong=%s\n", xpc_dictionary_get_string(r, "pong"));
    return 0;
  }
  if (!strcmp(mode, "bs-checkin")) {
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_check_in(bootstrap_port, name, &p);
    printf("bootstrap_check_in(%s) = %d (%s) port=%u pid=%d\n", name, kr, bootstrap_strerror(kr), p, getpid()); fflush(stdout);
    if (kr != KERN_SUCCESS) return 1;
    msg_t m; memset(&m, 0, sizeof m);
    kr = mach_msg(&m.h, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof m, p, 8000, MACH_PORT_NULL);
    printf("mach_msg receive = %d value=%d\n", kr, m.value); return 0;
  }
  if (!strcmp(mode, "bs-lookup")) {
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &p);
    printf("bootstrap_look_up(%s) = %d (%s) port=%u\n", name, kr, bootstrap_strerror(kr), p);
    if (kr != KERN_SUCCESS) return 1;
    msg_t m; memset(&m, 0, sizeof m);
    m.h.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0); m.h.msgh_size = sizeof m - sizeof(mach_msg_trailer_t);
    m.h.msgh_remote_port = p; m.h.msgh_id = 42; m.value = 1234;
    kr = mach_msg(&m.h, MACH_SEND_MSG, m.h.msgh_size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    printf("mach_msg send = %d\n", kr); return 0;
  }
  return 2;
}
