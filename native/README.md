# 原生插件开发

本目录实现运行在 `GuitarPro.exe` 内的 C++ MCP 服务器。当前通过 Qt 通用插件入口加载，并直接使用 Qt 和经过验证的 GPCore 接口。Python、Node.js、UIA、输入模拟和外部转接服务不在运行链路中。

当前协作规范、开发目标和范围决策见 [AGENTS.md](../AGENTS.md)；工具行为见 [原生 MCP API 参考](API.md)，能力证据见 [覆盖清单](../docs/COVERAGE.md)。以下提供构建、加载、ABI 和测试入口。

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `guitarpro_mcp.cpp` | Qt 插件入口、MCP 工具目录、Qt 对象检查和请求分发 |
| `mcp_server.cpp` / `.h` | HTTP、JSON-RPC、初始化、会话、鉴权和工具参数校验 |
| `guitarpro_api.h` | 文档定位/切换、实时曲谱编辑、光标、撤销重做、保存和播放 |
| `guitarpro_clipboard.h` | 原生曲谱快照、复制/剪切/粘贴及兼容性检查 |
| `guitarpro_audio.h` | 速度自动化、音色效果、设备及开发音频验收 |
| `guitarpro_semantics.h` / `guitarpro_spec.h` | 语义读回、JSON schema、批量原生构建、一次提交与观察恢复 |
| `guitarpro_chords.h` / `guitarpro_page.h` | 和弦集合与指法、文档页面元数据 |
| `guitarpro_chord_abi.h` / `ampainting.def` | 和弦及页面文本的已核验 ABI |
| `guitarpro_io.h` | 文件交换、PDF/PNG/WAV 输出及工作区设置 |
| `guitarpro_abi.h` / `gpcore.def` / `gprse.def` / `amaudio.def` | 已确认的原生导出声明及导入库定义 |
| `object_registry.h` | Qt 对象生命周期观察和失效指针保护 |
| `window_capture.h` | 实例内窗口身份、Qt 窗口枚举及指定目标的离屏截图 |
| `discovery.h` | 只读指针与 RTTI 校验；开发模式下的对象关系探索 |
| `build.ps1` | 使用项目内 Qt SDK 和已安装的 Visual Studio 构建 DLL |
| `mcp-client.ps1` | 供开发验证使用的 PowerShell HTTP MCP 客户端 |
| `../test/` | 测试脚本、测试夹具、故障探针及其构建脚本 |

ABI 约束只保留已核验的最小范围：

- `guitarpro_abi.h` 只声明已使用的导出接口；实时模型由 Guitar Pro 持有，P8 批量建谱另通过原生构造函数创建独立 `Score` 副本。
- 已核验值对象包括 `ScoreModelRange`（8 字节）、`RhythmValue`（56 字节）、`Color`（3 字节 RGB）、`TimeSignature`（8 字节）和 `KeySignature`（16 字节且含虚析构函数）。构造、析构、对齐和大小均有静态断言或原生读回证据。
- MSVC 负责成员调用及返回值 ABI；代码不手写 `std::string` 或 `std::shared_ptr` 的返回约定。新增 Score、和弦、歌词和页面对象见 [P8 实现说明](P8.md)。
- 音频边界另经 8.1.1.17 专项核对：`AMAudio::AudioBuffer`/`IAudioBuffer` 的对象大小、交错 PCM 读写、锁和 `GPRSE::EffectsChain::processDSP` 均通过运行时探针；`gp_audio_abi` 句柄不暴露 native 地址，每次使用重新校验文档和对象归属。`Conductor` 尚未构造 RSE 声音时，`chain_mapping_status` 明确返回 `host_limited`（整体状态为 `experimental`），不把导出符号当作绑定链证据。
- P13 Provider 契约见 [`audio_bridge_api.h`](audio_bridge_api.h)：v1 使用 C ABI、显式结构体大小和稳定状态码，导出 `gpmcp_audio_bridge_get_info`/`gpmcp_audio_enumerate_v1` 供同进程原生消费者协商。枚举只允许 Qt 控制线程；回调元数据须立即复制，`chain` 和字符串不得跨回调保存。`test/build-audio-bridge-probe.ps1` 编译独立 fixture/probe 和原生 Qt 消费者；`test/test-audio-bridge.ps1` 检查无宿主契约及缺失 Provider，`test/test-audio-provider-host.ps1 -HostDirectory <.tools 中无已安装 MCP 的隔离宿主>` 验证真实导出回调、两种加载顺序、线程拒绝和句柄生命周期。VST3 消费者与实时 PCM 未实现。

