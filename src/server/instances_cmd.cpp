#include "server/cli.h"
#include "server/runtime.h"
#include "server/service.h"
#include "hub/hub.h"
#include "util/fd.h"
#include <chrono>
#include <csignal>
#include <filesystem>
#include <fstream>
#include <thread>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <mach-o/dyld.h>

extern char** environ;
namespace ni {
namespace {
using runtime::json;
volatile sig_atomic_t detached = 0;
void detach(int) { detached = 1; }

json public_record(const json& record) {
  return {{"protocol", runtime::kProtocol}, {"instance_id", record.at("instance_id")},
    {"run_id", record.at("run_id")}, {"name", record.at("name")}, {"state", "unreachable"}};
}

void print_status(const json& j) {
  printf("%s  %s  %s  %s\n", j.value("instance_id", "").c_str(), j.value("state", "").c_str(),
    j.value("model", "").c_str(), j.value("api_url", "").c_str());
  for (const auto& r : j.value("requests", json::array()))
    printf("  request %s  %s  %s  %d tokens  %.1f tok/s\n", r.value("request_id", "").c_str(),
      r.value("client", "").c_str(), r.value("phase", "").c_str(), r.value("completion_tokens", 0),
      r.value("tokens_per_second", 0.0));
  fflush(stdout);
}

int start_instance(int argc, char** argv, int first) {
  json config{{"protocol", runtime::kProtocol}};
  for (int i = first; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--help" || a == "-h") {
      puts("kapitsa start --name ID --model MODEL [--port N] [--context N] [--slots N]\n"
           "              [--mem-budget GB] [--spec N] [--dflash DIR] [--disk-cache SIZE]\n"
           "kapitsa start --config FILE\n\n"
           "Starts a private, local runtime that outlives this command.\n"
           "Use kapitsa resume --instance ID to observe it; Ctrl+C detaches.\n"
           "Use kapitsa stop --instance ID to stop it.");
      return 0;
    }
    if (i + 1 >= argc) usage_error(a + " needs a value", "kapitsa start --help");
    const std::string v = argv[++i];
    if (a == "--config") {
      if (first != i - 1 || i + 1 != argc) throw std::invalid_argument("--config must be used on its own");
      std::ifstream input(expand_home(v));
      if (!input) throw std::invalid_argument("cannot read runtime configuration");
      config = json::parse(input);
    } else if (a == "--name") config["instance_id"] = config["name"] = v;
    else if (a == "--model") config["model"] = expand_home(v);
    else if (a == "--port") config["port"] = to_int(a, v, "kapitsa start --help");
    else if (a == "--slots") config["slots"] = to_int(a, v, "kapitsa start --help");
    else if (a == "--spec") config["spec"] = to_int(a, v, "kapitsa start --help");
    else if (a == "--prefill-chunk") config["prefill_chunk"] = to_int(a, v, "kapitsa start --help");
    else if (a == "--context" || a == "--ctx") {
      std::string why;
      const int context = parse_context(v, &why);
      if (context <= 0) throw std::invalid_argument(why.empty() ? "start requires a numeric context, such as 90k" : why);
      config["context"] = context;
    } else if (a == "--mem-budget") config["mem_budget_gb"] = json::parse(v);
    else if (a == "--dflash") config["dflash"] = v;
    else if (a == "--disk-cache") config["disk_cache"] = v;
    else throw std::invalid_argument("unknown start option " + a);
  }
  const auto options = server::native_options(config);
  config["instance_id"] = options.instance_id;
  config["name"] = options.name;
  uint32_t capacity = 4096;
  std::vector<char> executable(capacity);
  if (_NSGetExecutablePath(executable.data(), &capacity)) {
    executable.resize(capacity);
    if (_NSGetExecutablePath(executable.data(), &capacity)) throw std::runtime_error("cannot locate runtime helper");
  }
  const std::string helper = (std::filesystem::path(executable.data()).parent_path() / "kapitsa-runtime").string();
  if (access(helper.c_str(), X_OK)) throw std::runtime_error("kapitsa-runtime must be installed beside kapitsa");
  const std::string log_dir = hub::home_dir() + "/logs";
  std::filesystem::create_directories(log_dir);
  const std::string log_path = log_dir + "/instance-" + options.instance_id + ".log";
  Fd log(open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0600));
  if (log.get() < 0) throw std::runtime_error("cannot open runtime log");
  int pipe_fd[2];
  if (pipe(pipe_fd)) throw std::runtime_error("cannot create runtime configuration pipe");
  Fd input(pipe_fd[0]), output(pipe_fd[1]);
  fcntl(input.get(), F_SETFD, FD_CLOEXEC);
  fcntl(output.get(), F_SETFD, FD_CLOEXEC);
  fcntl(output.get(), F_SETNOSIGPIPE, 1);
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, input.get(), STDIN_FILENO);
  posix_spawn_file_actions_adddup2(&actions, log.get(), STDOUT_FILENO);
  posix_spawn_file_actions_adddup2(&actions, log.get(), STDERR_FILENO);
  char* args[] = {const_cast<char*>(helper.c_str()), nullptr};
  pid_t child = 0;
  const int spawned = posix_spawn(&child, helper.c_str(), &actions, nullptr, args, environ);
  posix_spawn_file_actions_destroy(&actions);
  if (spawned) throw std::runtime_error("cannot start runtime helper");
  input = Fd();
  const std::string bytes = config.dump();
  size_t written = 0;
  while (written < bytes.size()) {
    const ssize_t n = write(output.get(), bytes.data() + written, bytes.size() - written);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    written += size_t(n);
  }
  output = Fd();
  if (written != bytes.size()) throw std::runtime_error("runtime did not accept its configuration; see " + log_path);
  const std::string directory = hub::home_dir() + "/instances";
  for (int n = 0; n < 50; ++n) {
    for (const auto& record : runtime::discover(directory)) {
      if (record.value("instance_id", "") != options.instance_id || record.value("pid", 0) != child) continue;
      try {
        const json status = runtime::call(record, "GET", "/v1/status");
        print_status(status);
        printf("Started independently. Log: %s\n", log_path.c_str());
        return 0;
      } catch (const std::exception&) {}
    }
    int status = 0;
    if (waitpid(child, &status, WNOHANG) == child)
      throw std::runtime_error("runtime exited during startup; see " + log_path);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
  throw std::runtime_error("runtime control is not available yet; see " + log_path);
}
}  // namespace

