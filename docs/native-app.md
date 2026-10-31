# Native macOS app and local instances

This fork adds a native macOS desktop app, a menu bar panel and a local control plane to Kapitsa.
The app launches `kapitsa-runtime`, a native helper linked to the same C++ server
library as `kapitsa serve`. It reads structured state and events directly.
It does not run CLI commands or parse terminal output to discover engine activity.

## Build and open

Apple silicon, macOS 14+, CMake 3.24+ and Xcode 16+ (including Swift 6) are required.
No new third-party runtime dependency is used.

```bash
make -C app app
open build/Kapitsa.app
```

The development bundle contains the app, the WidgetKit extension, `kapitsa-runtime`,
the CLI, `LICENSE` and `THIRD_PARTY_NOTICES`. The build selects an installed
Apple Development identity when available; otherwise it uses ad-hoc signing.
Developer ID signing,
notarization and an app updater are still needed for public distribution.
The fork's CLI updater and installer use `edjubert/kapitsa` releases;
until this fork publishes releases, build from this checkout. Installing
upstream's Homebrew package does not install these changes.

The app, menu bar, widgets and web chat use the official
[Kapitsa press kit](assets/brand/README.md). Light and dark appearances select
their matching mark/wordmark; the green accent accompanies the native controls.
The macOS icon packages the existing square artwork with the platform's padded,
rounded silhouette. App and widget bundles include the same source PNGs, while
the self-contained web chat embeds the SVG masters at build time without
additional requests. Status and destructive-action colors retain their meaning.

## Desktop and Notification Center widget

Open Kapitsa once, then use macOS **Edit Widgets**, search for **Kapitsa**, and
add the small, medium or large widget. Right-click the widget, choose
**Edit Widget**, and select its instance. Several widgets can target different
instances, including instances with identical display names: selection uses
the stable logical ID, which is also shown in the picker.

For WidgetKit/AppIntents use, install the signed app at a stable standard
location rather than running it from a build directory:

```bash
make -C app install
open /Applications/Kapitsa.app
```

Quit and reopen the desktop app after installing an update; its existing
runtime instances keep running.
The installer uses `/Applications` when writable, otherwise `~/Applications`.
`INSTALL_DIR` overrides that location.

| State | Color |
| --- | --- |
| Ready, idle | Green |
| Processing requests | Blue |
| Preparing, loading, stopping | Orange |
| Stopped | Gray |
| Unreachable, missing target | Red |

The large widget adds memory use/budget and a gauge, context, conversation
slots, precision, API address, active requests, generated tokens and decoding
rate. The medium widget shows requests, rate and memory. Small widgets keep
the model, lifecycle and start/stop command. Text and symbols complement color.
The widget background opens the corresponding instance in the desktop app.

**Start**, **Stop** and **Refresh** open the containing app and execute native
AppIntents there. No CLI command is invoked. Starting uses the saved profile;
stopping interrupts this instance's requests. Stop captures the displayed
`run_id`: a stale widget cannot stop a replacement execution. When stopping a
managed CLI instance, Kapitsa saves its complete original launch configuration
so the widget can start it again. Foreground `serve` instances can be stopped,
but need an app profile before they can be started from the widget.
An unreachable instance cannot be started over an existing registry owner.
A crashed or stopped execution whose file lock is free is removed on the app's
next refresh, making its saved profile available to **Start** again.
A removed target never falls back to another instance.

The app and sandboxed extension share a private App Group. Display snapshots
contain no prompts, generated answers, API keys or control credentials.
Connections are stored separately in a `0600` file within a `0700` directory;
only the signed app and extension receive the group entitlement. The extension
reads the selected runtime directly, even when the app has quit. Newly launched
CLI instances and replacement executions are discovered when the app next
refreshes; the widget shows an old unreachable connection until then.

WidgetKit controls refresh frequency. The provider requests another update
after 60 seconds; macOS may defer it. Lifecycle changes request a reload, and
the widget displays the age of its last check. It is not a live per-second
monitor. macOS may render inactive desktop widgets monochromatically according
to the user's widget appearance settings.

The build uses Xcode's native app/extension targets to extract AppIntents
metadata, embeds the extension, signs both bundles with the same identity and
App Group, and replaces the output bundle atomically without overwriting an
executing runtime. The generated Xcode project stays under `build/native-app`.
Local builds increment a shared app/extension build number there, so macOS can
invalidate cached widget versions after an update. `BUILD_NUMBER` can override
it for a release pipeline.
Signing can be selected explicitly:

```bash
SIGN_IDENTITY="Apple Development: Your Name (ID)" TEAM_ID=YOURTEAMID make -C app app
```

