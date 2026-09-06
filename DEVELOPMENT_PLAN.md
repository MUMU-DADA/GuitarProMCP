# GuitarProMCP Development Plan

Accepted scope: installable native MCP control of Guitar Pro, automatic loading
with the application, reliable live editing, and completion of the operation
coverage in `COVERAGE.md`. The scope is not reduced to currently passing tests.
Implementation mode: ponytail ultra; reuse the C++/Qt runtime and native APIs.
Commit each completed phase after its acceptance checks pass.

## Status

| Phase | Status | Required acceptance |
| --- | --- | --- |
| P0 Automatic loading | Complete | Direct EXE, real Windows shortcut, file-association command arguments, and removing the extension verified in an isolated host copy. See `native/AUTOLOAD.md`. |
| P1 Installation | In progress; final installed-host verification pending | Prebuilt package, installation/update/disable/uninstall, normal visible startup, explicit background mode, persistent local configuration, MCP connection information. |
| P2 Sessions and documents | Pending | Restart/reconnect, port conflicts, instance identity, multiple clients, asynchronous failure/cancellation, document lifecycle, save-current/overwrite/recovery, explicit save/discard/cancel on close. |
| P3 Score and tracks | Pending | Missing notation/effects, keyboard/percussion notes, cross-track operations, instrument/tuning/capo/transposition, complex repeats/endings/jumps, verified read/write/undo/persistence/playback. |
| P4 Selection and clipboard | Pending | Partial track sets, complex voice ranges, batch commands, special/repeated paste, complex cut/replace, tuning/transposition/percussion compatibility, isolated system-clipboard verification. |
| P5 Playback and audio | Pending | Tempo points/ramps, loop ranges, mixing/effects/sounds/devices, repeat/jump timeline, accurate seeking and multi-document isolation. |
| P6 Exchange and workspace | Pending | MIDI/MusicXML/other GP import/export, PDF/image/audio output, printing/layout/staff display, document versus global preferences, actual output verification. |
| P7 Release | Pending | Supported-build matrix, diagnostics/recovery/upgrades, complex scores, long runs, multiple clients/documents, modal states, install/update/uninstall, complete applicable regression on the release binary. |

P0 -> P1 -> P2 precede feature expansion P3-P6. Reliability checks run during
every phase; P7 is the final release gate, not the first stability check.

## Product Requirements

- Normal application startup should load the installed plugin without a manual
  PowerShell command. Test direct `GuitarPro.exe`, Windows shortcuts and opening
  an associated score independently. Shortcut replacement alone does not prove
  direct executable loading.
- Normal launches retain the visible application and normal focus behavior.
  Explicit background launches preserve the existing hidden-mode guarantees.
- Installation provides compiled binaries; users do not need the compiler or
  Qt development kit. Keep runtime credentials/configuration out of the source
  checkout and out of logs. Installation and uninstall are reversible.
- The host process contains the native MCP server. No external language runtime,
  input simulation, or foreground window is required for native score work.
- The initial supported host is Windows x64 Guitar Pro 8.1.1.17. Each additional
  host build requires independent ABI validation and regression evidence.
- A running ordinary instance that predates installation must restart to load
  the plugin. Hot attachment remains separate research, outside the first
  release prerequisite.
- Manual editing and MCP share the actual host document. Multiple clients and
  instances must not silently redirect commands to the wrong score/process.

## Phase Details

### P0: Establish automatic loading

Inspect the host's existing plugin discovery and test an application-local
extension in an isolated installation copy before touching the installed host.
Do not replace host executables or Qt DLLs. Record the mechanism, actual loading
point, startup variants, compatibility checks and uninstall behavior. A loading
candidate is not accepted based only on metadata discovery or file placement.

### P1: Package and integrate

Separate developer compilation from end-user installation. Provide bounded
installation detection, staged updates, persistent configuration, status and
disable controls, credential handling and uninstall recovery. Detect running
hosts before replacing loaded binaries. Check compatibility before invoking
private ABI functions. Verify the application remains usable if configuration
or the local MCP endpoint is unavailable.

### P2: Make everyday work reliable

Provide instance discovery, reconnect, stable identity, collision handling and
serialized mutations. Complete operation status for open/new/close/save,
including failure, cancellation and timeout. Cover tab reordering, stale IDs,
manual edits, save-current, explicit overwrite, failed-save recovery and
save/discard/cancel on close. Never silently discard user changes.

### P3: Complete musical editing

Use the operation inventory in `COVERAGE.md` to track grace notes, bends, slides,
remaining effects, long connection chains, advanced tuplets, keyboard and
percussion notes, track instrument/configuration, tuning/capo/transposition,
cross-track notes, complex repeats, alternate endings and navigation marks.
Every supported operation needs structured state and a native edit path.

### P4: Complete ranges and transfer

Handle selected track subsets, complex voice/staff ranges and remaining batch
commands. Add special/repeated paste and complex cut/replacement. Verify content
mapping for different tunings, transposing instruments and percussion. Keep
native system-clipboard operations experimental until isolated tests pass;
tests must not replace the user's existing clipboard.

### P5: Complete playback

Edit tempo events and ramps, loop ranges, mixers/effect chains, sound selection
and devices. Validate actual timing and audio where applicable, including
repeat/jump expansion, seek positions, cancellation and document isolation.

### P6: Complete file and workspace workflows

Add native imports/exports and parameterized layout/printing/settings operations.
Verify exported musical structure independently, render PDF/image output and
inspect it, and validate audio duration/content. Settings must read back and
declare whether their scope is the current document or the whole application.

