#ifdef SPLASH_SEALED
#include <sys/mman.h>
#include <cstring>
#include "sealed/sealed_r2.h"
#include "sealed/sealed_r5.h"
#include "sealed_guard.h"
#include "sealed/sealed_r6.h"
#include "sealed/sealed_tee_probe.h"
#include <fcntl.h>
#endif
#include "ops/Vision.hpp"
#include "engine/MemoryPlan.hpp"
#include "engine/FdTransport.hpp"
#include "engine/Bootstrap.hpp"
#include "engine/Status.hpp"
#include "model/Model.hpp"
#include "model/ModelDescriptor.hpp"

#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <charconv>
#include <csignal>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <limits.h>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#ifndef SPLASH_BUILD_ID
#error "production build requires the generated BuildIdentity.hpp"
#endif

namespace splash {
namespace {

// One image may cover at most this many 16x16 patches (4,194,304 pixels).
// The wire limit, the engine's request validation, and the model's vision
// scratch are all sized from this one value.
constexpr uint32_t kMaximumImagePatches = ops::kMaximumImagePatches;
// Temporary host/driver allocation failures can recover during startup.
// Preserve the desktop reserve and bound retries; configuration and compute
// failures remain immediate and fail-closed.
constexpr auto kStartupMemoryRecoveryTimeout = std::chrono::seconds(30);
constexpr auto kStartupMemoryRecoveryPoll = std::chrono::seconds(1);
class UsageError final : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

struct NativeArguments final {
  std::filesystem::path modelRoot;
  model::ModelDescriptor model;
  uint32_t maxContext = 0;
  uint64_t maxMemoryBytes = 0;
};

// One observer spans bootstrap and serving. The dispatch queue only records
// pressure and wakes control; all allocation/reclaim decisions stay on the
// native thread. RAII also covers failed or interrupted startup.
class MemoryPressureMonitor final {
public:
  explicit MemoryPressureMonitor(std::function<void()> notify)
      : pending_(std::make_shared<std::atomic<engine::MemoryPressure>>(
            engine::MemoryPressure::Normal)),
        queue_(dispatch_queue_create("com.splash.memory-pressure",
                                     DISPATCH_QUEUE_SERIAL)) {
    source_ = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
            DISPATCH_MEMORYPRESSURE_CRITICAL, queue_);
    if (!source_)
      throw std::runtime_error("unable to create memory-pressure monitor");
    const auto pending = pending_;
    const auto source = source_;
    dispatch_source_set_event_handler(source_, ^{
      const unsigned long event = dispatch_source_get_data(source);
      engine::MemoryPressure pressure = engine::MemoryPressure::Normal;
      if (event & DISPATCH_MEMORYPRESSURE_CRITICAL)
        pressure = engine::MemoryPressure::Critical;
      else if (event & DISPATCH_MEMORYPRESSURE_WARN)
        pressure = engine::MemoryPressure::Warning;
      pending->store(pressure, std::memory_order_release);
      notify();
    });
    dispatch_activate(source_);
    timer_ = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue_);
    if (!timer_) {
      dispatch_source_cancel(source_);
      dispatch_sync(queue_, ^{});
      throw std::runtime_error("unable to create memory-pressure timer");
    }
    // Notifications are coarse. The same safe-point control handler also
    // samples live host headroom twice a second, without dispatch-thread IO.
    dispatch_source_set_timer(
        timer_, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
        500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer_, ^{ notify(); });
    dispatch_activate(timer_);
  }
  ~MemoryPressureMonitor() {
    dispatch_source_cancel(timer_);
    dispatch_source_cancel(source_);
    dispatch_sync(queue_, ^{});
  }
  MemoryPressureMonitor(const MemoryPressureMonitor &) = delete;
  MemoryPressureMonitor &operator=(const MemoryPressureMonitor &) = delete;
  [[nodiscard]] engine::MemoryPressure pressure() const noexcept {
    // Notifications select individual processes and may arrive late. Sample
    // the current system level at the same safe points as host availability.
    return engine::querySystemMemoryPressure().value_or(
        pending_->load(std::memory_order_acquire));
  }

private:
  std::shared_ptr<std::atomic<engine::MemoryPressure>> pending_;
  dispatch_queue_t queue_;
  dispatch_source_t source_;
  dispatch_source_t timer_;
};

