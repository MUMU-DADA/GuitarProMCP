# GuitarProMCP 开发者入口

本文件是开发者入口。GuitarProMCP 是运行在 Guitar Pro 8 进程内的 C++/Qt MCP 插件。MCP 客户端通过本机 HTTP `/mcp` 连接插件，插件在 Qt 主线程中调用已验证的宿主文档和曲谱接口。

```text
MCP 客户端 -> 本机 HTTP /mcp -> GuitarPro.exe 内的 C++ 插件 -> Qt/GPCore 原生文档模型
```

当前支持 Windows x64 的 Guitar Pro **8.1.1.17**。P0-P9 已按声明范围完成验收，P8 提供批量编曲与曲谱语义接口，P9 增加可核验的节拍文本、力度标记、符干方向、谱号编辑和能力矩阵，并提供保留既有点的实验性 DSP 参数自动化路径。系统剪贴板互通、细粒度排版、任意乐器/指法、力度/表情/音量自动化、独立 GUI 多进程、原生标签拖动、原生保存进度取消和部分宿主可靠性场景仍是实验项或宿主限制。当前构建、历史发布包和证据以 [覆盖清单](docs/COVERAGE.md) 为准。

## 文档入口

| 读者 | 文档 | 内容 |
| --- | --- | --- |
| 最终用户 | [docs/INSTALL.md](docs/INSTALL.md) | 安装、更新、启停、卸载和故障恢复 |
| 开发者 | [native/README.md](native/README.md) | 构建、连接、协议边界、工具参数和测试入口 |
| 编曲调用 | [native/P8.md](native/P8.md) | 批量建谱、语义 JSON、六线谱、和弦、歌词和页面元数据 |
| 验收/维护 | [docs/COVERAGE.md](docs/COVERAGE.md) | 当前能力、边界和最新证据 |
| 历史追溯 | [docs/DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md) | 历史阶段和验收检查点 |
| 自动加载 | [native/AUTOLOAD.md](native/AUTOLOAD.md) | Qt 加载入口和探针验证 |
| 协作规范 | [AGENTS.md](AGENTS.md) | 唯一的目标、范围和质量门槛来源 |

## 安装使用

预编译包使用 `Install.cmd` 安装，安装后从原有 Guitar Pro 入口启动。正常启动窗口可见；后台启动使用 `start-installed.ps1 -Background`。插件生成的连接配置位于 `%LOCALAPPDATA%/GuitarProMCP`，从 MCP 菜单或 `.cache/mcp-client.json` 获取实际端点和令牌。

安装前已经运行的 Guitar Pro 实例需要重启，插件不会热附加。安装器不替换宿主 EXE、Qt DLL、快捷方式或文件关联。详细步骤和回滚方式见 [docs/INSTALL.md](docs/INSTALL.md)。

## 开发启动

需要 Visual Studio x64 C++ 工具和 Qt 5.15.2 MSVC x64 开发包。开发 SDK 默认位于 `.tools/qt/5.15.2/msvc2019_64`。

```powershell
./setup.ps1
./start-plugin.ps1

# 启动时打开曲谱；-Visible 用于可见窗口验证
./start-plugin.ps1 -ScorePath C:/绝对路径/曲谱.gp
./start-plugin.ps1 -Visible
```

插件输出到 `.tools/native/plugins/generic/guitarpro_mcp.dll`。开发启动使用隔离的新进程，不附加到已经运行的普通 Guitar Pro 实例；重新编译 DLL 前先关闭加载该 DLL 的宿主。

完整构建、环境变量、实例发现、DDE 文件关联和 PowerShell 客户端说明见 [native/README.md](native/README.md)。

## MCP 接口

完整工具目录、参数、返回状态和宿主限制只维护在 [native/README.md#使用原生曲谱工具](native/README.md#使用原生曲谱工具)。工具按以下范围覆盖：

- 实例、模态对话框、文档打开/新建/关闭/保存和恢复
- 曲谱读取、光标、选区、音符/节拍/小节/音轨编辑
- 技法、连奏/延音线、调弦、移调和插件独立剪贴板
- 播放、时间线、音色、效果和音频设备
- Qt 对象检查、原生窗口控制和开发模式探针
- GP5/GPX/MusicXML/MIDI 导入以及 PDF/PNG/WAV 导出
- 批量建谱、riff 插入、JSON 交换、ASCII 六线谱和歌曲结构摘要
- 原生和弦符号/和弦图、五行歌词、段落及页面元数据

服务使用协议版本 `2025-06-18`，默认端点为 `http://127.0.0.1:18432/mcp`。默认端口被占用时会自动选择其他本机端口；显式设置 `GPMCP_PORT` 时，冲突会报告错误。连接配置绑定实例 UUID，宿主重启后必须重新导入新配置，编辑请求不会自动重放。

## 验证入口

关闭测试宿主后运行完整原生回归：

```powershell
./native/test-all.ps1
```

指定隔离宿主使用 `-Exe`；协议、安装包和单项专项命令见 [native/README.md](native/README.md)。真实宿主回归需要 Guitar Pro 8.1.1.17 及匹配的宿主文件哈希。没有实际状态读回或保存重开证据时，不把 DLL 加载、JSON 返回或菜单枚举视为能力完成。

## 当前边界

- 私有接口只对已核验的宿主文件哈希启用，不支持的版本会拒绝加载。
- 手工编辑与 MCP 编辑共用宿主文档、未保存状态和撤销历史；未知异步结果会阻止后续写入。
- 系统剪贴板互通、独立 GUI 多进程、原生标签拖动和原生保存进度取消不属于当前交付前提。
- 启动瞬间的 AMNetwork 快速退出等待仍是宿主限制；正常使用后的退出已按发布范围验收。

完整能力矩阵、限制、构建哈希和验收证据见 [docs/COVERAGE.md](docs/COVERAGE.md)。

## 许可与免责声明

本项目按 [MIT License](LICENSE) 授权，不隶属于也未获 Guitar Pro 或 Arobas Music 官方认可。插件调用 Guitar Pro 私有接口，宿主更新、插件冲突或环境差异可能导致无法加载、操作失败或影响未保存曲谱；使用前请备份曲谱，并只在已验证的宿主版本上使用。
