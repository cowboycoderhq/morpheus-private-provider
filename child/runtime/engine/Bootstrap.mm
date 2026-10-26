#ifdef SPLASH_SEALED
#include "sealed/sealed_r6.h"
#include "sealed/sealed_tee_probe.h"
#include "sealed/sealed_r2.h"
#include <cstdio>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#endif
#include "engine/Bootstrap.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <utility>

namespace splash::engine {
namespace {

RuntimeBootstrapReport reportForPlan(const EngineMemoryPlan &plan) {
  RuntimeBootstrapReport report;
  report.memoryPlanJson = plan.toStatusJson();
  report.budgetDescription = plan.breakdown().describe();
  return report;
}

RuntimeBootstrapReport
reportForResourceFailure(const RuntimeResourcesError &error) {
  RuntimeBootstrapReport report;
  report.resourceFailure = error.failure();
  report.message = error.message();
  report.warmup.error = report.message;
  report.memoryPlanJson = error.statusJson();
  report.budgetDescription = error.budgetDescription();
  return report;
}

[[noreturn]] void fail(RuntimeBootstrapReport report,
                       RuntimeBootstrapStage stage, std::string message) {
  report.ready = false;
  report.stage = stage;
  report.message = std::move(message);
  report.warmup.error = report.message;
  throw RuntimeBootstrapError(std::move(report));
}

} // namespace

std::string_view runtimeBootstrapStageName(RuntimeBootstrapStage stage) {
  switch (stage) {
  case RuntimeBootstrapStage::ResourceAssembly:
    return "resource_assembly";
  case RuntimeBootstrapStage::ModelCreation:
    return "model_creation";
  case RuntimeBootstrapStage::MaximumPrefill:
    return "maximum_prefill";
  case RuntimeBootstrapStage::DecodeWarmup:
    return "decode_warmup";
  case RuntimeBootstrapStage::DraftVerifyCommit:
    return "draft_verify_commit";
  case RuntimeBootstrapStage::CompositeStateRestore:
    return "composite_state_restore";
  case RuntimeBootstrapStage::MemoryAudit:
    return "memory_audit";
  case RuntimeBootstrapStage::AnnounceReady:
    return "announce_ready";
  case RuntimeBootstrapStage::Ready:
    return "ready";
  }
  return "unknown";
}

std::string RuntimeBootstrapReport::describe() const {
  std::ostringstream out;
  out << (ready ? "runtime bootstrap ready" : "runtime bootstrap failed")
      << " [" << runtimeBootstrapStageName(stage) << "]: " << message;
  if (!memoryAudit.message.empty()) {
    out << '\n' << memoryAudit.describe();
  }
  if (!budgetDescription.empty())
    out << '\n' << budgetDescription;
  return out.str();
}

RuntimeBootstrapError::RuntimeBootstrapError(RuntimeBootstrapReport report)
    : std::runtime_error(report.describe()), report_(std::move(report)) {}

RuntimeBootstrapError::RuntimeBootstrapError(const RuntimeResourcesError &error)
    : RuntimeBootstrapError(reportForResourceFailure(error)) {}

RuntimeBootstrap::RuntimeBootstrap(std::unique_ptr<RuntimeResources> resources,
                                   std::unique_ptr<model::RuntimeModel> modelRuntime,
                                   std::unique_ptr<NativeRuntime> nativeLoop,
                                   RuntimeBootstrapReport report)
    : resources_(std::move(resources)), model_(std::move(modelRuntime)),
      nativeLoop_(std::move(nativeLoop)), report_(std::move(report)) {}

RuntimeBootstrap::~RuntimeBootstrap() {
  // Cancel unsubmitted dependency waits before the loop destroys its tickets.
  resources_->backend().stop();
}

RuntimeBootstrapReport RuntimeBootstrap::requireWarmupAndAnnounce(
    const EngineMemoryPlan &memoryPlan, model::RuntimeModel &modelRuntime,
    ActualMemoryReporter memoryReporter, NativeRuntime &nativeLoop) {
  RuntimeBootstrapReport report = reportForPlan(memoryPlan);
  if (!memoryReporter) {
    fail(std::move(report), RuntimeBootstrapStage::MemoryAudit,
         "actual memory reporter is required");
  }
  if (nativeLoop.ready()) {
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "native loop announced ready before bootstrap");
  }
  if (!nativeLoop.engineHealthy()) {
    fail(std::move(report), RuntimeBootstrapStage::AnnounceReady,
         "native loop is unhealthy before warmup");
  }