void printUsage(std::string_view executable) {
  std::cerr << "usage: " << executable
            << " serve-native TARGET_DIRECTORY DRAFT_DIRECTORY"
               " MAX_CONTEXT|auto MAX_MEMORY_BYTES|auto\n";
}

template <typename T>
bool parsePositive(std::string_view value, T &result) {
  const char *end = value.data() + value.size();
  auto parsed = std::from_chars(value.data(), end, result);
  return parsed.ec == std::errc{} && parsed.ptr == end && result != 0;
}

uint64_t parseMaxMemory(std::string_view value) {
  if (value == "auto")
    return 0;
  uint64_t result = 0;
  if (!parsePositive(value, result))
    throw UsageError("MAX_MEMORY_BYTES must be auto or a positive integer");
  return result;
}

uint32_t parseMaxContext(std::string_view value,
                         const model::ModelCapabilities &capabilities) {
  if (value == "auto")
    return 0;
  uint32_t result = 0;
  if (!parsePositive(value, result) ||
      result > capabilities.maximumContextTokens) {
    throw UsageError("MAX_CONTEXT must be auto or an integer in [1, " +
                     std::to_string(capabilities.maximumContextTokens) + "]");
  }
  return result;
}

std::filesystem::path canonicalDirectory(std::string_view argument,
                                         std::string_view label) {
#ifdef SPLASH_SEALED
  // R2 checked these roots as canonical before the sandbox, and R6 opened
  // them by descriptor (F_GETPATH equal); after the sandbox a path-based
  // stat of a directory is denied, so nothing is resolved here.
  (void)label;
  return std::filesystem::path(argument);
#endif
  std::error_code error;
  std::filesystem::path path =
      std::filesystem::canonical(std::filesystem::path(argument), error);
  if (error || !std::filesystem::is_directory(path, error) || error) {
    throw UsageError(std::string(label) + " must name an existing directory");
  }
#ifdef SPLASH_SEALED
  // R2/R6: the engine passes canonical absolute roots; the child refuses any
  // other form (a symlinked or firmlinked parent) and never resolves it.
  if (path.string() != std::string(argument)) {
    std::cerr << "sealed: " << label << " is not canonical\n";
    _exit(113);
  }
#endif
  return path;
}

std::filesystem::path requireModelRoot(std::string_view targetArgument,
                                       std::string_view draftArgument) {
  std::filesystem::path target =
      canonicalDirectory(targetArgument, "TARGET_DIRECTORY");
  std::filesystem::path draft =
      canonicalDirectory(draftArgument, "DRAFT_DIRECTORY");
  if (target.filename() != "target" || draft.filename() != "draft" ||
      target.parent_path() != draft.parent_path()) {
    throw UsageError(
        "TARGET_DIRECTORY and DRAFT_DIRECTORY must be the target/ and "
        "draft/ subdirectories of one model root");
  }
  return target.parent_path();
}


NativeArguments parseArguments(int argc, char **argv) {
  if (argc != 6 || std::string_view(argv[1]) != "serve-native") {
    throw UsageError("expected the serve-native command");
  }
  NativeArguments result;
  result.modelRoot = requireModelRoot(argv[2], argv[3]);
  result.model = model::inspectModelPackage(result.modelRoot);
  result.maxContext = parseMaxContext(argv[4], result.model.capabilities);
  result.maxMemoryBytes = parseMaxMemory(argv[5]);
  return result;
}

