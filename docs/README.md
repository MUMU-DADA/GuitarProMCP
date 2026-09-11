# 文档索引

按使用场景查阅文档。当前状态只看 [AGENTS.md](../AGENTS.md)、[覆盖清单](COVERAGE.md) 和 [原生插件开发](../native/README.md)；历史记录不会覆盖当前结论。

| 文档 | 用途 |
| --- | --- |
| [AGENTS](../AGENTS.md) | 唯一的协作规范、开发目标、范围决策和质量门槛 |
| [项目入口](../README.md) | 安装入口、开发启动和基本连接方式 |
| [安装说明](INSTALL.md) | 预编译包安装、更新、停用、卸载和故障恢复 |
| [覆盖清单](COVERAGE.md) | 当前能力、保留边界和最新验收证据 |
| [原生插件开发](../native/README.md) | C++/Qt 构建、加载、ABI 和测试入口 |
| [原生 MCP API 参考](../native/API.md) | 协议、工具参数和原生行为 |
| [P8 编曲与语义 JSON](../native/P8.md) | 批量建谱、交换格式、和弦/歌词/段落和页面元数据 |
| [阶段计划与当前验收](DEVELOPMENT_PLAN.md) | P0-P13 总览、P9 边界、P10 验收、P11 实验性记录、P12 多窗口截图验收与 P13 音频 Provider 交付记录 |
| [Qt 自动加载方案](../native/AUTOLOAD.md) | 自动加载入口、生产实现和探针验证 |
| [开发计划历史归档](archive/DEVELOPMENT_HISTORY.md) | 旧版阶段快照、验收口径和执行记录 |
| [覆盖清单历史归档](archive/COVERAGE_HISTORY.md) | 旧版覆盖检查点和失败记录 |

## 本地生成目录

`.tools/` 保存 SDK、构建产物和开发探针；`.cache/` 保存运行配置、令牌、日志和临时文件；`artifacts/` 保存测试夹具、安装包和回归证据。三者均已加入 `.gitignore`，不应提交到 Git。
