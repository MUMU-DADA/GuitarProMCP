# GuitarProMCP

An MCP extension for controlling Guitar Pro through an external bridge.

## Goal

Expose all user-accessible Guitar Pro operations to MCP clients, including
file management, score and note editing, tracks and instruments, playback,
mixing and effects, import/export, printing, preferences, windows and dialogs.
Reading selections and editing the current unsaved score are also in scope.

Initial target: Windows and Guitar Pro 8.

## Starting Evidence

The preceding local investigation on 2026-09-06 reported:

- Installed version: Guitar Pro 8.1.1.17.
- Installation: `C:\Program Files\Arobas Music\Guitar Pro 8`.
- The `Plugins` directory contains Qt components; no third-party business
  plugin API or SDK was found.
- Windows registers `GuitarPro.exe --open "<file>"` for opening scores.
- GP, MIDI and MusicXML formats are supported; editing and conversion fidelity
  still need validation.

## Approach and Status

Use an external MCP server with available file/command interfaces and Windows
UI automation for interactive operations. Full control is the target, not a
verified capability; live selection, unsaved edits and UI reliability remain
unproven. Validate each operation and its resulting application state before
claiming support. A generic click or keystroke tool alone is not full coverage.

Repository initialization only: no server, dependencies or automation are
implemented. The next step is to inventory operations and validate one complete
MCP-to-Guitar-Pro workflow before expanding implementation.