## 构建和加载

正式安装和更新见 [安装说明](../docs/INSTALL.md)。Qt 自动加载入口、宿主校验和生产加载流程见 [自动加载方案](AUTOLOAD.md)。

```powershell
./native/build.ps1
# 或：
./setup.ps1 -QtDir ./项目内的Qt开发包路径
```

构建环境：x64、C++17、MSVC、`/MD`、发布版 Qt。当前使用 Qt 5.15.2 的 MSVC 开发包与宿主 Qt 5.15.3 运行库。构建只生成插件和最小导入库，不复制或替换宿主 Qt DLL。

所有生成文件保存在 `.tools/native/`。开发过程中新增的 SDK、探针、临时库和缓存也应放在项目内。宿主已经加载 DLL 时，先正常关闭相应实例，再重新编译。

```powershell
./start-plugin.ps1 -ScorePath C:/绝对路径/测试曲谱.gp
```

启动脚本为隔离新进程设置 `QT_PLUGIN_PATH`、`QT_QPA_GENERIC_PLUGINS` 和 `GPMCP_SESSION_FILE`，临时目录使用 `.cache/tmp`。服务优先监听 `127.0.0.1:18432`，端口冲突时回退到其他回环端口；显式设置 `GPMCP_PORT` 时严格报错。实例以 UUID、PID 和启动时间绑定，重启后旧配置失效。

完整实例、UTF-8、DDE 文件关联和安装生命周期验证见 [覆盖清单](../docs/COVERAGE.md) 与 [安装说明](../docs/INSTALL.md)。`test/test-all.ps1` 的完整原生回归包含 `audio-abi` 句柄和 buffer 边界专项；开发者需要运行 DDE 专项时使用：

```powershell
./test/build-dde-client.ps1
./test/test-instances.ps1 -HostDirectory '<isolated .tools host>' -CheckLaunchForwarding -StartupSettlingMs 15000
```

`-Visible` 验证正常可见模式；`-StartupSettlingMs` 记录实际等待值。DDE 客户端构建在 `.tools/dde-client`，不进入生产包。完整回归入口为 `test/test-all.ps1`。

`Get-McpInstances` 发现实例，`New-McpSession` 选择实例，`Reconnect-McpSession` 默认只重连原进程。实例绑定头为 `GuitarProMCP-Instance-Id`，不匹配时返回 HTTP 409；传输失败不会自动重放编辑。

## API 参考

协议、工具目录、参数和原生行为见 [原生 MCP API 参考](API.md)。批量编曲和语义 JSON 字段见 [P8 编曲与语义 JSON](P8.md)。

## 私有接口的版本约束

生产文档定位只在 `GuitarPro.exe` 和 `GPCore.dll` 的 SHA-256 与已验证构建完全一致时启用。播放接口另校验 `GPRSE.dll`，生命周期钩子另校验 `Qt5Core.dll`，页面文本另校验 `AMPainting.dll`。对应的宿主文件哈希为：

```text
GuitarPro.exe B233B0F1C87DEB3AECE693D51E8D3C3A841C88FEE78828607B20034737C4C6DF
GPCore.dll    9425F3E8EB627D328E0CB01146D43045D86D1BA639F73718BBE7FCCF733BD250
GPRSE.dll     E983122951B94C2513A1F05828DD03DCB11620DDC50F6B497723CAE0EB32BA6A
Qt5Core.dll   C2F85BD55C31E5380DD99F0D517EE183A54C3852480BC497DC30A5483FD70FF2
Qt5Gui.dll    BD853BB77296301EA0DBD0C432B5A4268389D4054C15F39DD44F245AF24EB407
AMPainting.dll 29EEC1AFE7BF7B02B7468B0AAA14BB4C0A85780E80D7BEBC6017472312C1ADBF
```

当前已验证关联为：

```text
IDocumentView + 0x30 → 视图实现对象
视图实现对象 + 0x98 → IDocument
IDocument + 0x10 → 文档实现对象
文档实现对象 + 0x68 → shared_ptr<Score> 的对象指针
IDocumentsManager + 0x10 → 管理器实现对象
管理器实现对象 + 0x50 → 管理器自身指针，用于校验
管理器实现对象 + 0x70 → 活动 IDocument
```

