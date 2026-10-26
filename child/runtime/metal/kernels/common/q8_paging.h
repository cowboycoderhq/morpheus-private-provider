#pragma once

#include "metal/abi/ExecutionGeometry.h"
#include <metal_stdlib>

using namespace metal;

// Q8 KV page geometry shared by the attention and store kernels. A page holds
// SplashQ8PageTokens tokens of every KV head: keys token-major, values
// dimension-major, and one fp32 scale per (KV head, token) for each tensor.
constant uint SplashQ8PageTokens = SPLASH_TARGET_KV_BLOCK_TOKENS;
constant uint SplashQ8HeadDimension = 256;

template <uint KVHeads>
inline ulong splash_q8_key_index(uint page, uint head, uint token,
                                   uint dimension) {
  constexpr ulong ElementsPerPage =
      ulong(KVHeads) * SplashQ8PageTokens * SplashQ8HeadDimension;
  return ulong(page) * ElementsPerPage +
         (ulong(head) * SplashQ8PageTokens + token) *
             SplashQ8HeadDimension +
         dimension;
}

template <uint KVHeads>
inline ulong splash_q8_value_index(uint page, uint head, uint token,
                                     uint dimension) {
  constexpr ulong ElementsPerPage =
      ulong(KVHeads) * SplashQ8PageTokens * SplashQ8HeadDimension;
  return ulong(page) * ElementsPerPage +
         (ulong(head) * SplashQ8HeadDimension + dimension) *
             SplashQ8PageTokens +
         token;
}

template <uint KVHeads>
inline ulong splash_q8_scale_index(uint page, uint head, uint token) {
  constexpr ulong ScalesPerPage = ulong(KVHeads) * SplashQ8PageTokens;
  return ulong(page) * ScalesPerPage + ulong(head) * SplashQ8PageTokens +
         token;
}

#if defined(SPLASH_KV_CHUNKED)
// Sealed chunked KV (review/CHUNKED-KV-2026-10-23.md). Each Q8 tensor binding
// is a table with one base address per chunk of SplashQ8ChunkPages pages; the
// host writes MTLBuffer.gpuAddress values. A physical page p is page
// p % SplashQ8ChunkPages of chunk p / SplashQ8ChunkPages, and the page layout
// inside a chunk region is the flat layout above.
constant uint SplashQ8ChunkPages = SPLASH_KV_CHUNK_PAGES;
struct SplashQ8DataChunk {
  device int8_t *base;
};
struct SplashQ8ScaleChunk {
  device float *base;
};
#define SPLASH_Q8_DATA device const SplashQ8DataChunk *
#define SPLASH_Q8_STORE_DATA device const SplashQ8DataChunk *
#define SPLASH_Q8_SCALES device const SplashQ8ScaleChunk *
#define SPLASH_Q8_CONST_SCALES device const SplashQ8ScaleChunk *

template <uint KVHeads>
inline device int8_t *splash_q8_data_page(SPLASH_Q8_DATA data, uint page) {
  return data[page / SplashQ8ChunkPages].base +
         splash_q8_key_index<KVHeads>(page % SplashQ8ChunkPages, 0, 0, 0);
}

template <uint KVHeads>
inline device float *splash_q8_scale_page(SPLASH_Q8_SCALES scales,
                                          uint page) {
  return scales[page / SplashQ8ChunkPages].base +
         splash_q8_scale_index<KVHeads>(page % SplashQ8ChunkPages, 0, 0);
}
#else
#define SPLASH_Q8_DATA device int8_t *
#define SPLASH_Q8_STORE_DATA device char *
#define SPLASH_Q8_SCALES device float *
#define SPLASH_Q8_CONST_SCALES device const float *

template <uint KVHeads, typename Pointer>
inline Pointer splash_q8_data_page(Pointer data, uint page) {
  return data + splash_q8_key_index<KVHeads>(page, 0, 0, 0);
}

template <uint KVHeads, typename Pointer>
inline Pointer splash_q8_scale_page(Pointer scales, uint page) {
  return scales + splash_q8_scale_index<KVHeads>(page, 0, 0);
}
#endif