The macOS group defaults to `TEAM_ID.io.github.edjubert.kapitsa`; `APP_GROUP`
can override it for a distribution build. `SIGN_IDENTITY=-` builds an ad-hoc
bundle for desktop development, but WidgetKit activation requires a valid
Apple signing identity and matching group access.

## Desktop workspace

Kapitsa opens a regular window and appears in the Dock. Its SwiftUI sidebar
contains **Instances**, **Chat**, **Downloaded models**, **Catalog** and **Settings**.
Native Liquid Glass cards are used on macOS 26; earlier versions use system
materials. The menu bar remains available after closing the main window.
Choose **Open app** there, or press Command+0, to reopen it.

- Instances show live engine state, memory, requests and recent events.
  **Edit** in a detail or the menu opens the saved launch configuration:
  name, model, API port, context, slots and engine options. Saving an active
  instance defers changes until its next launch; **Save and restart** asks
  for confirmation before interrupting requests and reloading the model.
  The logical identity and native chat history are retained. Pending changes
  are shown separately from the live engine settings. Managed CLI instances
  (`kapitsa start`) expose their original requested configuration, including
  automatic values. Foreground `serve` instances can seed an app profile from
  their known settings, with a notice that other CLI options are not imported;
  stop those instances before launching the saved profile from the app.
- **Delete** is available in an instance's detail, context menu and menu bar
  panel. Confirmation stops only the captured execution before removing its
  saved profile. Downloaded models, chat history and diagnostic logs are kept.
  A replacement execution, failed stop or shutdown timeout keeps the profile;
  an unreachable runtime that still owns its lock cannot be deleted or started
  over. A widget targeting a deleted instance displays a missing target.
- Starting shows progress until the native helper publishes its control
  connection. Immediate failures surface a bounded diagnostic from that launch
  and retain the profile for editing or retrying. The instance's detail includes
  a link to its log. Stopping a managed CLI instance also saves its original
  configuration so it can subsequently be started from the app.
- The library shows all variants in Kapitsa's model store, their file sizes,
  completion and current use. Local folders without a download manifest are
  distinguished from incomplete downloads. Models can be revealed in Finder,
  selected as the default, launched or moved to the Trash after confirmation.
  Active models and models locked by a downloader are protected. Unreachable
  instance records must be checked before removing a model. Emptying the
  Finder Trash is what reclaims space; APFS clones may still share data.
- The catalog comes directly from the C++ hub. Select a precision variant
  and download it without loading the engine. Progress is structured JSON,
  never terminal output. Interrupting preserves partial files; retrying
  uses Kapitsa's existing resumable, checksum-verified downloader. Quitting
  the app interrupts its own download while leaving inference instances alive.
- Settings persist defaults for model, API port, context, slots, memory
  budget, speculative depth, drafter, disk cache and prefill chunk. These
  prefill the next launch, whose options remain editable; existing instances
  keep their configuration.

The catalog, downloaded-model details and launch form show an orange memory
banner when the engine's header plan exceeds this Mac's budget. The estimate
uses the selected precision, context, slots, drafter and prefill options; it
does not equate download size with RAM. A separate warning covers a full
conversation that would exceed the budget, or additional instances whose
startup estimate plus existing Kapitsa allocations exceeds the shared budget.
The shared budget uses Metal's recommended working set with the engine's
margin; per-instance overrides do not increase the physical RAM. The current
allocations are a changing estimate, not a reservation, and other apps are
not accounted for. Unavailable headers show an unknown estimate, never a
positive fit. Warnings leave downloading and launching available.

The menu's stop confirmation stays inside the panel rather than opening a
modal alert that can dismiss a menu bar window when focus changes. It captures
the selected execution, so a refresh or a restart cannot retarget the stop.

## Native chat

**Open chat** in an instance's detail or menu opens the desktop's native SwiftUI
conversation. Its instance picker includes both app- and CLI-started instances.
It uses the instance's inference HTTP API directly, without invoking the CLI or
embedding the web page. Independent instances can stream replies simultaneously.

- Streaming responses, a Thinking toggle, collapsible reasoning and cancellation.
  **Stop** closes only this chat's request; it leaves the runtime and other
  requests running. Changing the selected instance preserves its conversation
  and any active reply. Quitting the app cancels its own chat requests.
- Image attachments through a file panel, paste or drag and drop, with removable
  previews. The limit is 16 images per message, 20 MB and 40 megapixels per image.
- Native Markdown paragraphs, headings, emphasis, HTTP links, quotes, lists,
  tables and fenced code with a copy button. Generated HTML is not executed.
  The transcript follows new text near its bottom and lets readers scroll back.
- Enter sends; Shift+Enter inserts a newline. Input-method composition does not
  accidentally send a message. The composer accepts plain text.
- Tokens, decoding rate, first-token time, reasoning duration, prompt-reading
  rate, cached tokens, interruption and token-limit status use the same streamed
  fields as the web chat. The server's timing setting controls displayed timings.
