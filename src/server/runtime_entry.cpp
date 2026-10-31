// Native helper for the macOS app and managed instances. Configuration enters
// as JSON; stdout/stderr are diagnostics, never the observation protocol.
#include "server/service.h"
#include "server/runtime.h"
#include "hub/hub.h"
#include <fstream>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

namespace {
void emit(const ni::ojson& message) {
  std::cout << message.dump() << '\n' << std::flush;
}

int model_request(const ni::ojson& request) {
  if (!request.is_object() || !request.contains("protocol") ||
      request.at("protocol") != 1 || !request.at("protocol").is_number_integer())
    throw std::invalid_argument("unsupported model request protocol");
  const std::string action = request.at("action").get<std::string>();
  for (auto it = request.begin(); it != request.end(); ++it)
    if (it.key() != "protocol" && it.key() != "action" && it.key() != "model" &&
        !(action == "capacity" && (it.key() == "configuration" || it.key() == "budget_bytes")))
      throw std::invalid_argument("unknown model request field: " + it.key());
  if (action == "capacity") {
    // The frontend reads Metal's recommended working set without creating an
    // engine/command queue. Explicit launch options use the same validator as
    // serving; the fit itself comes from the engine's header-only startup gate.
    const auto& value = request.at("budget_bytes");
    if (!value.is_number_unsigned() || value.get<uint64_t>() == 0 || value.get<uint64_t>() > 4096ULL * 1000000000)
      throw std::invalid_argument("budget_bytes must be a positive whole number, at most 4096 GB");
    const size_t budget = value.get<uint64_t>();
    auto options = ni::server::native_options(request.at("configuration"));
    auto opt = options.engine;
    opt.context = options.context_req;
    ni::ojson capacity{{"budget_bytes", budget}, {"status", "unknown"}};
    try {
      auto ref = ni::hub::resolve(options.model);
      if (ref.kind == ni::hub::ModelRef::kCatalog && !ref.variant_given) {
        opt.context = options.context_req > 0 ? options.context_req : ni::kMinDefaultContext;
        ref = ni::pick_variant(*ref.model, opt, budget);
      }
      const std::string dir = ni::hub::plan_dir(ref);
      if (!dir.empty()) {
        opt.context = ni::context_within_limit(dir, options.context_req);
        const auto plan = ni::start_plan(dir, opt, budget);
        const auto need = ni::start_need(dir, plan.load, plan.prefill_chunk, plan.context, plan.slots, budget);
        if (!need.weights) throw std::runtime_error("model weight headers are missing");
        const auto memory = ni::model_plan(dir, plan.prefill_chunk);
        capacity["status"] = "known";
        capacity["startup_bytes"] = need.bytes;
        // One full conversation, beside the other slots' state. KV grows on
        // demand; starting successfully does not promise every slot at capacity.
        capacity["conversation_bytes"] = need.bytes +
          memory.kv_per_pos * size_t(std::max(0, plan.context - 8192));
        capacity["context"] = plan.context;
        capacity["slots"] = plan.slots;
      }
    } catch (const std::exception& e) {
      capacity["message"] = e.what();  // offline/missing/unsupported headers are not a positive fit
    }
    emit({{"protocol", 1}, {"type", "capacity"}, {"capacity", capacity}});
    return 0;
  }
  if (action == "list") {
    ni::ojson models = ni::ojson::array(), installed = ni::ojson::array();
    for (const auto& m : ni::hub::catalog()) {
      ni::ojson variants = ni::ojson::array();
      for (const auto& v : m.variants)
        variants.push_back({{"id", m.name + ":" + v.name}, {"name", v.name},
          {"quant", v.quant}, {"repo", v.repo}, {"download_gb", v.download_gb},
          {"dir", ni::hub::models_dir() + "/" + m.name + "-" + v.name}});
      models.push_back({{"id", m.name}, {"title", m.title}, {"about", m.about},
        {"aliases", m.aliases}, {"default_variant", m.default_variant}, {"variants", variants}});
    }
    for (const auto& m : ni::hub::installed())
      installed.push_back({{"id", m.dir}, {"name", m.name}, {"variant", m.variant},
        {"dir", m.dir}, {"repo", m.repo}, {"complete", m.complete},
        {"managed", std::filesystem::is_directory(m.dir + "/.kapitsa")},
        {"bytes", m.bytes}, {"total", m.total}, {"includes", m.extras}});
    emit({{"protocol", 1}, {"type", "library"}, {"models_dir", ni::hub::models_dir()},
          {"catalog", models}, {"installed", installed}});
    return 0;
  }
  if (action != "download") throw std::invalid_argument("unknown model request action");
  const std::string model = request.at("model").get<std::string>();
  if (model.empty() || model.size() > 4096) throw std::invalid_argument("model is required");
  const auto ref = ni::hub::resolve(model);
  if (ref.kind == ni::hub::ModelRef::kLocal)
    throw std::invalid_argument("download requires a catalog model or Hugging Face repository");
  emit({{"protocol", 1}, {"type", "preparing"}, {"model", ref.name}});
  ni::hub::PullOptions options;
  options.progress = false;
  options.on_progress = [&](uint64_t done, uint64_t total) {
    emit({{"protocol", 1}, {"type", "progress"}, {"done", done}, {"total", total}});
  };
  const auto dir = ni::hub::ensure(ref, options);
  // ensure() may use an older finished revision while offline. Do not label
  // that fallback as a successfully updated pinned catalog variant.
  if (!ni::hub::is_current(ref))
    throw ni::hub::Error("The saved copy is available, but the requested revision could not be downloaded.");
  emit({{"protocol", 1}, {"type", "complete"}, {"dir", dir}});
  return 0;
}
}  // namespace

int main(int argc, char** argv) {
  bool models = false;
  try {
    bool check = false;
    std::ifstream file;
    std::istream* input = &std::cin;
    for (int i = 1; i < argc; ++i) {
      const std::string a = argv[i];
      if (a == "--check") check = true;
      else if (a == "--model-request") models = true;
      else if (a == "--config" && i + 1 < argc) {
        file.open(argv[++i]);
        if (!file) throw std::invalid_argument("cannot open configuration");
        input = &file;
      } else if (a == "--help") {
        std::cout << "kapitsa-runtime [--config FILE] [--check]\n"
                     "Reads one protocol-v1 JSON configuration from FILE or stdin.\n"
                     "--check validates configuration without loading a model or using Metal.\n"
                     "--model-request reads a protocol-v1 list/download/capacity request and emits JSON lines; no inference.\n";
        return 0;
      } else throw std::invalid_argument("unknown runtime option");
    }
    std::string bytes;
    char ch;
    while (input->get(ch)) {
      if (bytes.size() >= 16384) throw std::invalid_argument("configuration exceeds 16 KiB");
      bytes += ch;
    }
    const auto request = ni::ojson::parse(bytes);
    if (models) {
      if (check) throw std::invalid_argument("--check cannot be combined with --model-request");
      return model_request(request);
    }
    auto options = ni::server::native_options(request);
    if (check) {
      std::cout << "{\"protocol\":1,\"status\":\"valid\"}\n";
      return 0;
    }
    // A managed runtime outlives the app/CLI which launched it. It must not
    // inherit a coding-agent launcher's parent-death policy or its terminal.
    unsetenv("KAPITSA_PARENT_PID");
    setsid();
    return ni::server::run_service(std::move(options));
  } catch (const std::exception& e) {
    if (models) emit({{"protocol", 1}, {"type", "error"}, {"message", e.what()}});
    std::cerr << "kapitsa-runtime: " << e.what() << "\n";
    return 2;
  }
}
