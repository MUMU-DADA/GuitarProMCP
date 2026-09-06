# Automatic Loading Decision

P0 verified on Guitar Pro 8.1.1.17 x64 / Qt 5.15.3, 2026-09-07.

The installed `qt.conf` sets `[Paths] Plugins = Plugins`. During startup this
host instantiates Qt image-format plugins. An additional `QImageIOPlugin` in
`Plugins/imageformats/` is therefore an application-local bootstrap entry.
It reports no read/write capabilities and never decodes or handles images.
Its constructor queues work on the application's event loop, where a small
loader can validate the host and load the existing generic MCP plugin.

This is a Qt extension mechanism, not an Arobas business-plugin SDK. Discovery
timing is host-version-dependent and must be reverified for each supported
release. It requires neither modified executables/Qt DLLs, system environment
variables, shortcut replacement, a background launcher nor process injection.

## Reproducible Probe

Run `native/build-autoload-probe.ps1` then `native/test-autoload-probe.ps1`.
The test copies the installed runtime into a unique `.tools/autoload-host-*`
directory and changes only that copy. The probe merely writes PID, executable,
Qt version and generic-plugin environment to the copied directory. It does not
change scores. Test-created processes are stopped after observation.

Verified variants, with no `QT_PLUGIN_PATH`, `QT_QPA_GENERIC_PLUGINS`, or
`GPMCP_SESSION_FILE`:

1. Direct execution of the unchanged copied `GuitarPro.exe` loads the probe.
2. A real `.lnk` targeting that executable loads the probe.
3. `GuitarPro.exe --open "<fixture>.gp"` loads the probe.
4. Removing only the probe DLL stops loading it; the application stays running.

The actual registered `.gp` association was read from
`HKEY_CLASSES_ROOT/Guitar Pro 8.AssocFile.gp/shell/open/command` and is
`"C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe" --open "%1"`.
P0 verified those same arguments against the isolated executable; it did not
change the user's association. Opening an associated file against the actual
installed production plugin remains a P1 installation acceptance check.

Evidence: `artifacts/autoload-probe-724964da0f7740f991172f092da7b43f/verification.json`.
The host SHA-256 equals the production allowlist. Probe results do not prove
the MCP service itself works: P1 must verify the real DLL, protocol, live score,
visible/background startup, uninstall and failure behavior.

## Production Decision

Install a small Qt-only bootstrap in `Plugins/imageformats/` and the existing
MCP implementation in `Plugins/generic/`. Check executable, GPCore, GPRSE and
Qt5Core hashes before loading code that imports private interfaces. Queue the
load until the Qt main event loop is running. Keep normal visible startup as
the default and make background mode explicit.

All configuration/diagnostic files belong to the current user's data directory.
Invalid configuration, disabled state or an unsupported host must skip MCP
startup and preserve application use. Uninstall removes only installer-owned
files. Future Qt major-version changes can reject the bootstrap before its own
checks run, so compatibility cannot be promised across arbitrary host updates.
