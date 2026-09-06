# GuitarProMCP Development Plan

Accepted scope: installable native MCP control of Guitar Pro, automatic loading
with the application, reliable live editing, and completion of the operation
coverage in `COVERAGE.md`. The scope is not reduced to currently passing tests.
Implementation mode: ponytail ultra; reuse the C++/Qt runtime and native APIs.
Commit each completed phase after its acceptance checks pass.

Plan reconciled with the working tree on 2026-09-07. This is the full delivery
plan, including unfinished functionality. A candidate package, successful build
or historical passing suite does not complete a phase.

## Status

| Phase | Status | Required acceptance |
| --- | --- | --- |
| P0 Automatic loading | Complete | Direct EXE, real Windows shortcut, file-association command arguments, and removing the extension verified in an isolated host copy. See `native/AUTOLOAD.md`. |
| P1 Installation | In progress; final installed-host verification pending | Prebuilt package, installation/update/disable/uninstall, normal visible startup, explicit background mode, persistent local configuration, MCP connection information. |
| P2 Sessions and documents | In progress; connection and save checks passed, lifecycle and recovery gaps remain | Restart/reconnect, port conflicts, instance identity, multiple clients, asynchronous failure/cancellation, document lifecycle, save-current/overwrite/recovery, explicit save/discard/cancel on close. |
| P3 Score and tracks | Pending | Missing notation/effects, keyboard/percussion notes, cross-track operations, instrument/tuning/capo/transposition, complex repeats/endings/jumps, verified read/write/undo/persistence/playback. |
| P4 Selection and clipboard | Pending | Partial track sets, complex voice ranges, batch commands, special/repeated paste, complex cut/replace, tuning/transposition/percussion compatibility, isolated system-clipboard verification. |
| P5 Playback and audio | Pending | Tempo points/ramps, loop ranges, mixing/effects/sounds/devices, repeat/jump timeline, accurate seeking and multi-document isolation. |
| P6 Exchange and workspace | Pending | MIDI/MusicXML/other GP import/export, PDF/image/audio output, printing/layout/staff display, document versus global preferences, actual output verification. |
| P7 Release | Pending | Supported-build matrix, diagnostics/recovery/upgrades, complex scores, long runs, multiple clients/documents, modal states, install/update/uninstall, complete applicable regression on the release binary. |

P0 -> P1 -> P2 establishes the foundation for feature expansion P3-P6. Independent
P2 work may continue in isolated hosts while the actual P1 installation awaits
administrator access; this does not complete P1. Execute feature phases in order,
reusing earlier capabilities, then qualify the complete package in P7.
Reliability checks run during every phase, not only at the final release gate.

## User Workflow And Architecture

Install the compiled package once, launch Guitar Pro through its normal entry
points, and connect an MCP client using the published local configuration. The
client operates the documents already open in that plugin-enabled process.
Manual edits and MCP edits must use the same native document and undo history.
Ordinary use must not require the repository, a developer launcher or compilation.

The runtime path is MCP client -> authenticated loopback HTTP -> in-process
C++/Qt bridge -> Guitar Pro native model and commands. Reuse the host event loop
for mutation ordering and existing status/configuration helpers. Add no external
resident service or scripting runtime without a demonstrated requirement.

This repository provides an application-local extension; it does not control
what the vendor bundles in Guitar Pro. Automatic loading takes effect after
installation and restart. A process opened before installation has not loaded
the extension; hot attachment is separate research, not a promised first-release
capability. Explicit background operation is a separate launch mode from normal
visible startup.

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

Deliverable: documented loader, compatibility checks and reversible installation
proof. Exit gate: the isolated host loads the actual bridge from direct EXE,
Windows shortcut and associated-score command arguments; removal restores the
baseline startup behavior. Already accepted in `c945e42`. Actual installed
Windows entry points are additionally checked in P1.

### P1: Package and integrate

Separate developer compilation from end-user installation. Provide bounded
installation detection, staged updates, persistent configuration, status and
disable controls, credential handling and uninstall recovery. Detect running
hosts before replacing loaded binaries. Check compatibility before invoking
private ABI functions. Verify the application remains usable if configuration
or the local MCP endpoint is unavailable.

- Deliver a prebuilt ZIP with install/update/enable/disable/uninstall commands,
  persistent per-user configuration, local credentials and in-app MCP status.
- Verify ownership checks, staged replacement, rollback, unsupported versions,
  unavailable configuration/port and a host running during update. Failure must
  leave ordinary Guitar Pro usable and report the actual service state.
- Install the accepted candidate into the real installation directory and check
  direct EXE, existing shortcut and file association independently. Verify
  visible startup, explicit background startup, connection and clean shutdown.
- Exercise install -> update -> disable -> enable -> uninstall and retained
  user configuration. Bind the evidence to the exact packaged binaries.

