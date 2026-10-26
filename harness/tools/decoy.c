// Well-behaved pinned child (R2 socketpair-channel shape, DESIGN v2.28 R2 and
// probes/marker.c): its first act in main is to write the marker file named
// by argv[1] (the R2-T2 "the child ran" oracle), then it sends one fixed
// byte on the channel — the engine-created socketpair end the spawn placed on
// fd 0 and fd 1 (the Splash stdio shape; fd 0 and fd 1 are the same socket,
// so writing on either reaches the engine's end) — and stays connected so the
// engine can read the peer audit token after that byte and finish the
// verification. Any failure -> _exit(113). Compiled three times with
// -DVARIANT=1/2/3: each build has its own CD hash; VARIANT 3 is the
// get-task-allow child (signed with the get-task-allow entitlement).
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#ifndef VARIANT
#define VARIANT 1
#endif

int main(int argc, char **argv) {
    static volatile int variant = VARIANT;
    if (argc > 1 && argv[1][0] != '\0') {
        int fd = open(argv[1], O_CREAT | O_WRONLY, 0644);
        if (fd >= 0) close(fd);
    }
    // The channel's fixed descriptors (Splash shape): fd 0/1, one socket.
    char c = 'S';
    if (write(STDOUT_FILENO, &c, 1) != 1) _exit(113);
    sleep(120);   // stay connected; the verified arm kills us via the harness
    return variant == VARIANT ? 0 : 1;
}
