#include "ops/Q8PageStorage.hpp"

#include <algorithm>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#if defined(SEALED_TEST_CKV_NOTES)
#include "sealed/sealed_r2.h"
#include <chrono>
#include <cstdarg>
#include <cstdio>
#endif

namespace splash::kv {

static_assert(kv::kSparseMappingAlignmentBytes ==
                  metal::MetalBackend::kPlacementSparsePageBytes,
              "KV sparse mapping alignment must equal the Metal placement page");
namespace {

uint64_t checkedMultiply(uint64_t left, uint64_t right) {
    if (left && right > std::numeric_limits<uint64_t>::max() / left) {
        throw std::overflow_error("Q8 page storage size overflow");
    }
    return left * right;
}

#if defined(SEALED_TEST_CKV_NOTES)
// Test build: chunk allocate and release timings in the reason file.
void ckvNote(const char *format, ...) {
    char line[256];
    va_list args;
    va_start(args, format);
    int n = std::vsnprintf(line, sizeof line - 1, format, args);
    va_end(args);
    if (n <= 0) return;
    if (n > static_cast<int>(sizeof line) - 2) n = static_cast<int>(sizeof line) - 2;
    line[n] = '\n';
    sealed_reason_write(line, static_cast<size_t>(n) + 1);
}

double ckvMicros(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::micro>(
        std::chrono::steady_clock::now() - start).count();
}
#endif

}  // namespace

Q8PageStorage::Q8PageStorage(metal::MetalBackend &backend,
    metal::AllocationAdmission admitAllocation, Q8Layout layout,
    uint32_t pageCount)
    : backend_(backend), admitAllocation_(std::move(admitAllocation)),
      layout_(layout), pageCount_(pageCount), layers_(layout.attentionLayers) {
    if (!admitAllocation_) {
        throw std::invalid_argument(
            "Q8 page storage requires physical allocation admission");
    }
    if (!layout_.valid()) {
        throw std::invalid_argument("Q8 page storage layout is invalid");
    }
    if (!pageCount || pageCount % sparseMappingBatchPages()) {
        throw std::invalid_argument(
            "Q8 page pool is not sparse-mapping aligned");
    }
    const StorageByteCounts bytes = layout_.storageByteCounts(pageCount);
#if defined(SPLASH_SEALED)
    // Sealed chunked KV (review/CHUNKED-KV-2026-10-23.md): every chunk of
    // kChunkPages pages is one private buffer, allocated on demand. A chunk
    // holds, per layer, the keys, key scales, values and value scales of its
    // pages in the flat page layout. The kernels read one base address per
    // (layer, tensor, chunk) from chunkTable_; each layer binding below is a
    // view of that table, so the dispatch code is unchanged.
    {
        const uint64_t chunks = pageCount / kChunkPages;
        chunkBytes_ = checkedMultiply(kChunkPages, layout_.bytesPerModelPage());
        const uint64_t tableBytes = checkedMultiply(chunks, sizeof(uint64_t));
        chunkTable_ = backend_.allocateBuffer(
            checkedMultiply(tableBytes, uint64_t{layout_.attentionLayers} * 4),
            metal::BufferStorage::Shared, "q8-kv-chunk-table");
        std::memset(chunkTable_.contents(), 0, chunkTable_.sizeBytes());
        for (uint32_t layerIndex = 0; layerIndex < layers_.size();
             ++layerIndex) {
            const uint64_t base = uint64_t{layerIndex} * 4 * tableBytes;
            Q8LayerStorage &storage = layers_[layerIndex];
            storage.keyData = backend_.view(chunkTable_, base, tableBytes);
            storage.keyScales =
                backend_.view(chunkTable_, base + tableBytes, tableBytes);
            storage.valueData =
                backend_.view(chunkTable_, base + 2 * tableBytes, tableBytes);
            storage.valueScales =
                backend_.view(chunkTable_, base + 3 * tableBytes, tableBytes);
        }
    }
#else
    for (uint32_t layerIndex = 0; layerIndex < layers_.size();
         ++layerIndex) {
        std::string prefix = "q8-kv-layer-" +
                             std::to_string(layerIndex) + "-";
        Q8LayerStorage &storage = layers_[layerIndex];
        storage.keyData = backend_.allocatePlacementSparseBuffer(
            checkedMultiply(pageCount, layout_.dataBytesPerLayerPage()),
            kSparseMappingAlignmentBytes, prefix + "keys");
        storage.keyScales = backend_.allocatePlacementSparseBuffer(
            checkedMultiply(pageCount, layout_.scaleBytesPerLayerPage()),
            kSparseMappingAlignmentBytes, prefix + "key-scales");
        storage.valueData = backend_.allocatePlacementSparseBuffer(
            checkedMultiply(pageCount, layout_.dataBytesPerLayerPage()),
            kSparseMappingAlignmentBytes, prefix + "values");
        storage.valueScales = backend_.allocatePlacementSparseBuffer(
            checkedMultiply(pageCount, layout_.scaleBytesPerLayerPage()),
            kSparseMappingAlignmentBytes, prefix + "value-scales");
    }
#endif
    if (declaredBytes() != bytes.total) {
        throw std::logic_error("Q8 storage accounting mismatch");
    }

    for (uint32_t first = 0; first < pageCount_;
         first += backingExtentPages()) {
        uint32_t count = std::min(backingExtentPages(), pageCount_ - first);
        if (count % sparseMappingBatchPages()) {
            throw std::logic_error("Q8 backing extent is not tile aligned");
        }
        extents_.push_back(Extent{first, count, std::nullopt, {}});
    }
    // One small runway makes startup warmup and the first requests allocation
    // free. Every later extent remains virtual until real tokens need it.
    if (auto result = ensureResident(0); !result) {
        throw metal::MetalAllocationError(
            std::string("unable to allocate initial Q8 backing extent: ") +
                metal::allocationFailureName(result.failure), result.failure);
    }
}

Q8PageStorage::~Q8PageStorage() {
#if defined(SPLASH_SEALED)
    // Commands retain the chunk buffers they used; this drops the last
    // storage reference.
    for (Extent &extent : extents_) {
        if (!extent.chunk) continue;
        try {
            backend_.removeIndirectResource(extent.chunk);
        } catch (...) {
        }
        extent.chunk = {};
    }
#else
    // Pace GPU-written extent releases to avoid long stalls in the OS kernel.
    for (Extent &extent : extents_) {
        if (!backend_.healthy()) break;
        if (!extent.heap) continue;
        try {
            // unmapSparse waits for the previous extent's unmap itself.
            auto mappings = mappingsFor(extent);
            backend_.unmapSparse(mappings, std::move(*extent.heap));
        } catch (...) {
            // Shutdown cannot recover or safely report an exception. The
            // Metal resources are still released in deterministic C++ order.
        }
        extent.heap.reset();
    }
    if (!backend_.healthy()) return;
    try {
        backend_.drainSparseUnmaps();
    } catch (...) {
    }
#endif
}

uint64_t Q8PageStorage::declaredBytes() const noexcept {
    return uint64_t(pageCount_) * layout_.bytesPerModelPage();
}

uint64_t Q8PageStorage::actualAllocatedBytes() const noexcept {
    return residentBackingBytes_;
}

uint32_t Q8PageStorage::residentPages() const noexcept {
    return residentPages_;
}

size_t Q8PageStorage::extentIndex(uint32_t page) const {
    if (page >= pageCount_) throw std::out_of_range("invalid Q8 page id");
    return page / backingExtentPages();
}

uint32_t Q8PageStorage::extentFirstPage(uint32_t page) const {
    return extents_.at(extentIndex(page)).firstPage;
}

uint32_t Q8PageStorage::extentPageCount(uint32_t page) const {
    return extents_.at(extentIndex(page)).pageCount;
}

bool Q8PageStorage::isResident(uint32_t page) const {
#if defined(SPLASH_SEALED)
    return static_cast<bool>(extents_.at(extentIndex(page)).chunk);
#else
    return extents_.at(extentIndex(page)).heap.has_value();
#endif
}

#if defined(SPLASH_SEALED)
void Q8PageStorage::writeChunkAddresses(size_t chunk,
                                        uint64_t base) noexcept {
    auto *table = static_cast<uint64_t *>(chunkTable_.contents());
    const uint64_t chunks = extents_.size();
    const uint64_t data = uint64_t{kChunkPages} * layout_.dataBytesPerLayerPage();
    const uint64_t scale =
        uint64_t{kChunkPages} * layout_.scaleBytesPerLayerPage();
    const uint64_t layerStride =
        uint64_t{kChunkPages} * layout_.bytesPerLayerPage();
    // Tensor order within a layer region: keys, key scales, values, value
    // scales; the same order as the table views.
    const uint64_t offsets[4] = {0, data, data + scale, 2 * data + scale};
    for (uint64_t layerIndex = 0; layerIndex < layers_.size(); ++layerIndex) {
        for (uint64_t tensor = 0; tensor < 4; ++tensor) {
            table[(layerIndex * 4 + tensor) * chunks + chunk] =
                base ? base + layerIndex * layerStride + offsets[tensor] : 0;
        }
    }
}
#endif

std::vector<metal::SparseMapping> Q8PageStorage::mappingsFor(
    const Extent &extent) const {
    std::vector<metal::SparseMapping> mappings;
    mappings.reserve(uint64_t{layout_.attentionLayers} * 4);
    uint64_t heapOffset = 0;
    auto append = [&](const metal::MetalBuffer &buffer,
                      uint64_t bytesPerPage) {
        uint64_t bufferOffset = checkedMultiply(
            extent.firstPage, bytesPerPage);
        uint64_t size = checkedMultiply(extent.pageCount, bytesPerPage);
        mappings.push_back({buffer, bufferOffset, size, heapOffset});
        heapOffset += size;
    };
    for (const Q8LayerStorage &storage : layers_) {
        append(storage.keyData, layout_.dataBytesPerLayerPage());
        append(storage.keyScales, layout_.scaleBytesPerLayerPage());
        append(storage.valueData, layout_.dataBytesPerLayerPage());
        append(storage.valueScales, layout_.scaleBytesPerLayerPage());
    }
    uint64_t expected = checkedMultiply(
        extent.pageCount, layout_.bytesPerModelPage());
    if (heapOffset != expected) {
        throw std::logic_error("Q8 sparse mapping geometry mismatch");
    }
    return mappings;
}

metal::AllocationResult Q8PageStorage::ensureResident(uint32_t page) {
#if defined(SPLASH_SEALED)
    const size_t index = extentIndex(page);
    Extent &chunkExtent = extents_.at(index);
    if (chunkExtent.chunk) return true;
#if defined(SEALED_TEST_CKV_NOTES)
    const auto noteStart = std::chrono::steady_clock::now();
#endif
    try {
        return admitAllocation_(chunkBytes_, [&] {
            metal::MetalBuffer chunk = backend_.allocateBuffer(
                chunkBytes_, metal::BufferStorage::Private,
                "q8-kv-chunk-" + std::to_string(index));
            if (chunk.sizeBytes() != chunkBytes_ || !chunk.gpuAddress()) {
                throw std::logic_error(
                    "Q8 chunk buffer differs from the admitted chunk bytes");
            }
            backend_.addIndirectResource(chunk);
            writeChunkAddresses(index, chunk.gpuAddress());
            residentBackingBytes_ += chunkBytes_;
            residentPages_ += chunkExtent.pageCount;
            chunkExtent.chunk = std::move(chunk);
#if defined(SEALED_TEST_CKV_NOTES)
            ckvNote("test: ckv alloc chunk=%zu us=%.1f resident_chunks=%u",
                    index, ckvMicros(noteStart), residentPages_ / kChunkPages);
#endif
        });
    } catch (const metal::MetalAllocationError &error) {
        return error.failure();
    }
#else
    Extent &extent = extents_.at(extentIndex(page));
    if (extent.heap) return true;
    uint64_t bytes = checkedMultiply(extent.pageCount,
                                     layout_.bytesPerModelPage());
    try {
        return admitAllocation_(bytes, [&] {
            std::optional<metal::SparseHeap> heap;
            heap.emplace(backend_.allocatePlacementHeap(
                bytes, kSparseMappingAlignmentBytes,
                "q8-kv-extent-" + std::to_string(extent.firstPage)));
            if (heap->sizeBytes() != bytes) {
                throw std::logic_error(
                    "placement heap size differs from admitted Q8 extent bytes");
            }
            auto mappings = mappingsFor(extent);
            backend_.mapSparse(*heap, mappings);
            residentBackingBytes_ += heap->sizeBytes();
            residentPages_ += extent.pageCount;
            extent.heap = std::move(heap);
        });
    } catch (const metal::MetalAllocationError &error) {
        return error.failure();
    }
#endif
}

bool Q8PageStorage::releaseBackingForPage(uint32_t page) {
#if defined(SPLASH_SEALED)
    // The table entries go first, then the buffer. A submitted command can
    // still read the table, so a release waits for a command-free point.
    const size_t index = extentIndex(page);
    Extent &extent = extents_.at(index);
    if (!extent.chunk || !backend_.commandIdle()) return false;
#if defined(SEALED_TEST_CKV_NOTES)
    const auto noteStart = std::chrono::steady_clock::now();
#endif
    if (residentBackingBytes_ < chunkBytes_ || residentPages_ < extent.pageCount) {
        throw std::logic_error("Q8 resident accounting underflowed");
    }
    backend_.removeIndirectResource(extent.chunk);
    writeChunkAddresses(index, 0);
    residentBackingBytes_ -= chunkBytes_;
    residentPages_ -= extent.pageCount;
    extent.chunk = {};
#if defined(SEALED_TEST_CKV_NOTES)
    ckvNote("test: ckv release chunk=%zu us=%.1f resident_chunks=%u", index,
            ckvMicros(noteStart), residentPages_ / kChunkPages);
#endif
    return true;
#else
    Extent &extent = extents_.at(extentIndex(page));
    if (!extent.heap) return false;
    const uint64_t heapBytes = extent.heap->sizeBytes();
    if (residentBackingBytes_ < heapBytes || residentPages_ < extent.pageCount) {
        throw std::logic_error("Q8 resident accounting underflowed");
    }
    auto mappings = mappingsFor(extent);
    // The backend owns the heap from here until the unmap has completed.
    // A validation failure throws before the move, leaving the extent intact.
    backend_.unmapSparse(mappings, std::move(*extent.heap));
    residentBackingBytes_ -= heapBytes;
    residentPages_ -= extent.pageCount;
    extent.heap.reset();
    return true;
#endif
}

bool Q8PageStorage::releaseReady() const noexcept {
#if defined(SPLASH_SEALED)
    return backend_.commandIdle();
#else
    return !backend_.sparseUnmapPending();
#endif
}

void Q8PageStorage::awaitRelease() {
    backend_.drainSparseUnmaps();
}

const Q8LayerStorage &Q8PageStorage::layer(uint32_t index) const {
    if (index >= layers_.size()) {
        throw std::out_of_range("invalid attention layer index");
    }
    return layers_[index];
}

}  // namespace splash::kv