Exit gate: all of the above pass on the supported host. `974e4e0` is a candidate
checkpoint, not a P1 completion commit. The actual installation still contains
older binaries. Writing to Program Files needs Windows administrator access;
removing the execution sandbox does not supply it. The prior UAC cancellation
and pending retry decision remain relevant only to this installed-host step.

### P2: Make everyday work reliable

Provide instance discovery, reconnect, stable identity, collision handling and
serialized mutations. Complete operation status for open/new/close/save,
including failure, cancellation and timeout. Cover tab reordering, stale IDs,
manual edits, save-current, explicit overwrite, failed-save recovery and
save/discard/cancel on close. Never silently discard user changes.

- P2.1 Connection ownership: discover live instances using UUID, PID and process
  start time; bind requests to the selected instance; reject stale descriptors
  and mismatched identity before native work. Remove only owned runtime files.
- P2.2 Connection lifecycle: reconnect to the same process, explicitly select a
  replacement after restart, preserve credentials and invalidate old document
  IDs. Never automatically replay a mutation after a transport failure.
- P2.3 Port and client behavior: use the default port when available, test
  fallback when it is occupied, and fail clearly when an explicitly requested
  port is unavailable. Test real MCP clients importing configuration, including
  restart and changed URLs; a rewritten configuration file alone is not proof
  that a running client follows it. Align protocol/package version reporting.
- P2.4 Concurrency and host boundary: exercise at least two client sessions with
  overlapping requests and verify mutation ordering and document isolation.
  Verify repeated host launches and file forwarding. Test independent GUI
  processes only through a supported host mode; protocol-level server isolation
  cannot substitute for actual host-process evidence.
- P2.5 Document lifecycle: complete new/open/activate/close and expose a request
  identity and observed completion, error, cancellation or timeout. A timeout
  must not imply that a native operation was rolled back. Resolve outstanding
  work before retrying an action whose outcome is uncertain.
- P2.6 Save and recovery: save the current path, save a copy, adopt a Save As
  path, explicitly authorize overwrite, and preserve original file/path/dirty
  state after failure. A new document must have a destination before saving.
- P2.7 Close and shared editing: implement explicit save/discard/cancel, with a
  conservative default; verify manual edits, tab reorder, multiple dirty
  documents, stale IDs, modal dialogs and closing the last document.

Exit gate: successful and failed workflows are verified against actual files and
native state, wrong-target writes are rejected, and request completion matches
what happened in the host. Connection checks now cover two clients, identity,
restart and port fallback. Save-current, explicit overwrite and preservation
after rejected writes are verified. A second GUI launch exits, but opening its
requested score in the existing host has not passed in visible or background
mode. Independent GUI processes, native mid-write failure recovery, full
asynchronous completion/cancellation and close policies remain open. P2 is not
accepted.

### P3: Complete musical editing

Use the operation inventory in `COVERAGE.md` to track grace notes, bends, slides,
remaining effects, long connection chains, advanced tuplets, keyboard and
percussion notes, track instrument/configuration, tuning/capo/transposition,
cross-track notes, complex repeats, alternate endings and navigation marks.
Every supported operation needs structured state and a native edit path.

- P3.1 Complete structured read/write coverage for grace notes, bends, slides,
  remaining note/beat effects, advanced tuplets and grouping, and long
  legato/tie chains. Include interactions between effects, not just toggles.
- P3.2 Add keyboard and percussion note addressing/editing and cross-track
  operations, with correct staff, voice, instrument and pitch interpretation.
- P3.3 Complete track instrument configuration, tuning, capo and transposition;
  distinguish notation changes from sounding-pitch changes.
- P3.4 Complete alternate endings, nested/complex repeats and navigation marks;
  preserve references and automation when bars or tracks are inserted/deleted.

Exit gate: a mixed-instrument score can be read, edited, undone/redone, saved
and reopened with the intended notation and pitch. Verify affected playback in
P3 where available; advanced timeline/audio interactions also enter P5 tests.
Expand each feature family into named operations in `COVERAGE.md` as interfaces
are identified; unresolved operations remain visible rather than disappearing
behind a family-level completion label.

### P4: Complete ranges and transfer

Handle selected track subsets, complex voice/staff ranges and remaining batch
commands. Add special/repeated paste and complex cut/replacement. Verify content
mapping for different tunings, transposing instruments and percussion. Keep
native system-clipboard operations experimental until isolated tests pass;
tests must not replace the user's existing clipboard.

- P4.1 Extend selection to partial track sets, complex voice/staff ranges,
  keyboard/percussion notes and remaining applicable batch commands.
- P4.2 Complete special paste, repeated paste and complex cross-bar cut/replace,
  using the existing native score snapshot and undo infrastructure.
