// fakecompiler: the executable of the fake XPC bundles (MTLCompilerService.xpc
// with Apple's name, TEEFakeCtl.xpc with a test name). If launchd ever
// starts it, it writes a marker named after its service and exits.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
  const char *n = getenv("XPC_SERVICE_NAME");
  char p[256]; snprintf(p, sizeof p, "/private/tmp/tee-fake-ran-%s-%d", n ? n : "unknown", getpid());
  int fd = open(p, O_CREAT | O_WRONLY, 0644); if (fd >= 0) close(fd);
  return 0;
}
