// outsider: a client with no app bundle, using a global Mach service lookup.
// It must NOT reach a service that lives in another process's pid domain.
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>

int main(int argc, char **argv) {
  @autoreleasepool {
    const char *name = argc > 1 ? argv[1] : "com.tee.r4t5.control";
    printf("outsider pid=%d service=%s\n", getpid(), name);
    fflush(stdout);
    xpc_connection_t c = xpc_connection_create_mach_service(name, NULL, 0);
    xpc_connection_set_event_handler(c, ^(xpc_object_t ev) {
      if (xpc_get_type(ev) == XPC_TYPE_DICTIONARY) {
        printf("OUTSIDER GOT REPLY service=%s marker=%s\n",
               xpc_dictionary_get_string(ev, "service"),
               xpc_dictionary_get_string(ev, "marker"));
      } else if (xpc_get_type(ev) == XPC_TYPE_ERROR) {
        printf("outsider error: %s\n",
               xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION));
      }
      fflush(stdout);
    });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(m, "op", "ping");
    xpc_connection_send_message(c, m);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
    printf("outsider done\n");
  }
  return 0;
}
