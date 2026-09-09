# GuitarProMCP

GuitarProMCP 是运行在 Guitar Pro 8 进程内的 C++/Qt MCP 插件。MCP 客户端通过本机 HTTP `/mcp` 连接插件，插件在 Qt 主线程中调用已核验的 Guitar Pro 文档和曲谱接口。

```text
MCP 客户端 -> 本机 HTTP /mcp -> GuitarPro.exe 内的 C++ 插件 -> Qt/GPCore 原生文档模型
```

当前支持 Windows x64 的 Guitar Pro **8.1.1.17**。当前能力、边界和验收证据见 [覆盖清单](docs/COVERAGE.md)。

## 用户安装

使用预编译包中的 `Install.cmd` 安装。安装后从原有 Guitar Pro 入口启动；安装前已经运行的实例需要重启，插件不会热附加。

详细的安装、更新、停用、启用、卸载和故障恢复步骤见 [安装说明](docs/INSTALL.md)。

## 开发启动

需要 Visual Studio x64 C++ 工具和 Qt 5.15.2 MSVC x64 开发包。SDK 默认位于 `.tools/qt/5.15.2/msvc2019_64`。

```powershell
./setup.ps1
./start-plugin.ps1

# 启动时打开曲谱；-Visible 用于可见窗口验证
./start-plugin.ps1 -ScorePath C:/绝对路径/曲谱.gp
./start-plugin.ps1 -Visible
```

开发启动使用隔离的新进程，不附加到已经运行的普通 Guitar Pro 实例。完整构建、协议、实例和测试命令见 [原生插件开发](native/README.md) 和 [原生 MCP API 参考](native/API.md)。

## MCP 连接

默认端点为 `http://127.0.0.1:18432/mcp`。默认端口被占用时会自动选择其他本机端口；实际 URL 和令牌以实例生成的客户端配置为准。连接配置绑定实例 UUID，宿主重启后必须重新导入新配置，编辑请求不会自动重放。

完整工具目录、参数和原生行为只维护在 [原生 MCP API 参考](native/API.md)；P8 批量编曲和语义 JSON 见 [P8 原生编曲与语义 JSON](native/P8.md)。

## 验证

关闭测试宿主后运行完整原生回归：

```powershell
./native/test-all.ps1
```

可使用 `-Exe` 指定隔离宿主。真实宿主回归需要 Guitar Pro 8.1.1.17 及匹配的宿主文件哈希。

## 文档

| 内容 | 文档 |
| --- | --- |
| 用户安装与恢复 | [docs/INSTALL.md](docs/INSTALL.md) |
| 当前能力与证据 | [docs/COVERAGE.md](docs/COVERAGE.md) |
| 构建、ABI 和测试 | [native/README.md](native/README.md) |
| 协议和工具参数 | [native/API.md](native/API.md) |
| P8 JSON 与编曲接口 | [native/P8.md](native/P8.md) |
| Qt 自动加载 | [native/AUTOLOAD.md](native/AUTOLOAD.md) |
| 阶段计划与 P10 验收 | [docs/DEVELOPMENT_PLAN.md](docs/DEVELOPMENT_PLAN.md) |
| 完整文档索引 | [docs/README.md](docs/README.md) |

## 支持边界

私有接口只对已核验的宿主文件哈希启用，不支持的版本会拒绝加载。系统剪贴板互通、独立 GUI 多进程、原生标签拖动、原生保存进度取消和部分编辑组合仍按覆盖清单标记为实验性、未实现或宿主受限。

本项目按 [MIT License](LICENSE) 授权，不隶属于也未获 Guitar Pro 或 Arobas Music 官方认可。使用前请备份曲谱，并只在已验证的宿主版本上使用。
