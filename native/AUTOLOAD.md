# 自动加载方案与验证

P0 已于 2026-09-07 在 Guitar Pro 8.1.1.17 x64 / Qt 5.15.3 上通过验收。

安装目录的 `qt.conf` 设置了 `[Paths] Plugins = Plugins`。该宿主在启动时会实例化 Qt 图像格式插件，因此可在 `Plugins/imageformats/` 中新增一个 `QImageIOPlugin`，作为软件目录内的自动加载入口。

加载器不声明任何图像读写能力，也不解码或处理图像。构造函数将任务排入软件事件循环，由小型加载器校验宿主后加载现有的 Qt 通用 MCP 插件。

这是 Qt 的扩展机制。Arobas 未为此提供业务插件 SDK，插件发现时机依赖宿主版本，每个支持版本都必须重新验证。该方案无需修改 EXE 或 Qt DLL，无需系统环境变量、替换快捷方式、后台启动器或进程注入。

## 可复现的探针验证

先运行 `test/build-autoload-probe.ps1`，再运行 `test/test-autoload-probe.ps1`。测试把已安装运行文件复制到唯一的 `.tools/autoload-host-*` 目录，只修改该副本。探针仅向副本目录记录 PID、EXE 路径、Qt 版本和通用插件环境，不修改曲谱。观察结束后停止测试创建的进程。

在未设置 `QT_PLUGIN_PATH`、`QT_QPA_GENERIC_PLUGINS` 或 `GPMCP_SESSION_FILE` 的条件下，已验证：

1. 直接运行未修改的副本 `GuitarPro.exe` 会加载探针。
2. 通过实际指向该 EXE 的 `.lnk` 快捷方式启动会加载探针。
3. 执行 `GuitarPro.exe --open "<fixture>.gp"` 会加载探针。
4. 仅移除探针 DLL 后不再加载探针，软件仍保持运行。

实际 `.gp` 文件关联读取自 `HKEY_CLASSES_ROOT/Guitar Pro 8.AssocFile.gp/shell/open/command`，值为：

```text
"C:\Program Files\Arobas Music\Guitar Pro 8\GuitarPro.exe" --open "%1"
```

P0 在隔离 EXE 上验证了相同的启动参数，没有修改用户的文件关联。通过文件关联启动真实安装目录中的正式插件，仍属于 P1 安装验收。

该关联还注册了 `ddeexec = [open("%1")]`、应用名 `Guitar Pro 8`、主题 `system` 和 `ifexec = []`。后续 P2 调查确认：重复命令行启动发送的 Qt 单实例消息为空，真正的文件打开事件由 DDE 命令传递。因此，仅重复运行 EXE 命令不能作为完整的文件关联测试。

原生 DDE 测试客户端发送打开命令前会核对接收进程 PID。隔离环境的协议检查不能代替 P1 中尚未完成的真实资源管理器入口验收。

验证证据：`artifacts/autoload-probe-724964da0f7740f991172f092da7b43f/verification.json`。宿主 SHA-256 与生产版本白名单一致。探针结果只证明加载入口；P1 还必须验证实际 DLL、MCP 协议、实时曲谱、可见和后台启动、卸载及异常行为。

## 生产实现方案

在 `Plugins/imageformats/` 安装仅依赖 Qt 的小型加载器，在 `Plugins/generic/` 安装现有 MCP 实现。加载使用私有接口的代码前，校验 EXE、GPCore、GPRSE 和 Qt5Core 的哈希；后续 ZIP/GPIF 接口还要求校验 Qt5Gui，完整列表见 [私有接口的版本约束](README.md#私有接口的版本约束)。加载任务等待 Qt 主事件循环运行后执行。正常可见启动为默认行为，后台运行需要显式选择。

所有配置和诊断文件放在当前用户的数据目录。配置无效、已停用或宿主不受支持时跳过 MCP 启动，保留软件的正常使用能力。卸载只删除安装器管理的文件。

未来 Qt 主版本变化可能在加载器自身校验前就拒绝加载，因此不能承诺任意宿主更新后的兼容性。