int run_instances(const std::string& command, int argc, char** argv, int first) {
  try {
    if (command == "start") return start_instance(argc, argv, first);
    std::string target;
    bool as_json = false, once = false;
    for (int i = first; i < argc; ++i) {
      const std::string a = argv[i];
      if (a == "--help" || a == "-h") {
        puts("kapitsa instances [--json]\n"
             "kapitsa status --instance ID [--json]\n"
             "kapitsa resume --instance ID [--json] [--once]\n"
             "kapitsa stop --instance ID [--json]\n\n"
             "resume attaches to a live instance's dashboard. Ctrl+C only detaches.\n"
             "stop explicitly ends that instance, including any running requests.\n"
             "With several live instances, select one by ID or an unambiguous name.");
        return 0;
      }
      if (a == "--json") as_json = true;
      else if (a == "--once" && command == "resume") once = true;
      else if (a == "--instance" && i + 1 < argc) target = argv[++i];
      else throw std::invalid_argument("unknown instance option " + a);
    }
    std::vector<std::pair<json, json>> live;
    json statuses = json::array();
    for (const auto& record : runtime::discover(hub::home_dir() + "/instances")) {
      json status = public_record(record);
      try {
        status = runtime::call(record, "GET", "/v1/status");
        live.emplace_back(record, status);
      } catch (const std::exception&) {}
      statuses.push_back(status);
    }
    if (command == "instances") {
      if (as_json) puts(statuses.dump().c_str());
      else for (const auto& status : statuses) print_status(status);
      return 0;
    }
    std::vector<json> matches;
    for (const auto& [record, status] : live)
      if (target.empty() || record.value("instance_id", "") == target || record.value("name", "") == target)
        matches.push_back(record);
    if (matches.empty()) throw std::runtime_error("no reachable instance" + (target.empty() ? "" : " named '" + target + "'"));
    if (matches.size() != 1) throw std::invalid_argument("ambiguous instance; pass --instance ID (kapitsa instances lists IDs)");
    const json record = matches.front();
    if (command != "resume") {
      const json reply = runtime::call(record, command == "stop" ? "POST" : "GET",
                                      command == "stop" ? "/v1/stop" : "/v1/status");
      if (as_json) puts(reply.dump().c_str());
      else print_status(reply);
      return 0;
    }
    struct sigaction previous {}, handler {};
    handler.sa_handler = detach;
    sigemptyset(&handler.sa_mask);
    detached = 0;
    sigaction(SIGINT, &handler, &previous);
    struct Restore {
      struct sigaction previous;
      ~Restore() { sigaction(SIGINT, &previous, nullptr); }
    } restore{previous};
    uint64_t cursor = 0;
    do {
      const json reply = runtime::call(record, "GET", "/v1/events?after=" + std::to_string(cursor));
      cursor = reply.at("cursor").get<uint64_t>();
      if (as_json) puts(reply.dump().c_str());
      else print_status(reply);
      fflush(stdout);
      if (once) break;
      for (int n = 0; n < 10 && !detached; ++n) std::this_thread::sleep_for(std::chrono::milliseconds(100));
    } while (!detached);
    return 0;
  } catch (const std::invalid_argument& e) { return fail(e.what(), 2); }
    catch (const json::exception& e) { return fail(e.what(), 2); }
    catch (const std::exception& e) { return fail(e.what()); }
}
}  // namespace ni