[[maybe_unused]] std::filesystem::path executablePath() {
  uint32_t size = PATH_MAX;
  std::vector<char> buffer(size);
  if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
    buffer.resize(size);
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
      throw std::runtime_error("could not resolve executable path");
    }
  }
  std::error_code error;
  std::filesystem::path path = std::filesystem::canonical(buffer.data(), error);
  if (error) {
    throw std::runtime_error("could not canonicalize executable path: " +
                             error.message());
  }
  return path;
}

uint64_t engineInstanceId() {
  uint64_t process = static_cast<uint64_t>(getpid());
  uint64_t clock = static_cast<uint64_t>(
      std::chrono::steady_clock::now().time_since_epoch().count());
  uint64_t result = (process << 32) ^ clock;
  return result ? result : 1;
}

engine::RuntimeBootstrapConfig
bootstrapConfig(const NativeArguments &arguments) {
  const model::ModelCapabilities &capabilities = arguments.model.capabilities;
  const uint32_t maskWordsPerToken =
      (capabilities.vocabularySize + 31) / 32;
  engine::RuntimeBootstrapConfig config;
#ifdef SPLASH_SEALED
  // R4: the metallib is embedded (__TEXT,__splash_metal); the path is never
  // read. A fixed non-empty value keeps the bootstrap's non-empty check.
  config.resources.metallibPath = "embedded:__TEXT,__splash_metal";
#else
  config.resources.metallibPath =
      executablePath().parent_path() / "splash.metallib";
#endif
  config.resources.modelRoot = arguments.modelRoot;
  config.resources.model = arguments.model;
  config.resources.buildId = SPLASH_BUILD_ID;
  config.resources.maximumMemoryBytes = arguments.maxMemoryBytes;
#ifdef SPLASH_SEALED
  // Chunked KV budget from the config frame; 0 selects the default.
  config.resources.kvBudgetBytes = sealed_r2_kv_budget_bytes();
#endif
  config.resources.maximumImagePatches = kMaximumImagePatches;
  config.nativeLoop.engine.maxContext = arguments.maxContext;
  config.nativeLoop.engine.maxImagePatches = kMaximumImagePatches;
  config.protocolLimits.maxImagePatches = kMaximumImagePatches;
  config.nativeLoop.engineInstanceId = engineInstanceId();
  config.nativeLoop.maskWordsPerToken = maskWordsPerToken;
  config.protocolLimits.maxTokenBatch =
      model::ExecutionLimits::maximumStepTokens;
  config.protocolLimits.maxSimulationTokens = capabilities.draftQueryRows;
  config.protocolLimits.maxMaskWords =
      maskWordsPerToken * (capabilities.draftQueryRows + 1);
  return config;
}

// SIGTERM, SIGINT and SIGHUP end the transport loop instead of killing the
// process, so the KV backing is released one extent at a time by the normal
// destructors. SIGPIPE is ignored: a closed parent pipe surfaces as EPIPE,
// which the transport already reports as an I/O failure.
std::atomic<engine::FdTransport *> gShutdownTransport{nullptr};

void requestShutdownFromSignal(int) {
  const int savedErrno = errno;
  if (engine::FdTransport *transport =
          gShutdownTransport.load(std::memory_order_acquire)) {
    transport->requestShutdown();
  }
  errno = savedErrno;
}

// Keep shutdown idempotent through process teardown. Detach the transport before
// it is destroyed; later stop signals remain harmless until process exit.
class ShutdownSignals final {
public:
  explicit ShutdownSignals(engine::FdTransport &transport) {
    gShutdownTransport.store(&transport, std::memory_order_release);
    struct sigaction action {};
    action.sa_handler = requestShutdownFromSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    for (const int number : {SIGTERM, SIGINT, SIGHUP})
      sigaction(number, &action, nullptr);
    std::signal(SIGPIPE, SIG_IGN);
  }
  ShutdownSignals(const ShutdownSignals &) = delete;
  ShutdownSignals &operator=(const ShutdownSignals &) = delete;
  ~ShutdownSignals() {
    gShutdownTransport.store(nullptr, std::memory_order_release);
  }
};



