#!/bin/bash
# R4-T5 (user-level arm): can the operator, without root, make launchd inject
# a library into the Metal compiler service that the sealed child uses?
# launchctl setenv puts DYLD_INSERT_LIBRARIES into the GUI domain for a short
# window; a fresh Metal client then starts a new MTLCompilerService instance.
# Control: an ad-hoc, non-hardened job started by launchd in the same window
# must load the library (proves the variable reaches launchd's children).
# Pass: no marker from MTLCompilerService, a marker from the control job.
set -u
W=/tmp/tee-dyld; rm -rf $W; mkdir -p $W
cleanup() { launchctl unsetenv DYLD_INSERT_LIBRARIES; launchctl remove com.tee.dyldctl 2>/dev/null; }
trap cleanup EXIT
cat > $W/marker.c <<'EOF'
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <mach-o/dyld.h>
__attribute__((constructor)) static void mark(void) {
  char exe[1024]; uint32_t n = sizeof exe; char p[1200];
  if (_NSGetExecutablePath(exe, &n) != 0) exe[0] = 0;
  const char *b = exe; for (const char *c = exe; *c; c++) if (*c == '/') b = c + 1;
  snprintf(p, sizeof p, "/tmp/tee-dyld/marker-%d-%s", getpid(), b);
  int fd = open(p, O_CREAT | O_WRONLY, 0644); if (fd >= 0) close(fd);
}
EOF
cat > $W/ctl.c <<'EOF'
#include <unistd.h>
int main(void) { sleep(2); return 0; }
EOF
cat > $W/client.m <<'EOF'
#import <Metal/Metal.h>
#include <stdio.h>
int main(void) {
  @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    NSString *src = [NSString stringWithFormat:@"kernel void k%u(device float *a [[buffer(0)]]) { a[0] = %u.0; }", arc4random(), arc4random()];
    NSError *e = nil;
    id<MTLLibrary> l = [d newLibraryWithSource:src options:nil error:&e];
    id<MTLFunction> f = [l newFunctionWithName:[l functionNames][0]];
    id<MTLComputePipelineState> p = [d newComputePipelineStateWithFunction:f error:&e];
    printf("client: library=%s pipeline=%s\n", l ? "ok" : "nil", p ? "ok" : "nil");
  }
  return 0;
}
EOF
clang -dynamiclib -o $W/marker.dylib $W/marker.c && codesign -f -s - $W/marker.dylib 2>/dev/null
clang -o $W/ctl $W/ctl.c && codesign -f -s - $W/ctl 2>/dev/null
clang -fobjc-arc -framework Metal -framework Foundation -o $W/client $W/client.m || exit 1
before=$(pgrep -f MTLCompilerService | sort | tr '\n' ' ')
launchctl setenv DYLD_INSERT_LIBRARIES $W/marker.dylib
launchctl submit -l com.tee.dyldctl -- $W/ctl
sleep 1
$W/client
sleep 2
after=$(pgrep -f MTLCompilerService | sort | tr '\n' ' ')
cleanup; trap - EXIT
new=$(comm -13 <(echo "$before" | tr ' ' '\n' | sort) <(echo "$after" | tr ' ' '\n' | sort) | tr '\n' ' ')
echo "compiler instances before: $before"
echo "compiler instances after:  $after (new: ${new:-none})"
echo "markers:"; ls $W | grep '^marker-' | sed 's/^/  /'
ctl=$(ls $W | grep -c 'marker-.*-ctl$'); comp=$(ls $W | grep -c 'marker-.*-MTLCompilerService$')
[ "$ctl" -ge 1 ] && echo "PASS control: launchd's child loaded the library ($ctl)" || echo "FAIL control: no marker from the control job (the variable did not reach launchd's children; arm inconclusive)"
[ "$comp" = 0 ] && echo "PASS R4-T5 user arm: no MTLCompilerService instance loaded the library" || echo "FAIL R4-T5 user arm: MTLCompilerService loaded the library ($comp)"
echo "env after cleanup: $(launchctl getenv DYLD_INSERT_LIBRARIES || true)"
