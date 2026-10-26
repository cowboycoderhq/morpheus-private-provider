// xpchost: runs an XPC service lookup from inside an app bundle.
// Usage: xpchost <service-name> <seconds>
// It prints its pid, then connects with the bundle-relative lookup that an
// embedded Contents/XPCServices bundle answers.
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <stdlib.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *name = argc > 1 ? argv[1] : "com.tee.r4t5.control";
    double wait = argc > 2 ? atof(argv[2]) : 6.0;
    printf("host pid=%d service=%s\n", getpid(), name);
    fflush(stdout);
    xpc_connection_t c = xpc_connection_create(name, NULL);
    xpc_connection_set_event_handler(c, ^(xpc_object_t ev) {
      if (xpc_get_type(ev) == XPC_TYPE_DICTIONARY) {
        printf("reply service=%s marker=%s\n",
               xpc_dictionary_get_string(ev, "service"),
               xpc_dictionary_get_string(ev, "marker"));
      } else if (xpc_get_type(ev) == XPC_TYPE_ERROR) {
        printf("error: %s\n", xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION));
      }
      fflush(stdout);
    });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "ping");
    xpc_connection_send_message(c, m);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:wait]];
    printf("host done pid=%d\n", getpid());
  }
  return 0;
}
