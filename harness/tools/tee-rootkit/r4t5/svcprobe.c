// svcprobe: XPC service used by r4t5-control.sh. It answers any dictionary
// with {"service": <XPC_SERVICE_NAME>, "marker": "ran"} and appends an event
// line to $TEE_FAKE_LOG (set by the harness), so the harness can tell
// "launchd started our bundle" from "launchd started something else".
#include <xpc/xpc.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

#ifndef TEE_FAKE_LOG_PATH
#define TEE_FAKE_LOG_PATH "/dev/null"
#endif

static void logline(const char *what, long v) {
  const char *env = getenv("TEE_FAKE_LOG");
  const char *path = (env && *env) ? env : TEE_FAKE_LOG_PATH;
  if (!path) return;
  int fd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
  if (fd < 0) return;
  char b[320];
  int n = snprintf(b, sizeof b, "%s pid=%d v=%ld svc=%s\n", what, getpid(), v,
                   getenv("XPC_SERVICE_NAME") ? getenv("XPC_SERVICE_NAME") : "?");
  if (n > 0) { ssize_t w = write(fd, b, (size_t)n); (void)w; }
  close(fd);
}

static void peer_event(xpc_connection_t peer, xpc_object_t ev) {
  xpc_type_t t = xpc_get_type(ev);
  if (t == XPC_TYPE_DICTIONARY) {
    logline("dict", 0);
    xpc_object_t r = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(r, "service",
        getenv("XPC_SERVICE_NAME") ? getenv("XPC_SERVICE_NAME") : "?");
    xpc_dictionary_set_string(r, "marker", "ran");
    xpc_connection_send_message(peer, r);
  } else if (t == XPC_TYPE_ERROR) {
    logline("error", 0);
  } else {
    logline("other", (long)t);
  }
}

static void handler(xpc_connection_t c) {
  logline("peer", 0);
  xpc_connection_set_event_handler(c, ^(xpc_object_t ev) { peer_event(c, ev); });
  xpc_connection_resume(c);
}

int main(void) { logline("start", 0); xpc_main(handler); }