  uint64_t estimatedPeakBytes = 0;
  auto run = [&](RuntimeBootstrapStage stage, WarmupStepStatus &status,
                 auto &&operation, bool optional = false) {
    model::WarmupStepResult result;
    try {
      result = operation();
    } catch (const metal::MetalAllocationError &error) {
      if (optional) {
        status = WarmupStepStatus::MemoryLimited;
        return model::WarmupStepResult{};
      }
      report.resourceFailure = resourceAllocationFailure(error.failure());
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw: " + error.what());
    } catch (const std::exception &error) {
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw: " + error.what());
    } catch (...) {
      fail(report, stage,
           std::string(runtimeBootstrapStageName(stage)) +
               " threw an unknown exception");
    }
    if (!result.completed || !result.estimatedPeakBytes ||
        !(result.wallSeconds > 0.0) || !std::isfinite(result.wallSeconds)) {
      std::string message = std::string(runtimeBootstrapStageName(stage)) +
                            " did not complete a real measured path";
      if (!result.detail.empty())
        message += ": " + result.detail;
      fail(report, stage, std::move(message));
    }
    estimatedPeakBytes =
        std::max(estimatedPeakBytes, result.estimatedPeakBytes);
    status = WarmupStepStatus::Complete;
    return result;
  };

  model::WarmupStepResult maximumPrefill =
      run(RuntimeBootstrapStage::MaximumPrefill, report.warmup.maximumPrefill,
          [&] {
            return modelRuntime.warmupPrefill(model::ExecutionLimits::prefillTokenBudget);
          });
  nativeLoop.observePrefill(model::ExecutionLimits::prefillTokenBudget,
                           maximumPrefill.wallSeconds * 1000.0);
  report.warmup.maximumPrefillDetail = maximumPrefill.detail;
  const auto &budget = memoryPlan.breakdown();
  // Startup exercises only widths that fit this budget. This is not a
  // serving concurrency limit: the engine still admits lanes dynamically.
  const uint32_t affordableWidth = static_cast<uint32_t>(std::min<uint64_t>(
      model::ExecutionLimits::maximumBatchWidth,
      (budget.dynamicBudgetBytes - budget.kvExtentBytes) /
          budget.activeStateCellBytes));
  for (uint32_t width = 1;
       width <= model::ExecutionLimits::maximumBatchWidth; ++width) {
    if (width > affordableWidth ||
        (width > 1 && report.warmup.decodeBatches[width - 2] ==
                          WarmupStepStatus::MemoryLimited)) {
      report.warmup.decodeBatches[width - 1] = WarmupStepStatus::MemoryLimited;
      continue;
    }
    run(RuntimeBootstrapStage::DecodeWarmup,
        report.warmup.decodeBatches[width - 1],
        [&] { return modelRuntime.warmupDecodeBatch(width); }, width > 1);
  }
  run(RuntimeBootstrapStage::DraftVerifyCommit, report.warmup.draftVerifyCommit,
      [&] { return modelRuntime.warmupDraftVerifyCommit(); });
  run(RuntimeBootstrapStage::CompositeStateRestore,
      report.warmup.compositeStateRestore,
      [&] { return modelRuntime.warmupCompositeStateRestore(); }, true);

  ActualMemoryReport actual;
  try {
    actual = memoryReporter(estimatedPeakBytes);
  } catch (const metal::MetalAllocationError &error) {
    report.resourceFailure = resourceAllocationFailure(error.failure());
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         std::string("actual memory reporting failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         std::string("actual memory reporting failed: ") + error.what());
  } catch (...) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         "actual memory reporting failed with an unknown exception");
  }
  report.warmup.actualPeakBytes = actual.devicePeakAllocatedBytes;
  report.memoryAudit = auditActualMemory(memoryPlan, actual);
  if (!report.memoryAudit.valid) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         report.memoryAudit.describe());
  }
  report.warmup.memoryBudgetValidated = true;
  if (!report.warmup.ready()) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         "warmup report is incomplete after memory validation");
  }