### P7: Qualify the release

Exercise the supported version matrix, restart/update/uninstall, modal dialogs,
port failures, concurrent clients, large and complex scores, repeated document
destruction and long-running sessions. Publish diagnostic instructions and
version-bound evidence with the compiled package.

## Definition of Done

For each real user operation record implemented, verified, experimental,
unimplemented, or host-limited status. Distinguish blockers from completed work.
Exports/menu enumeration/JSON success do not prove a functioning native edit.

For mutations check actual state, target isolation, undo/redo where supported,
and save/reopen persistence. Test playback for changes that affect sound. For
asynchronous operations verify completion rather than merely `scheduled`.
Bind regression evidence to source, plugin and host hashes. Run all applicable
checks against the final binary before claiming full release completion.

## Existing Evidence

`COVERAGE.md` records thirteen suites with 2195 historical passing checks and an
eight-suite regression of 1784 checks for the prior DLL. Those results are the
starting baseline, not proof of the phases above. The system clipboard and
other explicit gaps in that file remain open.

## Execution Log

- Baseline preserved in commit `2b97686` on `codex/full-development`.
- P0: `native/test-autoload-probe.ps1` passed direct EXE, Windows shortcut,
  score-open and uninstall variants. Evidence:
  `artifacts/autoload-probe-724964da0f7740f991172f092da7b43f/verification.json`.
- P0 completion commit: `c945e42`.
- P1: production bootstrap, visible/background startup, persistent data, status
  dialog, install/update/disable/uninstall and a standalone package implemented.
  Installation checks: 35 plus 26 protocol checks at
  `artifacts/installation-716ffefd35114ea3b57b55abe6d5f53d/verification.json`.
  The package also installed using Windows PowerShell 5.1. The actual host now
  has an installer-owned plugin; final installed-entrypoint verification and
  the updated package remain outstanding.
- P1 validation exposed empty `GPMCP_PORT` handling (fixed), request timeouts
  (added), and native autosave failures when test hosts inherit the restricted
  filesystem. Full application tests must run with permission for the host's
  own user configuration/autobackup directory. The modal dialog was observed
  as `am::gui::MessageDialog`, title "Save error" (localized), not inferred from
  a timeout. `gp_dialogs` and central modal guards now prevent native writes
  while it is active; dialog-scoped controls remain available.
- Thirteen suites passed all 2195 checks in
  `artifacts/regression-f4364a58c78f42b1ac85cff266581cf6/regression.json`, but
  clean exit failed with a Qt5Gui access violation. This is NOT a passing
  release regression. Testing cleanup on `aboutToQuit` before host/Qt teardown.
  P1 remains in progress; no P1 completion commit has been made.
- P1: corrected Qt ownership of generic-plugin return values and explicit
  ownership of the manually created bootstrap bridge. Cleanup on aboutToQuit
  releases the registry, local listener, callbacks and native score snapshot.
  Hidden main-window destruction now exits the process even though hidden mode
  disables Qt's last-visible-window exit. Eight visible/background, generic/
  automatic-loader, window/menu shutdown cases passed with zero exit codes:
  `artifacts/shutdown-aa809b7b3dfe40168058de228ec24b91/verification.json`.
- P1: the current core also removes its descriptor when client-configuration
  publication fails. Installation checks: 43 plus 26 protocol checks at
  `artifacts/installation-9d9bdc780adb4e208e9dd3e028fe8b84/verification.json`;
  ownership/configuration checks: 23 at
  `artifacts/installer-files-8a4322bc4d2146cdab657626cf78ed5e/verification.json`.
- P1: all thirteen suites, 2195 checks, completed with exit code 0 and descriptor
  removal on the current binary:
  `artifacts/regression-f1463f227d554ba0b74060538e9ff651/regression.json`.
  The source/plugin/host hashes are recorded there. The current candidate is
  `artifacts/GuitarProMCP-0.3.0-7090f898224d4949a54d798a0ff647d5.zip`.
  PowerShell 5.1 compatibility fixes use a UTF-8 BOM for the Chinese developer
  launcher and basic HTTP parsing for the packaged JSON client.
- P1: packaged installer/client and all eight visible/background shutdown paths
  passed Windows PowerShell 5.1.19041.6456 with a recorded 5000 ms startup
  settling interval:
  `artifacts/shutdown-6ba484f7661a401a95aaa47244f8cd03/verification.json`.
  The final package adds the documented rapid-exit limitation; its DLLs and
  executable scripts are identical to the package used by this check.
- Open host limitation: rapid close during startup can deadlock in the vendor's
  AMNetwork shutdown. A minimal Qt-only closing probe, without the MCP core,
  registry or native score snapshot, reproduced the same wait. The main thread
  waits for NetworkServiceGuard while its network thread waits on a semaphore
  during an error callback. Evidence and all thread stacks:
  `artifacts/exit-baseline-ee2f813e0b8343d7856fa611439c315e/`.
  This is not a passing rapid-exit test. A recorded startup settling interval
  may be used to test ordinary installed operation separately; it does not
  close the rapid-exit reliability issue. P7 must retain this limitation.
- Actual installation still contains an older P1 binary. The previous Windows
  administrator prompt was cancelled. A fresh user decision on retrying that
  update is pending; no repeated UAC launch or installed-entrypoint success is
  assumed. P1 remains in progress, and P2-P7 are not marked complete.
