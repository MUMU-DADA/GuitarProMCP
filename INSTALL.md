# Install GuitarProMCP

Supported host: Guitar Pro 8.1.1.17, Windows x64. The installer verifies the
executable and private-interface DLL hashes. No compiler, Qt SDK, Python or
Node.js is needed to use the packaged DLLs.

1. Save your scores and close Guitar Pro.
2. Extract the package and run `Install.cmd`. Windows may request administrator
   access to the Guitar Pro installation directory.
3. Start Guitar Pro using its existing shortcut, executable or a `.gp` file.
4. Use the application's **MCP** menu entry for connection status and the
   **Open client configuration** command. Add that configuration to an HTTP MCP
   client. The file contains an access token and should remain private.

The normal window stays visible. To start an explicit background instance:

```powershell
./start-installed.ps1 -Background -ScorePath C:/Scores/example.gp
```

Default endpoint: `http://127.0.0.1:18432/mcp`. Configuration and credentials are
stored under `%LOCALAPPDATA%/GuitarProMCP`, independently of the source checkout.
The files are `native-session.json`, `mcp-client.json`, `mcp-auth-token`,
`settings.json` and a credential-free `status.json`. Developer scripts and
isolated tests can override the data directory with `GPMCP_DATA_DIR`.

## Update, Disable and Uninstall

Run these commands from the extracted package:

```powershell
./install-plugin.ps1 -Action Status
./install-plugin.ps1 -Action Disable
./install-plugin.ps1 -Action Enable
./install-plugin.ps1 -Action Update -Elevate
./install-plugin.ps1 -Action Uninstall -Elevate
```

Enable/disable takes effect on the next application start. The MCP status
dialog also has a **Load at startup** checkbox, including when the service has
been disabled. Updates and uninstall require the affected host to be closed.
Uninstall retains user configuration and credentials and removes only verified
installer-owned DLLs and its receipt. Modified/unrecognized files are not
overwritten. A failed update rolls back replaced DLLs; if rollback cannot
finish, its backup directory is retained and reported.

For a non-default host directory, pass `-InstallDirectory C:/Path/To/GuitarPro`
to the installation or launch command. Installation does not change the host
EXE, vendor Qt DLLs, shortcuts, file associations, or system environment.

## Loading and Diagnostics

An application-local Qt image-plugin bootstrap queues the existing native MCP
plugin onto the Qt event loop. It handles no images. Private-interface files
are checked before loading the core plugin. An unsupported host or invalid
configuration skips MCP and reports a status while preserving ordinary
application use. This loading mechanism is version-dependent and must be
reverified after Guitar Pro updates.

The status dialog and `status.json` distinguish `running`, `disabled`,
`unsupported_host`, `configuration_error`, `load_error` and `service_error`.
A port already in use produces `service_error`; close the other plugin instance
or use `GPMCP_PORT` with a separate data directory. Multi-instance discovery is
still planned in P2. The initial package is a development release: remaining
functional and reliability scope is tracked in `DEVELOPMENT_PLAN.md` and
`COVERAGE.md` in the source repository.

Rapidly closing this host build during startup can leave its vendor AMNetwork
thread waiting during shutdown. This was also reproduced with a minimal
Qt-only closing probe without the MCP core. It remains an open reliability
issue. The current complete editing regression exits normally with code 0;
that result does not establish reliable rapid startup/exit behavior.