int runNative(const NativeArguments &arguments) {
  engine::FdTransport transport(STDIN_FILENO, STDOUT_FILENO);
  ShutdownSignals signals(transport);
#ifdef SPLASH_SEALED
  sealed_r7_own_signals();   // no-op outside test builds (R7-T3)
#endif
  MemoryPressureMonitor pressureMonitor(transport.controlNotifier());
  engine::RuntimeMetrics metrics;
  engine::RuntimeBootstrap *published = nullptr;
  auto statusProvider = [&]() -> std::string {
    engine::RuntimeResources &resources = published->resources();
    // Status can arrive during GPU work; allocation/command boundaries and
    // the safe-point pressure monitor already refresh the cached sample.
    metal::MetalBackend &backend = resources.backend();
    bool healthy = backend.healthy();
    return engine::runtimeStatusJson(
        resources.memoryPlan(), published->nativeLoop().snapshot(),
        backend.memoryStats(), published->report().warmup,
        published->report().memoryAudit, metrics.snapshot(),
        published->modelRuntime().telemetry(), resources.cacheIdentity(),
        resources.memoryGovernor().snapshot(), healthy,
        healthy ? std::string{} : backend.unhealthyReason(),
        published->nativeLoop().resourceWaitSnapshot());
  };

  const auto recoveryDeadline =
      std::chrono::steady_clock::now() + kStartupMemoryRecoveryTimeout;
  bool reportedRecoveryWait = false;
  std::unique_ptr<engine::RuntimeBootstrap> bootstrap;
  while (!bootstrap) {
    if (transport.shutdownRequested())
      return static_cast<int>(engine::NativeProcessExit::CleanEof);
    engine::RuntimeBootstrapConfig config = bootstrapConfig(arguments);
    config.resources.memoryPressure = [&] { return pressureMonitor.pressure(); };
    config.resources.cancelled = [&] { return transport.shutdownRequested(); };
    config.nativeLoop.metrics = &metrics;
    try {
      bootstrap = engine::RuntimeBootstrap::start(
          std::move(config), transport.outputSink(), statusProvider);
    } catch (const engine::RuntimeBootstrapError &error) {
      if (transport.shutdownRequested())
        return static_cast<int>(engine::NativeProcessExit::CleanEof);
      const auto now = std::chrono::steady_clock::now();
      const auto failure = error.report().resourceFailure;
      if ((failure != engine::RuntimeResourceFailure::HostCapacity &&
           failure != engine::RuntimeResourceFailure::DriverAllocation) ||
          now >= recoveryDeadline) {
        throw;
      }
      if (!reportedRecoveryWait) {
        std::cerr
            << "Waiting for sufficient available memory to start; "
               "the macOS reserve remains protected...\n";
        reportedRecoveryWait = true;
      }
      const auto resumeAt = std::min(
          now + std::chrono::steady_clock::duration(kStartupMemoryRecoveryPoll),
          recoveryDeadline);
      while (std::chrono::steady_clock::now() < resumeAt &&
             !transport.shutdownRequested()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
      }
    }
  }
  if (transport.shutdownRequested())
    return static_cast<int>(engine::NativeProcessExit::CleanEof);
  // Serving handles shutdown and memory pressure between engine ticks.
  // The per-operation guard is only needed during bootstrap.
  bootstrap->resources().backend().setOperationGuard({});
  published = bootstrap.get();

  transport.setControlHandler([&pressureMonitor, published,
                               memoryReporter = engine::MemoryStatusReporter{},
                               pressurePolicy =
                                   engine::MemoryPressurePolicy{}]() mutable {
    engine::MemoryPressure pressure = pressureMonitor.pressure();
    engine::RuntimeResources &resources = published->resources();
    engine::MemoryGovernor &governor = resources.memoryGovernor();
    governor.setPressure(pressure);
    const double now = std::chrono::duration<double, std::milli>(
                           std::chrono::steady_clock::now().time_since_epoch())
                           .count();
    static_cast<void>(resources.backend().refreshMemoryStats());
#ifdef SPLASH_SEALED
    // Chunked KV (review/CHUNKED-KV-2026-10-23.md): return the chunks of
    // finished requests at every command-free control pass.
    static_cast<void>(published->nativeLoop().releaseIdleKv());
    // Evicted composite states park their buffers in the state pool. With no
    // request left, keep the warm set of one lane, as after startup.
    if (published->nativeLoop().idle())
      static_cast<void>(resources.stateStorage().releaseIdle(2, 1));
#endif
    const auto memory = governor.snapshot();
    const engine::ResourceWaitSnapshot wait =
        published->nativeLoop().resourceWaitSnapshot();
    const std::string diagnostic =
        memoryReporter.update(wait, memory.growthAllowed);
    if (!diagnostic.empty())
      std::cerr << diagnostic << '\n';
    engine::MemoryReclaimDirective directive =
        pressurePolicy.update(memory, now, wait.memory || wait.suspended);
    if (!directive.reclaimEmptyKvExtents)
      return false;
    static_cast<void>(published->nativeLoop().reclaimMemory(directive));
    static_cast<void>(resources.backend().refreshMemoryStats());
    // KV backing is returned one extent at a time. Ask to run again at the
    // next command-free point while a release is still in flight, so the
    // rest of the empty backing follows without a burst of kernel work.
    return published->nativeLoop().reclaimDeferred();
  });
  const auto exit = transport.run(bootstrap->nativeLoop());
  switch (exit) {
  case engine::NativeProcessExit::CleanEof:
    break;
  case engine::NativeProcessExit::ProtocolFailure:
    std::cerr << "error: native transport stopped after a protocol failure\n";
    break;
  case engine::NativeProcessExit::EngineFailure:
    std::cerr << "error: native transport stopped after an engine failure\n";
    break;
  case engine::NativeProcessExit::IoFailure:
    std::cerr << "error: native transport stopped after an I/O failure\n";
    break;
  }
  return static_cast<int>(exit);
}