每次还检查文档类型、Score 控制块 RTTI、Score 自引用、ScoreModel 类型及原生 `modelPrivate()` 的返回值。模型写入通过原生命令完成，没有直接覆盖曲谱内存字段。

插件通过经过精确 Qt DLL 哈希校验的生命周期钩子观察 GUI 线程对象，并用真实事件观察补充发现插件加载前已创建的宿主服务。安装时检查钩子版本和占用情况；已被其他观察器占用时跳过。对象跨线程迁移时停止跟踪。

生命周期注册表和事件观察列表均从首次发现对象起保存 `QPointer`，服务快照直接复制已有引用。不能在后续请求中从长期保存的裸指针新建 `QPointer`：对象可能已销毁，而销毁通知的清理回调尚未执行，重新构造引用本身就会访问无效内存。音轨回归暴露了这一残留路径，修复后回归检查通过。原生播放还单独校验 `GPRSE.dll` 哈希。生命周期观察仍不代表能读取所有 C++ 内部状态，也未证明长期运行可靠性。

开发时可在启动前设置 `GPMCP_DEVELOPMENT=1`，启用只读 `gp_debug_objects`。其 RTTI 扫描可能读到相邻分配，结果只能作为研究线索，不能直接当作稳定 ABI。原始地址不接受客户端回传执行，默认模式也不暴露该开发工具。

## 验证与验收

当前验收结果、候选包、构建哈希和保留边界见 [覆盖清单](../docs/COVERAGE.md)。

### 常用命令

先关闭加载测试 DLL 的 Guitar Pro 实例。完整入口会在各组之间核对夹具、文档状态、源码哈希和 DLL 哈希；单项脚本必须满足自己的夹具前提。

```powershell
# 完整原生回归（含 P12，要求 .tools 中的隔离宿主）
./test/test-all.ps1 -Exe '<isolated .tools host>/GuitarPro.exe'

# 协议和 HTTP 边界
./test/test-mcp.ps1

# 安装包文件归属、生命周期和入口
./test/test-installer-files.ps1 -HostDirectory <host> -PackageDirectory <package>
./test/test-installation.ps1 -HostDirectory <host> -PackageDirectory <package>
./test/test-installed-lifecycle.ps1 -PackageDirectory <package> -StartupSettleMs 30000 -Elevate
./test/test-installed-entrypoints.ps1 -PackageDirectory <package> -StartupSettleMs 30000

# 文件交换和工作区
./test/test-p6.ps1 -SessionFile <session.json>

# P8 批量编曲、语义对象、异常恢复；PDF 复核依赖见 P8.md
./test/test-p8.ps1 -SessionFile <session.json> -RenderPdf

# P9 节拍文本、力度/符干/谱号和能力矩阵
./test/test-p9.ps1 -SessionFile <session.json>

# P10 偏好、音频 choices 和 MIDI 模型可用性
./test/test-p10.ps1 -SessionFile <session.json> -VerifyRestart

# EffectsChain -> track 句柄和 IAudioBuffer/DSP 边界（开发模式）
./test/test-audio-abi.ps1 -SessionFile <isolated-session.json>

# P11 窗口截图、PNG image content 和焦点保持
./test/test-p11.ps1 -SessionFile <session.json> -RequireCapture

# P12 真实窗口、模态下指定目标、隐藏菜单保护和只读性
./test/test-p12.ps1 -SessionFile <isolated-session.json>
# Qt 机制夹具：生命周期/地址复用、SubWindow、QWindow、限制及两种缩放
./test/test-p12-windows.ps1
# Windows 非客户区夹具：标题栏/边框、DPI、隐藏窗口和焦点保持
./test/test-p12-windows.ps1 -NativeFrame
# P12 跨客户端、重连与宿主重启后的 ID 拒绝（同时回归既有实例行为）
./test/test-instances.ps1 -HostDirectory '<isolated .tools host>' -StartupSettlingMs 15000
```

失败时保留宿主和 `artifacts/` 证据；不要把 `scheduled`、菜单枚举或 DLL 加载成功当作原生能力已验证。真实宿主回归需要 Guitar Pro 8.1.1.17 及匹配的宿主文件哈希。
