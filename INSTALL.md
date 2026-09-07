# GuitarProMCP 安装说明

支持的宿主：Guitar Pro 8.1.1.17，Windows x64。安装器会校验宿主 EXE 和私有接口 DLL 的哈希。使用预编译包无需编译器、Qt SDK、Python 或 Node.js。

## 安装与启动

1. 保存曲谱并关闭 Guitar Pro。
2. 解压安装包，运行 `Install.cmd`。写入 Guitar Pro 安装目录时，Windows 可能要求管理员权限。
3. 通过原有快捷方式、EXE 或关联的 `.gp` 文件启动 Guitar Pro。
4. 打开软件中的 **MCP** 菜单查看连接状态，使用“打开客户端配置”（`Open client configuration`）命令，将配置接入支持 HTTP MCP 的客户端。该文件包含访问令牌，请勿公开。

安装后随 Guitar Pro 启动自动加载插件。已经在安装前打开的普通实例需要重启；安装器不会向运行中的进程热加载插件。加载插件后，客户端可以直接操作该进程中已打开的文档，手工编辑与 MCP 编辑使用同一份曲谱。

正常启动时窗口保持可见。显式后台启动使用：

```powershell
./start-installed.ps1 -Background -ScorePath C:/Scores/example.gp
```

默认端点为 `http://127.0.0.1:18432/mcp`。默认端口被占用时会改用其他本机端口，实际 URL 以生成的配置为准；显式指定 `GPMCP_PORT` 时，端口冲突会报错。

配置与凭据存放在 `%LOCALAPPDATA%/GuitarProMCP`，独立于源码目录。文件包括 `native-session.json`、`mcp-client.json`、`mcp-auth-token`、`settings.json`，以及不含凭据的 `status.json`。开发脚本和隔离测试可通过 `GPMCP_DATA_DIR` 指定其他数据目录。

插件还为当前实例生成 `native-session-<UUID>.json` 和 `mcp-client-<UUID>.json`，退出时清理。固定的 `mcp-client.json` 和独立实例配置都绑定当前 UUID；进程重启后，即使端口相同，也要重新导入新配置。旧配置会被拒绝，避免意外操作新进程。端口变化后同样需要重新导入；运行中的客户端不会因为配置文件变化就必然自动刷新。

## 更新、停用和卸载

在解压后的安装包目录执行：

```powershell
./install-plugin.ps1 -Action Status
./install-plugin.ps1 -Action Disable
./install-plugin.ps1 -Action Enable
./install-plugin.ps1 -Action Update -Elevate
./install-plugin.ps1 -Action Uninstall -Elevate
```

启用或停用在下次启动软件时生效。MCP 状态对话框提供“随软件启动加载”（`Load at startup`）复选框，服务停用后也可使用。更新和卸载前必须关闭使用相关插件文件的宿主。

卸载保留用户配置与凭据，只删除确认归安装器管理的 DLL 和安装记录。已被修改或无法识别的文件不会被覆盖。更新失败时回滚已替换的 DLL；回滚无法完成时保留并报告备份目录。

安装路径不同时，在安装或启动命令中传入 `-InstallDirectory C:/Path/To/GuitarPro`。安装器不修改宿主 EXE、厂商 Qt DLL、快捷方式、文件关联或系统环境变量。

## 加载与诊断

软件目录内的 Qt 图像插件加载器将现有原生 MCP 插件的加载任务提交到 Qt 事件循环，自身不处理图像。加载核心前校验私有接口所依赖的宿主文件。不支持的宿主或无效配置会跳过 MCP 启动并报告状态，保留 Guitar Pro 的正常使用能力。加载机制与版本有关，Guitar Pro 更新后必须重新验证。

状态对话框及 `status.json` 使用以下状态值：

| 状态值 | 含义 |
| --- | --- |
| `running` | 服务正在运行 |
| `disabled` | 已停用，下次启动时不加载核心 |
| `unsupported_host` | 宿主版本或文件哈希不受支持 |
| `configuration_error` | 配置无效 |
| `load_error` | 核心插件加载失败 |
| `service_error` | 服务启动失败，例如显式指定的端口已被占用 |

实例发现、两个客户端、重连、默认端口回退及 MCP Inspector 配置重新导入已完成 P2 专项验证。Windows 文件关联使用 DDE 命令 `[open("%1")]`；单独再次执行 `GuitarPro.exe --open ...` 不会传递文件路径。独立 GUI 多进程列为宿主限制。

当前为开发版本，P1 安装集成已完成真实目录及普通用户验收。EXE、原有快捷方式、文件关联和后台启动均通过；安装、更新、启停、卸载及重装后保留用户配置与凭据。普通退出验收采用启动后等待 30 秒的条件。准确安装包、证据及完整功能要求见源码仓库的 [开发计划](DEVELOPMENT_PLAN.md) 与 [覆盖清单](COVERAGE.md#p1-验收)。已归档安装包的行为以随包文档和对应二进制为准。

该宿主版本在启动期间快速关闭时，厂商 AMNetwork 线程可能在退出过程中持续等待。不加载 MCP 核心、仅使用最小 Qt 关闭探针也能复现，仍是未解决的可靠性问题。完整编辑回归正常退出、退出码为 0，并不能证明快速启动和退出已经可靠；延长启动等待也不是已验证的修复。
