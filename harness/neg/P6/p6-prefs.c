// p6-prefs PATH [sb]: read PATH, optionally after sandbox_init with the
// child's file-read rule classes (deny default; /System/Library, /usr/lib, /usr/share).
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int sandbox_init(const char *profile, uint64_t flags, char **errorbuf);
int main(int argc, char **argv) {
  if (argc < 2) return 64;
  if (argc > 2) {
    char *err = NULL;
    const char *p = "(version 1)(deny default)(allow file-read*(subpath \"/System/Library\")(subpath \"/usr/lib\")(subpath \"/usr/share\"))";
    if (sandbox_init(p, 0, &err) != 0) { printf("sandbox_init failed: %s\n", err); return 1; }
    printf("sandboxed\n");
  }
  int fd = open(argv[1], O_RDONLY); char b[16];
  if (fd < 0) { printf("open %s: errno=%d (%s)\n", argv[1], errno, strerror(errno)); return 2; }
  printf("open %s: ok read=%zd\n", argv[1], read(fd, b, sizeof b)); return 0;
}