#ifdef SPLASH_SEALED
  // R6 open latch and first self-audit, after the load and before READY.
  if (int missing = sealed_r6_unloaded()) {
    fail(report, RuntimeBootstrapStage::MemoryAudit,
         "sealed: " + std::to_string(missing) + " manifest entries were not loaded");
  }
  // T2: after the load, before the self-audit (the test spawner kills the
  // child as soon as "loaded" arrives). No-op outside test builds.
  sealed_t2_publish("loaded");
  sealed_t2f_probe("loaded");   // T2 follow-up; no-op outside test builds
  sealed_s1_share("loaded");    // S-1; no-op outside test builds
#if defined(SEALED_TEST_REREAD)
  {
    // Test build: read a loaded manifest file a second time (before the latch).
    const char *const *paths = nullptr;
    size_t n = sealed_r6_abs_paths(&paths);
    uint64_t len = 0;
    if (n > 0) (void)sealed_r6_read(paths[0], &len);
  }
#endif
#if defined(SEALED_TEST_BYPASS_OPEN)
  {
    // Test build: a loader open of a manifest file that bypasses the funnel,
    // after the load and under the sandbox. BYPASS_CLOSE closes it again.
    const char *const *paths = nullptr;
    size_t n = sealed_r6_abs_paths(&paths);
    int fd = n > 0 ? ::open(paths[0], O_RDONLY | O_CLOEXEC) : -1;
    char line[1300];
    int m = std::snprintf(line, sizeof line, "test: bypass open of %s fd=%d errno=%d\n", n > 0 ? paths[0] : "-", fd, fd < 0 ? errno : 0);
    if (m > 0) sealed_reason_write(line, static_cast<size_t>(m));
#if defined(SEALED_TEST_BYPASS_CLOSE)
    if (fd >= 0) ::close(fd);
#endif
  }
#endif
  sealed_r6_latch();
#if defined(SEALED_TEST_REOPEN_AFTER_LATCH)
  { uint64_t n = 0; (void)sealed_r6_read("/reopen-after-latch-test", &n); }
#endif
  {
    char why[1024] = {0};
    if (sealed_r6_self_audit(why, sizeof why) != 0) {
      std::fprintf(stderr, "sealed-r6: self-audit failed: %s\n", why);
      std::fflush(stderr);
      { char line[1100]; int n = std::snprintf(line, sizeof line, "sealed-r6: self-audit failed: %s\n", why);
        if (n > 0) sealed_reason_write(line, static_cast<size_t>(n)); }
      _exit(113);
    }
  }
  sealed_r7_after_load();          // no-op outside test builds (R7-T3)
  sealed_tee_probe("postload");    // no-op outside test builds (R7-T3 crash arm)
  {
    // Report "loaded" with the manifest hash (hash form, kind 2) before READY.
    uint8_t msg[36] = {'S', 'L', 'L', 'D'};
    sealed_r6_manifest_hash(msg + 4);
    size_t off = 0;
    while (off < sizeof msg) {
      ssize_t w = ::write(1, msg + off, sizeof msg - off);
      if (w < 0 && errno == EINTR) continue;
      if (w <= 0) _exit(113);
      off += static_cast<size_t>(w);
    }
  }
  sealed_tee_probe("loaded");   // no-op outside test builds
  sealed_r7_check("loaded");    // no-op outside test builds (R7-T3)
#endif
  try {
    nativeLoop.announceReady();
  } catch (const std::exception &error) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         std::string("binary ReadyEvent announcement failed: ") + error.what());
  } catch (...) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         "binary ReadyEvent announcement failed with an unknown exception");
  }
  if (!nativeLoop.ready()) {
    fail(report, RuntimeBootstrapStage::AnnounceReady,
         "native loop did not enter ready state");
  }
  report.ready = true;
  report.stage = RuntimeBootstrapStage::Ready;
  report.message = "required warmup paths and memory audit passed";
  report.warmup.error.clear();
  return report;
}

std::unique_ptr<RuntimeBootstrap> RuntimeBootstrap::start(
    RuntimeBootstrapConfig config,
    NativeRuntime::ByteSink output,
    NativeRuntime::StatusProvider statusProvider) {
  std::unique_ptr<RuntimeResources> resources;
  try {
    resources = RuntimeResources::create(config.resources);
  } catch (const RuntimeResourcesError &error) {
    throw RuntimeBootstrapError(error);
  }

  RuntimeBootstrapReport base = reportForPlan(resources->memoryPlan());
  const uint32_t automaticContext =
      resources->memoryPlan().maximumContextTokens();
  if (!automaticContext) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "memory plan cannot hold one model token");
  }
  if (!config.nativeLoop.engine.maxContext) {
    config.nativeLoop.engine.maxContext = automaticContext;
  } else if (config.nativeLoop.engine.maxContext > automaticContext) {
#if defined(SPLASH_SEALED)
    // Chunked KV: MAX_CONTEXT stays the logical limit. The KV budget bounds
    // one request at automaticContext; the engine answers a longer request
    // with capacity_exhausted (HTTP 503) and the budget in the reason.
#else
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "logical max_context exceeds the model or physical "
         "single-request Q8 KV capacity");
