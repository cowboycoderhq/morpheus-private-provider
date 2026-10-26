// waitclient FLAG: an unsandboxed Metal client. Prints its pid, waits until
// FLAG exists, then compiles a fresh kernel (a new compiler request) and
// reports whether the pipeline was built. Victim for the R4-T5 arm.
#import <Metal/Metal.h>
#include <stdio.h>
#include <unistd.h>
#include <xpc/xpc.h>
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  printf("waitclient pid=%d\n", getpid()); fflush(stdout);
  while (access(argv[1], F_OK) != 0) usleep(200000);
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSString *src = [NSString stringWithFormat:@"kernel void k%u(device float *a [[buffer(0)]]) { a[0] = %u.0; }", arc4random(), arc4random()];
    NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithSource:src options:nil error:&e];
    id<MTLComputePipelineState> p = l ? [d newComputePipelineStateWithFunction:[l newFunctionWithName:[l functionNames][0]] error:&e] : nil;
    printf("waitclient library=%s pipeline=%s err=%s\n", l ? "ok" : "nil", p ? "ok" : "nil", e ? e.localizedDescription.UTF8String : "-");
    // Control: connect to a test-named service. If root's bootstrap into this
    // process's domain works, launchd starts the fake and it leaves a marker.
    xpc_connection_t c = xpc_connection_create("com.tee.fakectl", NULL);
    xpc_connection_set_event_handler(c, ^(xpc_object_t ev) { (void)ev; });
    xpc_connection_resume(c);
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0);
    xpc_connection_send_message(c, m);
    sleep(3);
    printf("waitclient control connection sent\n");
  }
  return 0;
}