- P4.3 Verify duration, staff, voice, tuning, transposing-instrument and
  percussion mapping. Incompatible content must fail before partial edits.
- P4.4 Verify system clipboard exchange in a disposable desktop/user environment
  with isolation that actually works. The existing failed isolation attempt is
  not evidence of interoperability; keep these tools experimental until passed.

Exit gate: exact destination content, unaffected ranges, source independence,
undo/redo and save/reopen all match expectations. Record bounded batch sizes and
test their rejection behavior. System clipboard interoperability remains an
open requirement until verified; plugin-local clipboard tests do not satisfy it.

### P5: Complete playback

Edit tempo events and ramps, loop ranges, mixers/effect chains, sound selection
and devices. Validate actual timing and audio where applicable, including
repeat/jump expansion, seek positions, cancellation and document isolation.

- P5.1 Read/edit tempo points and ramps, loop boundaries and the expanded
  repeat/ending/jump timeline; distinguish score positions from playback ticks.
- P5.2 Complete mixer settings, sound selection, effect chains and available
  audio-device controls, including persistence and their native undo behavior.
- P5.3 Verify start/stop/seek/loop transitions, device changes and failures,
  cancellation and switching documents while playback work is pending.

Exit gate: measured timeline/frame progression and rendered or captured audio
agree with expected tempo, repeats and sound changes. State readback alone does
not establish audible correctness. Device-dependent capabilities and available
soundbanks are listed explicitly in the acceptance environment.

### P6: Complete file and workspace workflows

Add native imports/exports and parameterized layout/printing/settings operations.
Verify exported musical structure independently, render PDF/image output and
inspect it, and validate audio duration/content. Settings must read back and
declare whether their scope is the current document or the whole application.

- P6.1 Implement supported native MIDI, MusicXML and other GP import/export
  paths; surface format capabilities, options and expected conversion losses.
- P6.2 Implement PDF, image and audio output plus printing, page setup, layout,
  staff display and other document presentation controls.
- P6.3 Expose the remaining requested workspace/preferences, sound/plugin and
  dialog settings through parameterized native operations with declared scope.
- P6.4 Reuse P2 completion, overwrite, cancellation and failure handling for all
  output workflows; restore global settings modified by verification.

Exit gate: independently parse supported interchange outputs, reopen applicable
scores, render and inspect PDF/images, and check audio content/duration. Verify
print output through a controlled destination. Each requested format/setting
gets an operation-level result; unavailable host features are reported as
host-limited with evidence, not as successful exports or completed operations.

### P7: Qualify the release

Exercise the supported version matrix, restart/update/uninstall, modal dialogs,
port failures, concurrent clients, large and complex scores, repeated document
destruction and long-running sessions. Publish diagnostic instructions and
version-bound evidence with the compiled package.

- Freeze the release source and record source, core, bootstrap and host hashes.
  Run all applicable existing and new suites against that exact package.
- Initially qualify Windows x64 Guitar Pro 8.1.1.17. Reject unsupported ABI
  builds cleanly; each added build needs its own full applicable evidence.
- Cover guitar, keyboard, percussion and transposing-instrument scores with
  multiple voices/staves, nested tuplets, long connections, repeats/jumps and
  automation. Include a generated large score and record its actual dimensions.
- Planned minimum endurance matrix: two concurrent clients, ten open documents,
  100 open/edit/save/close cycles and a two-hour mixed-use session. Record
  process memory, handle counts, failures and cleanup trends; investigate
  unexplained growth and do not silently reduce a failing test envelope.
- Test modal interruption, malformed requests, port contention, denied output
  paths, stale descriptors, reconnect, upgrade/rollback and application exit.
  Controlled abrupt termination applies only to disposable test hosts/files.
- Re-run the actual installed entry points and package lifecycle, publish
  diagnostics, recovery instructions, support limits and release notes.

Exit gate: no unresolved plugin-caused crash, corruption, wrong-document write,
silent data loss or mandatory functional acceptance gap. Reproducible vendor
limitations remain explicitly open and version-bound. The observed rapid-start
shutdown deadlock needs a verified supported mitigation or an explicit release
scope decision; a five-second settling interval cannot make that test pass.

## Definition of Done

For each real user operation record implemented, verified, experimental,
unimplemented, or host-limited status. Distinguish blockers from completed work.
Exports/menu enumeration/JSON success do not prove a functioning native edit.

For mutations check actual state, target isolation, undo/redo where supported,
and save/reopen persistence. Test playback for changes that affect sound. For
asynchronous operations verify completion rather than merely `scheduled`.
Bind regression evidence to source, plugin and host hashes. Run all applicable
checks against the final binary before claiming full release completion.