#endif
  }
  // The parser and engine consume the same resolved ceiling. In automatic
  // mode these limits cannot be known until resource planning has measured
  // the device and built the immutable page pool.
  config.protocolLimits.maxPromptTokens = config.nativeLoop.engine.maxContext;
  config.protocolLimits.maxLogicalOutputTokens =
      config.nativeLoop.engine.maxContext;
  config.nativeLoop.engine.vocabularySize =
      config.resources.model.capabilities.vocabularySize;

  std::unique_ptr<model::RuntimeModel> modelRuntime;
  try {
    const model::ModelMemoryPlan &modelMemory =
        resources->modelMemoryPlan();
    if (modelMemory.sharedDecodePlannedAllocatedBytes >
        std::numeric_limits<uint64_t>::max() -
            modelMemory.sharedPrefillPlannedAllocatedBytes) {
      throw std::overflow_error(
          "modelRuntime shared allocation reservation overflows");
    }
    const uint64_t modelBytes =
        modelMemory.sharedPrefillPlannedAllocatedBytes +
        modelMemory.sharedDecodePlannedAllocatedBytes;
    metal::AllocationFailure failure;
    auto reservation = resources->memoryGovernor().tryReserve(modelBytes, &failure);
    if (!reservation) {
      throw metal::MetalAllocationError(
          std::string("unable to reserve model arenas: ") +
              metal::allocationFailureName(failure), failure);
    }
    modelRuntime = model::createRuntime(resources->modelContext());
    reservation->commit();
  } catch (const metal::MetalAllocationError &error) {
    base.resourceFailure = resourceAllocationFailure(error.failure());
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("modelRuntime creation failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("modelRuntime creation failed: ") + error.what());
  } catch (...) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         "modelRuntime creation failed with an unknown exception");
  }
  std::unique_ptr<NativeRuntime> nativeLoop;
  try {
    config.nativeLoop.engine.growthPaused =
        [governor = &resources->memoryGovernor()] {
          return !governor->snapshot().hostGrowthAllowed;
        };
    nativeLoop = std::make_unique<NativeRuntime>(
        config.nativeLoop, resources->cache(), *modelRuntime,
        std::move(output), std::move(statusProvider), NativeLoopClocks{},
        config.protocolLimits);
  } catch (const metal::MetalAllocationError &error) {
    base.resourceFailure = resourceAllocationFailure(error.failure());
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("modelRuntime creation failed: ") + error.what());
  } catch (const std::exception &error) {
    fail(std::move(base), RuntimeBootstrapStage::ModelCreation,
         std::string("native loop creation failed: ") + error.what());
  }

  RuntimeResources *resourcesPointer = resources.get();
  model::RuntimeModel *modelPointer = modelRuntime.get();
  RuntimeBootstrapReport report = requireWarmupAndAnnounce(
      resources->memoryPlan(), *modelRuntime,
      [resourcesPointer, modelPointer](uint64_t estimatedPeakBytes) {
        resourcesPointer->backend().checkOperation();
        // Audit every attempted warmup before reclaiming idle buffers.
        // Wider batches and cache backing grow on demand after Ready.
        ActualMemoryReport report = resourcesPointer->actualMemoryReport(
            modelPointer->actualRuntimeMemory(), estimatedPeakBytes);
        // Keep one lane's worth of warm buffers for the first request.
        static_cast<void>(resourcesPointer->stateStorage().releaseIdle(2, 1));
        resourcesPointer->cache().releaseUnusedKvBacking();
        return report;
      },
      *nativeLoop);

  return std::unique_ptr<RuntimeBootstrap>(
      new RuntimeBootstrap(std::move(resources), std::move(modelRuntime),
                           std::move(nativeLoop), std::move(report)));
}

} // namespace splash::engine
