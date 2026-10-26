// ctlproc: unhardened control. Reads lines from stdin forever (so dtrace's
// read probe sees the canary) and keeps a canary string in memory.
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static char canary[64] = "TEE-CONTROL-CANARY-IN-MEMORY";
int main(void) { char b[256]; ssize_t n; while ((n = read(0, b, sizeof b)) > 0) { (void)n; } (void)canary; for (;;) pause(); }