Every mandatory operation needs a named coverage entry, target/parameter
contract, observed outcome and verification artifact. Host-limited, experimental
and unverified are not synonyms for complete. A host limitation requires a
reproducer and a documented release consequence; changing accepted scope must
be explicit. Do not declare the full project complete while mandatory gaps
remain unresolved.

Reuse the existing PowerShell verification scripts and `native/test-all.ps1`;
add focused checks where new behavior requires them. Phase work ends with updated
coverage/docs, package evidence where relevant, and a phase completion commit.
Intermediate commits must identify themselves as checkpoints. Do not mix
unfinished code into a documentation-only or completed-phase commit. Keep
runtime tokens, temporary hosts and generated evidence out of Git.

## Immediate Execution Order

1. Preserve the archived P1 candidate and its evidence. The development DLLs now
   contain P2 changes and must not be represented as the tested P1 package.
2. Complete P2 connection verification in isolated hosts: single-instance
   forwarding, external port contention, strict explicit port, two clients,
   stale identity, reconnect/restart and cleanup. Split tests by supported host
   behavior; do not count a prematurely exited second launch as a passing host.
3. Finish P2 document completion, save/recovery and close policies, then run the
   affected regression and document operation-level results.
4. Complete the pending real P1 update/entry-point check once Windows elevation
   is available. Independent repository work can proceed while it is pending.
5. Complete P3, P4, P5 and P6 in order, committing each accepted phase, then run
   P7 on the resulting release package. Report blockers with their actual
   affected phase, rather than treating installation alone as the project.

Fixed calendar estimates are not yet justified for unverified private APIs.
Track progress by accepted operations and phase gates; after P2, reassess effort
using the concrete remaining operation inventory without reducing its scope.

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
- P1 candidate checkpoint: `974e4e0`. An update attempt without elevation after
  sandbox removal failed with Access Denied when creating its staging directory;
  it did not update the installed binaries.
- P2 working tree: instance UUID/start-time descriptors, owned configuration
  cleanup, default-port fallback, instance-bound requests and explicit client
  reconnection implemented; build and a single-host handshake succeeded. Full
  verification is pending, and no P2 completion commit exists.
- P2 investigation: `native/test-instances.ps1` currently fails because a second
  GUI launch exits normally instead of providing an independent host, including
  when launched from a different isolated installation. The host inherits
  QtSingleApplication; no supported independent-instance mode has been verified.
  Preserve this boundary while testing concurrent clients and connection
  isolation independently.
- P2: document IDs are now UUIDs stored on the native document, replacing
  reusable view names. All document tools use that identity, including clipboard
  metadata and cross-document operations. Restart and reopen reject old IDs.
- P2: `gp_save_current` and explicit `overwrite=true` for copy/Save As implemented.
  Existing destination bytes are backed up before native writing; failed native
  writes attempt file/path recovery and retain the backup if file recovery
  fails. Thirty checks verify save-current, overwrite, protected open documents,
  locked/missing destinations, native state, GPIF and reopening. Failure during
  the native write itself has not yet been injected or verified.
- P2: full fourteen-suite regression passed 2225 checks with exit code 0 and
  descriptor cleanup at
  `artifacts/regression-a5bf1961faf441cfa42eabf4782296e9/regression.json`.
  Installation 43 plus protocol 26 passed at
  `artifacts/installation-8253afa705c0458bad1fe25ea708b534/verification.json`.
  These runs precede the subsequent exited-process identity fix below.
- P2: retaining a terminated process handle reproduced stale alias ownership:
  Windows still returns its creation time. Identity probing now also checks
  the exit timestamp. All 53 connection checks passed after this fix:
  `artifacts/instances-d32b829a0032440a86a001624a5d01df/verification.json`.
- P2: `test-instances.ps1 -CheckLaunchForwarding` remains a separately runnable
  failing workflow, not counted among the passing connection checks. The second
  process exits with code 0 but its score does not appear in the existing host;
  native `gp_open` does open that same kind of fixture. Visible-mode evidence:
  `artifacts/instances-fa5b0650158348838bc0f681a3f46daa/verification.json`.
  Earlier statements that it forwarded successfully were not supported by file
  readback. This still requires investigation and is not a completed P2 gate.
- P2 checkpoint validation after the exited-process fix: all fourteen suites,
  2225 checks, passed with exit code 0 and descriptor removal:
  `artifacts/regression-dd6830958c334f7cb5ad42add6e4bd4d/regression.json`.
  Core SHA-256:
  `00470B0D0F90015EF32076A37002BFC865DF0F43989FA954BF4585CB830F356C`.
  The same core passed all 53 connection checks under Windows PowerShell 5.1:
  `artifacts/instances-5524513fd40d4b2b988926b4abf5fd92/verification.json`.
  This is an intermediate P2 checkpoint; P1 installed-host acceptance and the
  remaining P2-P7 requirements are still open.