void printBootstrapError(const engine::RuntimeBootstrapReport &report) {
  std::cerr << "error: " << report.describe() << '\n';
#ifdef SPLASH_SEALED
  {
    std::string line = "bootstrap error: " + report.describe() + "\n";
    sealed_reason_write(line.data(), line.size());
  }
#endif
  if (!report.memoryPlanJson.empty()) {
    std::cerr << "memory_plan_json: " << report.memoryPlanJson << '\n';
  }
}

} // namespace
} // namespace splash

int main(int argc, char **argv, char **envp) {
  (void)envp;
#ifdef SPLASH_SEALED
  // R2: self-check, first byte, config frame; then R6: manifest and roots.
  // All before any argument parsing or model-file access.
  {
    // R1: the exception-port guard is the first thing the child does.
    sealed_old_port_t old[SEALED_MAX_OLD_PORTS];
    unsigned oldCount = 0;
#if !defined(SEALED_TEST_NO_R1)
    if (sealed_guard_install(old, &oldCount) != 0 || sealed_guard_readback() != 0)
      _exit(113);
#else
    (void)old; (void)oldCount;   // test build: crash-report control (A-20)
#endif
  }
  sealed_reason_open();   // test builds only; the descriptor check skips this one fd
  sealed_r2_self_check(argc, argv, envp);
  sealed_r7_start();   // no-op outside test builds (R7-T3 read-back)
  sealed_r2_first_byte();
  {
    const uint8_t *manifest = nullptr;
    size_t manifestLen = 0;
    const char *packageRoot = nullptr;
    sealed_r2_read_config(argv[2], argv[3], &manifest, &manifestLen, &packageRoot);
    sealed_r6_init(manifest, manifestLen, packageRoot);
  }
#if defined(SEALED_TEST_PLANT_MAPPING)
  {
    // Test build: a file mapping the self-audit must refuse, planted before the
    // sandbox (the sandbox would deny this open). It stays mapped for life.
#ifndef SEALED_TEST_PLANT_PATH
#define SEALED_TEST_PLANT_PATH "/private/etc/hosts"
#endif
    int fd = ::open(SEALED_TEST_PLANT_PATH, O_RDONLY);
    void *m = fd >= 0 ? mmap(nullptr, 4096, PROT_READ, MAP_PRIVATE, fd, 0) : MAP_FAILED;
    if (fd >= 0) ::close(fd);
    const char *msg = m == MAP_FAILED ? "test: plant mapping FAILED\n" : "test: planted mapping of " SEALED_TEST_PLANT_PATH "\n";
    sealed_reason_write(msg, std::strlen(msg));
  }
#endif
  sealed_tee_probe("presandbox");   // no-op outside test builds
#ifndef SEALED_TEST_NO_SANDBOX
  {
    // R5: sandbox and self-test, then the R4 Metal guard, before any Metal call.
    const char *const *paths = nullptr;
    size_t n = sealed_r6_abs_paths(&paths);
#if defined(SEALED_TEST_REPORT_EARLY)
    sealed_r5_report_sandboxed();   // test build: must refuse (out of order)
#endif
    sealed_r5_apply(paths, n);
    sealed_r5_self_test(paths[0]);
    sealed_r7_sandbox_start();   // no-op outside test builds (R7-T3)
  }
#endif
  sealed_r4_metal_guard();
#if !defined(SEALED_TEST_NO_SANDBOX) && !defined(SEALED_TEST_SKIP_SB_REPORT)
  // An unsandboxed test build never reports "sandboxed"; the engine refuses it.
  // The skip-report test build is sandboxed and sends "loaded" first.
  sealed_r5_report_sandboxed();
#endif
  sealed_t2_publish("sandboxed");  // no-op outside test builds (T2)
  sealed_t2f_probe("sandboxed");   // no-op outside test builds (T2 follow-up)
  sealed_s1_share("sandboxed");     // no-op outside test builds (S-1)
  sealed_tee_probe("sandboxed");   // no-op outside test builds
  sealed_r7_check("sandboxed");    // no-op outside test builds (R7-T3)
#endif
  @autoreleasepool {
    try {
      splash::NativeArguments arguments = splash::parseArguments(argc, argv);
      return splash::runNative(arguments);
    } catch (const splash::UsageError &error) {
      std::cerr << "error: " << error.what() << '\n';
#ifdef SPLASH_SEALED
      {
        std::string line = std::string("usage error: ") + error.what() + "\n";
        sealed_reason_write(line.data(), line.size());
      }
#endif
      splash::printUsage(argc > 0 ? argv[0] : "splash");
      return static_cast<int>(
          splash::engine::NativeProcessExit::ProtocolFailure);
    } catch (const splash::engine::RuntimeBootstrapError &error) {
      splash::printBootstrapError(error.report());
      return static_cast<int>(
          splash::engine::NativeProcessExit::EngineFailure);
    } catch (const std::system_error &error) {
      std::cerr << "error: native runtime I/O failed: " << error.what() << '\n';
      return static_cast<int>(splash::engine::NativeProcessExit::IoFailure);
    } catch (const std::exception &error) {
      std::cerr << "error: " << error.what() << '\n';
#ifdef SPLASH_SEALED
      {
        std::string line = std::string("engine error: ") + error.what() + "\n";
        sealed_reason_write(line.data(), line.size());
      }
#endif
      return static_cast<int>(
          splash::engine::NativeProcessExit::EngineFailure);
    }
  }
}
