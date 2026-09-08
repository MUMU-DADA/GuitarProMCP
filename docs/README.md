# 文档索引

按使用场景查阅文档。当前状态只看根目录的 `AGENTS.md`、本目录的 `COVERAGE.md` 和 `native/README.md`；历史计划不会覆盖当前结论。

| 文档 | 用途 |
| --- | --- |
| [AGENTS](../AGENTS.md) | 唯一的协作规范、开发目标、范围决策和质量门槛 |
| [README](../README.md) | 项目概览、文档入口、开发启动和基本连接方式 |
| [安装说明](INSTALL.md) | 预编译包安装、手动解压、更新、停用、卸载和故障恢复 |
| [原生插件开发与调用](../native/README.md) | C++/Qt 构建、开发客户端、测试入口和原生 API 约束 |
| [P8 编曲与语义 JSON](../native/P8.md) | 批量建谱例子、交换格式、和弦/歌词/段落、页面元数据及限制 |
| [覆盖清单](COVERAGE.md) | 已验证能力、保留边界和当前验收证据 |
| [开发计划与验收记录](DEVELOPMENT_PLAN.md) | 历史阶段计划、验收标准和检查点；当前目标以 `AGENTS.md` 为准 |
| [自动加载方案](../native/AUTOLOAD.md) | Qt 自动加载入口、生产实现和探针验证 |

## 常用入口

最终用户只需要阅读 [安装说明](INSTALL.md)。开发者通常按以下顺序操作：

1. 准备 Visual Studio x64 C++ 工具和 Qt 5.15.2 MSVC x64 SDK。
2. 运行 `./setup.ps1` 或 `./native/build.ps1` 编译插件。
3. 运行 `./start-plugin.ps1` 启动隔离开发实例。
4. 阅读 [原生插件开发与调用](../native/README.md) 的协议和工具说明。
5. 运行 `./native/test-all.ps1` 执行完整回归；使用 `-Exe` 指定隔离宿主。

## 本地生成目录

`.tools/` 保存 SDK、构建产物和开发探针；重新克隆后可按构建环境重新准备。`.cache/` 保存运行配置、令牌、日志和临时文件，确认 Guitar Pro 已退出后可以删除。`artifacts/` 保存测试夹具、安装包和回归证据，测试会自动重新生成；它们均已加入 `.gitignore`，不应提交到 Git。

这些目录用于本地开发，不是发布包的一部分。提交前只需检查 `git status`，确认没有把生成文件强制加入版本库。