- Model selection lists downloaded and catalog models. Switching is available
  only when the server allows it; catalog selection can download weights.
  App-managed runtimes keep switching disabled, so choose another instance or
  launch one with the desired model. A server started with `serve --allow-switch`
  permits changing its model.
- Protected inference APIs prompt for their own API key, stored in the macOS
  Keychain. The runtime's private control token is never sent to inference routes.
  Chat requests reject redirects and use only validated loopback HTTP endpoints.

One conversation and its Thinking preference are stored per logical
`instance_id`, in `$KAPITSA_HOME/chats/INSTANCE.json`. This directory has mode
`0700`; atomic history files have mode `0600`. Text, reasoning and images stay
on disk across app and runtime restarts. **New conversation** clears only the
selected instance's history. An unreadable history is preserved until the user
explicitly starts a new conversation. The web page's separate browser history
is not imported.

The app sends the web chat's `/v1/chat/completions` schema, including image data
URLs, `stream_options.include_usage`, `chat_template_kwargs.enable_thinking` and
the active model's context fit as `max_tokens`. Only user input and assistant
answers are replayed; reasoning, local errors and timing metadata are excluded.
`GET /v1/models` adds root-level `allow_switch` and `timing` fields while retaining
the existing model list. Interrupted or failed replies keep any text already
received; failures before output restore the user's input for retry.

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
Destruction of the runtime removes its record, but termination by a signal or
a crash can leave an unreachable record. The app reconciles these records by
taking the instance's exclusive nonblocking lock and checking the captured
execution again before removing the record. It retains the lock file, and
never treats an unreachable endpoint or absent/reused PID alone as proof of
shutdown. The final deletion of a saved profile uses the same lock to exclude
a concurrent native start.
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
engine events. Task-output replay and custom repository management are later
additions.

## Native model-management contract

`kapitsa-runtime --model-request` reads a JSON object with `protocol: 1` and
`action: "list"`, `action: "download"` or `action: "capacity"`. Downloads also require `model`.
It invokes the C++ hub directly and never runs inference.

It emits newline-delimited JSON objects: `library` (catalog and installed
models), or `preparing`, `progress`, `complete` and `error`. Every message
includes `protocol: 1`. Progress includes `done` and `total` bytes for the
ranges fetched during this run, excluding files already present or resumed.
Preparation, checksum verification and GGUF import can continue outside the
byte-transfer phase. Errors have a message and a nonzero process exit code.
Diagnostics go to stderr; the app saves them in `logs/model-manager.log`.

Capacity requests carry `configuration` (the same validated launch object)
and positive integer `budget_bytes`. The app reads Metal's recommended
working set without running GPU commands. The helper uses `hub::plan_dir`,
`start_plan` and `start_need`, reading cached/local headers or fetching
catalog metadata and weight headers without downloading weight data.
It emits `type: "capacity"` with a `capacity` object: `status` (`known` or
`unknown`), `budget_bytes`, and, when known, `startup_bytes`,
`conversation_bytes` (one conversation at the full context), `context`
and `slots`. Aliases without a variant use the engine's automatic variant
selection. This is a pre-load estimate, not a measured peak or a guarantee
that all slots can fill their context simultaneously. Selection changes
cancel the previous request; editing launch options is debounced.

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
python3 tests/test_native_models.py build
swift test --package-path app
```

The C++ contract tests use synthetic progress. The Python checks run two
independent engine-free processes, exercise the actual launcher and CLI, detach
and stop. The Swift integration check connects its real HTTP client to the
same native CPU fixture. These checks do not establish GPU behavior or inference
performance; a real-model run remains necessary before declaring production
readiness.
The model API checks use a local HTTP fixture and tiny synthetic files to
exercise the real downloader, byte progress, interruption, resumption, checksum
verification and offline reuse without downloading real model weights.
Header-only synthetic packs also exercise memory planning for oversized and
small models, context/slot options, metadata-only fetching, offline reuse and
unknown estimates. Swift tests cover warning thresholds and shared budgets.
The native chat's Swift tests start `tests/fixtures/native_chat_server.py`:
three loopback servers with synthetic UTF-8 SSE, reasoning, Markdown, images,
usage and auth. They exercise the real URLSession client, independent histories,
cancellation/disconnection, runtime replacement, model selection, API-key retry,
HTTP/stream errors and truncated responses without loading an engine.
The same fixture can populate an isolated `$KAPITSA_HOME` for native UI checks.
Widget tests use two CPU fixtures to verify direct status reads without an app,
private sharing without credentials in display data, start/stop AppIntents,
CLI configuration preservation, duplicate/removed targets and stale execution
protection. The control server closes idle observer connections so app, widget
and CLI clients cannot reserve all of its HTTP workers.
