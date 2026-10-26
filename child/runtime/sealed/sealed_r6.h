// sealed_r6 — R6 weights manifest and integrity for the sealed Splash child.
//
// One funnel for every model-file access (open, stat, directory listing). It
// refuses any path not in the manifest, reads each file into anonymous
// page-aligned memory with read(), checks size and SHA-256 against the
// manifest, and engages an open latch after the load. After the latch, every
// open ends the child (_exit(113)).
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SEALED_R6_KIND_SPLASH 2u           // backendID kind (spec R10: 2 = splash)
#define SEALED_R6_PREFIX "sealed-manifest-v2"
#define SEALED_R6_MAX_ENTRIES 512
#define SEALED_R6_MAX_PATH 255

typedef struct {
    uint8_t tag;                 // 1 = target root, 2 = draft root, 3 = package root (Splash: manifest.json, tokenizer/, vision/)
    char path[SEALED_R6_MAX_PATH + 1];  // relative to its root, '/'-separated, no '.'/'..'
    uint64_t size;
    uint8_t sha256[32];
    int loaded;                  // the funnel read and verified it
} sealed_r6_entry_t;

// Parses the file form of the manifest (prefix, u32 count, entries). Returns 0
// on success, -1 on any encoding error (unsorted, duplicate, bad path, too many).
int sealed_r6_parse(const uint8_t *buf, size_t len);

// Computes the manifest hash (hash form: the file form with the backend kind
// inserted after the prefix). Valid after sealed_r6_parse.
void sealed_r6_manifest_hash(uint8_t out[32]);

// Opens the root directories (O_DIRECTORY | O_NOFOLLOW, each component opened
// relative to its parent) and every intermediate directory the manifest names.
// Must run before the sandbox. Returns 0 or -1.
int sealed_r6_open_roots(const char *package_root, const char *target_root, const char *draft_root);

// Maps an absolute path the loader asks for to a manifest entry. Returns the
// entry index or -1 (not in the manifest).
int sealed_r6_lookup(const char *abs_path);

// Reads one manifest file fully into anonymous, page-aligned memory (rounded
// up to the page size, zero-filled), checks size and SHA-256. On any mismatch
// or I/O error the child exits (_exit(113)). Returns the buffer; *len receives
// the file size. The memory is never freed by the funnel.
void *sealed_r6_read(const char *abs_path, uint64_t *len);

// File size from the in-memory manifest (no system call). -1 if not listed.
int64_t sealed_r6_size(const char *abs_path);

// Absolute paths of every manifest entry (root path + relative path), for the
// R5 profile's literal slots. Valid after sealed_r6_open_roots.
size_t sealed_r6_abs_paths(const char *const **out);

// Engages the open latch, closes the root descriptors. After this, every
// sealed_r6_read ends the child.
void sealed_r6_latch(void);

// Checks that every required manifest entry was loaded. Returns the number of
// entries not loaded (0 = complete).
int sealed_r6_unloaded(void);

// Records that the loader wrapped a funnel buffer in a Metal no-copy buffer.
// The region must then read SM_TRUESHARED with ref count 1 + wraps (measured:
// each wrap adds one reference); otherwise the self-audit fails.
void sealed_r6_note_gpu_wrap(const void *address);

// R6 self-audit: walks the process address space and returns 0 if no region
// is file-backed by anything other than the executable and system-volume
// libraries (dyld shared cache included); otherwise -1 and writes the first
// offending path to `why`. After the latch it also runs the S3 checks:
// every funnel region keeps its recorded share mode, reference count and
// read-only protection; no descriptor refers to a funnel-opened file, a model
// root, a path under a model root, or a file outside the sealed volume; and
// the open log names each manifest path once, as the kernel reports it.
int sealed_r6_self_audit(char *why, size_t why_len);

// Sum of manifest sizes for the target, draft and package (vision) roots below
// `package_root`; from the in-memory manifest, no system call.
uint64_t sealed_r6_total_bytes(const char *package_root);

// Loader entry for the sealed build: parses the manifest file form, opens the
// roots, and returns 0. On failure the child exits (_exit(113)).
void sealed_r6_init(const uint8_t *manifest, size_t len, const char *package_root);

#ifdef __cplusplus
}
#endif
