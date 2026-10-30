# Native macOS app and local instances

This fork adds a macOS menu bar app and a local control plane to Kapitsa.
The app launches `kapitsa-runtime`, a native helper linked to the same C++ server
library as `kapitsa serve`. It reads structured state and events directly.
It does not run CLI commands or parse terminal output to discover engine activity.

## Build and open

Apple silicon, macOS 14+, CMake 3.24+ and Swift 6 are required.
No new third-party runtime dependency is used.

```bash
make -C app app
open build/Kapitsa.app
```

The development bundle contains the app, `kapitsa-runtime`, the CLI, `LICENSE`
and `THIRD_PARTY_NOTICES`. It is ad-hoc signed. Developer ID signing,
notarization and an app updater are still needed for public distribution.
The fork's CLI updater and installer use `edjubert/kapitsa` releases;
until this fork publishes releases, build from this checkout. Installing
upstream's Homebrew package does not install these changes.

In the app, choose a name, model (a catalog alias such as `27b`, or a folder),
API port, optional context and slot count. The native runtime resolves and loads
the model using the existing engine path. Different instances need different API
ports on the same listen address. They share the physical RAM and model store;
a memory budget is not a separate reservation of the Mac's RAM.

## The two frontends

```bash
build/kapitsa start --name code --model 27b --port 8000 --context 90k
build/kapitsa start --name chat --model 4b --port 8001
build/kapitsa instances
build/kapitsa status --instance code --json
build/kapitsa resume --instance code
build/kapitsa stop --instance chat
```

`start` launches the same native helper as the app. The helper starts a new session,
ignores the coding-agent launcher's parent-death marker, and continues after
the launcher exits. Closing the app or pressing Ctrl+C in `resume` does not stop it.
`stop` explicitly stops only the selected instance, interrupting its requests.
The engine's existing signal handler saves its cache and calibration state.

`serve` remains a foreground command: Ctrl+C stops it, as before. It also publishes
its local control endpoint by default. `--name ID` chooses its identity; otherwise
it uses `serve-PORT`. An app can observe and stop a foreground `serve`.
Servers from an unmodified upstream release do not publish this control protocol;
restart them with this fork to make them discoverable.

`resume` reattaches to the live dashboard. It does not recover an in-flight
generation after a crash or disconnect of its original inference client.
Inference HTTP clients keep their existing cancellation behavior.

The app remembers configurations it launched and can restart them. It can
observe and stop instances launched elsewhere without claiming ownership.
CLI selection accepts an ID or a unique display name. With several reachable
instances, omitting a target is an error. `instances --json` includes unreachable
records, but never includes control credentials.

## Identity and discovery

Each running instance owns a record in `$KAPITSA_HOME/instances`, defaulting to
`~/.cache/kapitsa/instances`. The directory has mode `0700`; records and locks
have mode `0600`.

| Field | Meaning |
| --- | --- |
| `instance_id` | Logical identity, retained when restarting a saved configuration |
| `run_id` | Random UUID for this execution; changes at every restart |
| `name` | Display name; distinct instances may use the same name |
| `pid` | Informational process ID; clients never use it to kill a discovered process |
| `control_url` | Random loopback HTTP port, separate from inference |
| `token` | Private per-execution bearer credential; absent from public status |
| `protocol` | Control protocol version, currently `1` |

An exclusive file lock belongs to one logical instance, not the GPU or the
whole registry. Failed duplicate starts leave the owner's record intact.
Records are written to a private temporary file and atomically renamed.
Normal shutdown removes the record; crashes can leave an unreachable record.
Clients verify both IDs and the protocol on every response, including stop.
Neither client follows control redirects. There is no central daemon in the
inference path and no new global GPU lock.

## Control protocol

Every request requires `Authorization: Bearer TOKEN` and
`X-Kapitsa-Run-ID: RUN_ID`. The endpoint is bound only to `127.0.0.1`.
It exists during preparation and model loading, before the inference server.

| Request | Response |
| --- | --- |
| `GET /v1/status` | Current snapshot: lifecycle, configuration, memory, active requests and last completed request |
| `GET /v1/events?after=N` | Snapshot plus events after cursor `N`, bounded to its returned cursor |
| `POST /v1/stop` | Acknowledgment followed by stopping this runtime |

Events have `seq`, `type` and `data`. The runtime retains the newest 256.
Types are `state`, `request_started`, `request_finished` and `log`.
Live progress is read from the engine's `LiveDecode` atomics, including phase,
prompt/cache/output counts, current rate, tokens per step and speculation mode.
Completed usage and timings come from `ChatResult`. No prompts, generated text
or inference API keys enter this dashboard protocol.

`reset: true` means the cursor is no longer in retained history. Use the returned
snapshot as the authoritative current state, then continue from its `cursor`.
A different `run_id` starts a new history. Disconnecting an observer does not
cancel inference. Both current frontends poll once per second.

The ready snapshot includes live memory allocation and the engine's effective
context, slots and precision where catalog metadata is available. Engine log
messages are exposed as structured log events; warnings and decoding metadata
that currently exist only as log messages have not yet become separate typed
engine events. Download byte progress, task-output replay, model management UI
and WidgetKit are later additions.

## Native helper configuration

The helper accepts one JSON object on stdin, or `--config FILE`.
`--check` validates it without loading a model or using Metal.

```json
{
  "protocol": 1,
  "instance_id": "code",
  "name": "Code",
  "model": "27b",
  "port": 8000,
  "context": 92160,
  "slots": 4
}
```

Optional engine fields: `mem_budget_gb`, `spec`, `dflash`, `disk_cache`,
`prefill_chunk`. Unknown fields and invalid types/ranges are rejected.
Native-managed instances use private, local inference and keep model switching
off. A terminal `serve` retains its existing network and switching options.

## Validation without a model or GPU

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j 6 --target kapitsa runtime_test
build/runtime_test
python3 tests/test_instances.py build
swift test --package-path app
```

The C++ contract tests use synthetic progress. The Python checks run two
independent engine-free processes, exercise the actual launcher and CLI, detach
and stop. The Swift integration check connects its real HTTP client to the
same native CPU fixture. These checks do not establish GPU behavior or inference
performance; a real-model run remains necessary before declaring production
readiness.
