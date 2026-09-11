# GuitarProMCP 阶段计划与当前验收

更新日期：2026-09-12。本文件记录 P0-P13 阶段计划、当前验收标准、P9 实施边界、P10 验收、RSE/音频 ABI 边界、P11 实验性记录、P12 多窗口枚举与指定窗口截图的验收记录以及 P13 音频 Provider 与多插件接口设计计划。当前协作规范、开发目标、产品要求、范围决策和质量门槛统一见 [AGENTS.md](../AGENTS.md)；历史执行记录见文末归档。

> 文档分工遵循 [AGENTS.md](../AGENTS.md#文档分工)：阶段记录见本文件，当前能力及具名证据见 [COVERAGE.md](COVERAGE.md)，接口细节见 [native/API.md](../native/API.md) 和 [native/P8.md](../native/P8.md)。

阶段结论以绑定源码和二进制的具名验收记录为准；历史检查点只用于追溯，见文末归档。

## 阶段总览

| 阶段 | 当前状态 | 必须交付并验收的内容 |
| --- | --- | --- |
| P0 自动加载 | 已完成 | 隔离宿主中验证直接启动 EXE、真实 Windows 快捷方式、文件关联启动参数和移除扩展；见 [自动加载方案](../native/AUTOLOAD.md) |
| P1 安装集成 | 已完成，按 2026-09-07 用户确认的普通启动与退出范围验收 | 预编译包、真实目录安装/更新/启停/卸载/重装、四种启动入口、持久配置及客户端连接；快速退出挂起归 P7 |
| P2 会话与文档 | 已完成，按 2026-09-07 用户确认的必要范围验收 | 重启重连、端口冲突、实例身份、多客户端、异步失败与可确认的取消、多文档生命周期、保存及恢复、关闭时保存/丢弃/取消；三项宿主限制见下文 |
| P3 曲谱与音轨 | 已完成，按 2026-09-07 用户确认的必要范围验收 | 主要技法、键盘/打击乐、调弦/变调夹、跨轨移调、长连接链及复杂反复；最终构建通过 19 组、3732 项回归并正常退出 |
| P4 选区与剪贴板 | 已完成，按本次最小必要范围验收 | 音轨/谱表/声部筛选、批量清空/删除、文本特别粘贴、重复、跨小节剪切及整小节替换、兼容性预检；系统剪贴板保持实验状态 |
| P5 播放与音频 | 已完成，按本次最小必要范围验收 | 变速点及渐变、原生选区循环、已有音色/效果、设备选项、展开时间线、定位与多文档隔离；真实 PCM 验证 |
| P6 导入导出与工作区 | 已完成，按本次最小必要范围验收 | 当前构建专项 116 项、显式 PDF 复核 119 项通过；候选包已核对。受权限限制的完整回归按用户要求跳过，不计为通过 |
| P7 发布验收 | 已完成，按 2026-09-08 用户确认的一小时持续运行范围验收 | 最终候选包完整回归、双客户端长测、资源回落、恢复、退出和真实安装生命周期；AMNetwork 快速退出按厂商限制保留 |
| P8 高层编曲与曲谱语义 | 已完成，按本次最小必要范围验收 | 批量建谱、JSON 往返、文本六线谱、结构摘要、和弦/歌词/段落及页面元数据；含 PDF 专项 207 项、完整原生回归 23 组 4375 项通过 |
| P9 编辑面板剩余能力 | 已完成可核验范围，剩余项按宿主受限或实验性保留 | 节拍文本、`PPP`–`FFF` 力度标记、`Upward`/`Downward`/`auto` 符干方向、`G2/F4/C3` 谱号写入及读回、撤销重做、保存重开；沿用 P8 和弦/歌词/页面元数据及 P5 已有音色效果和速度自动化；能力矩阵与边界见下文 |
| P10 偏好设置与基础音频/MIDI 控制 | 已完成最小可核验范围，剩余项按宿主受限或待调查保留 | 一般/界面偏好、我的资讯默认值、音频输出通道 choices、MIDI 设备/输出列表/采集灵敏度及乐谱错误开关；更新/Beta、每路 MIDI 延迟、通道检测及驱动控制面板另行调查 |
| P11 界面截图与窗口状态采集 | 已实现最小 Qt 离屏路径，实验性 | `gp_screenshot` 已注册并通过 MCP image content 返回 PNG；正常、后台、被遮挡和最小化均走 `QWidget::render`，不改变焦点、不发送输入、不截取整个桌面；活动模态对话框优先捕获；尚未完成真实宿主全矩阵，无法证明离屏结果等价时返回 `status=host_limited` |
| P12 多窗口枚举与指定窗口截图 | 已完成核心实现与真实宿主专项，截图保持实验性 | `gp_windows` 提供稳定身份、数量与状态，`gp_screenshot(window_id)` 保留显式目标；核心多窗口、模态并存、只读性和失效拒绝有证据；剩余矩阵逐项保留，见下文与 [P12 范围约定](../AGENTS.md#p12-范围约定) |
| P13 音频 Provider 与多插件接口设计 | 已完成最小 Provider 契约、MCP 适配和真实宿主原生消费者专项；VST3 消费者未实现 | 抽象进程内音频 Provider；MCP、VST3 和其他插件通过版本化 ABI 使用；允许按真实需求重新设计 MCP 工具和数据模型；实时 PCM 获取仍需单独设计和验证 |

P0、P1、P2 为 P3–P6 提供基础，随后由 P7 对完整安装包进行发布验收。P1 已完成真实安装集成验收；可靠性检查继续贯穿后续阶段。

## P8：高层编曲与曲谱语义接口

状态：已完成（2026-09-08）。P8 的请求、字段、限制和原生调用细节唯一维护在 [P8 原生编曲与语义 JSON](../native/P8.md)；当前能力与验收证据见 [P8 验收](COVERAGE.md#p8-验收)。

- 批量建谱：`gp_create_from_spec`、`gp_apply_spec`、`gp_insert_tab`，支持 `replace/append/insert`、多轨、声部、谱表、调弦、既有技法和速度点。
- 语义交换：`gp_export_json`、`gp_import_json`、`gp_export_tab`、`gp_structure`，使用 `guitarpromcp.p8` v1。
- 曲谱对象：和弦、和弦图、五行歌词、段落和页面元数据均使用原生模型，并支持实际读回、撤销和保存重开。
- 验收：P8 专项和完整原生回归的数字、哈希与具名证据只在覆盖清单维护。

## P9：编辑面板剩余能力
P9 用于归拢当前截图及实际用户编辑流程中尚未覆盖的按钮级能力。本阶段按最小可核验范围完成：新增节拍文本、节拍力度标记、符干方向和谱号写入，以及只读能力矩阵，复用 P8/P5 已有原生接口，并把没有已核验 GPCore 写入 ABI 的项目明确标为宿主受限或实验性。它不把 Qt 动作枚举或控件属性修改当作曲谱编辑完成，也不复制第二套曲谱模型。

### P9.1 文本、和弦与记谱按钮

状态：已完成可核验范围。新增 `gp_edit_beat operation=text/dynamic/stem` 和 `gp_edit_measure operation=clef`：按光标或选区写入节拍文本、`PPP`–`FFF` 力度标记和 `Upward`/`Downward`/`auto` 符干方向，按当前谱表小节写入 `G2/F4/C3` 谱号，读回实际 `Beat::freeText`、`Beat::dynamic`、符干 getter 和 `Bar::clef`，并核对 dirty、原生撤销/重做和保存重开。力度清除、力度/表情自动化以及截图中未落到已核验模型的按钮标为宿主受限。

### P9.2 排版与视图编辑

状态：页面尺寸、边距、方向、页面元数据、谱表显示和视图控制沿用 P6/P8 的原生接口并已有 PDF/PNG 或保存重开证据；节拍符干方向已通过 GPCore 原生 setter 完成并单独读回。细粒度符杠分组、连音括号、括号和间距没有已核验写入 ABI，标为宿主受限；Qt 控件属性或菜单启用状态不计为完成。

### P9.3 乐器、指法、音色与自动化

状态：已有音色/效果选择、旁路、参数、删除及速度点/渐变沿用 P5，并有时间线或 PCM 证据；`gp_automation` 现可读取整条音轨的原生自动化，并以实验性方式写入 `DSPParam_00..DSPParam_31`，提交时保留同轨道其他点和旁路状态。该参数的宿主语义及声音影响尚未核验。任意乐器定义、自动指法搜索、自定义音色/效果构造和力度/表达/音量自动化仍标为宿主受限。剩余已知技法可逐项使用既有工具，但全部组合及跨引擎声音结果不作推断。

### P9.4 系统剪贴板与完整内容转移

状态：插件内部剪贴板、跨小节转移和兼容性拒绝沿用 P4 的已验证范围。系统剪贴板互通仍为 `GPMCP_DEVELOPMENT=1` 下的实验接口；本机无法建立隔离窗口站，未计入通过，不能用内部剪贴板结果代替系统互通验收。

### P9.5 组合验收与支持边界

状态：`gp_p9_status` 提供截图按钮到 MCP 工具、原生字段和验收边界的能力矩阵，使用“已实现、已验证、实验性、未实现或宿主受限”状态值。矩阵覆盖文本、力度、符干方向、谱号、沿用的和弦/歌词/页面、已有音色效果、速度自动化、实验性音轨自动化、排版、任意乐器/指法、力度自动化、系统剪贴板及剩余技法组合；不支持的宿主版本、驱动、格式或 UI 上下文明确拒绝。

验收标准：所有 P9 写入均在 Qt 主线程按顺序执行，核对实际模型、未保存状态、撤销/重做和保存重开；影响排版或声音的沿用能力继续使用已有 PDF/PNG、时间线或 PCM 证据。结果未知时保持写入阻塞，不自动重放编辑或猜测回滚成功。P9 不扩展已排除的外部常驻服务、输入模拟、前台窗口依赖或未核验宿主 ABI。

### P9 剩余要求归档

以下缺口全部属于 P9 的剩余编辑面板要求，当前不计为完整按钮覆盖：

- 细粒度符杠分组、连音括号、括号、间距、系统布局和其他刻谱排版（节拍符干方向已完成）；完整歌词排版。
- 力度标记清除、力度/表情/音量曲线及其对播放的完整自动化。
- 任意乐器定义、打击乐演奏法配置、自动指法搜索，以及跨乐器的自动指法映射。
- 自定义音色和效果构造、效果参数名称数据库、完整音色/效果自动化和跨引擎组合。
- Windows 系统剪贴板互通、任意音轨集合映射、完整特别粘贴过滤项和部分小节跨栏替换。
- 截图中剩余技法、跳转、排版和音源组合的逐项交互与声音回归；已有单项接口通过不推断全部组合完成。

这些项目的状态由 `gp_p9_status` 逐项报告为“宿主受限”“实验性”或“未实现”。只有获得已核验的宿主原生写入路径，并完成实际模型读回、撤销/重做、保存重开以及必要的 PDF/PNG 或时间线/PCM 验证后，才能从 P9 剩余清单移入已完成范围。

### P9 验收

状态：完成可核验范围并新增符干方向和实验性音轨自动化保留路径（2026-09-09）。使用 Windows x64 Guitar Pro 8.1.1.17 隔离开发宿主，实际加载当前构建的 `guitarpro_mcp.dll`，SHA-256 以专项证据 `verification.json` 为准。

`test/test-p9.ps1` 通过 65 项：读取 P9 能力矩阵、检查 `gp_capabilities` 公共矩阵、检查节拍文本/力度/符干/谱号工具映射、读取音轨自动化并验证严格拒绝参数、保留 `Sound` 点的实验性 DSP 参数写入/不变写入/撤销重做/删除、打开真实 `.gp` 夹具、写入 Unicode 文本、选区批量写入、清除、`PPP`–`FFF` 力度标记光标/选区写入、`Upward`/`Downward`/`auto` 符干方向光标/选区写入、`G2/F4/C3` 谱号写入、dirty、撤销/重做、保存、独立重开读回和关闭清理。具名证据为最新 `artifacts/native-p9-1666ae49cb204e44a9c18183b6440c9c/verification.json`，其中 `complete=true`。随后完整 `test/test-all.ps1` 通过 24 组、4406 项，证据为 `artifacts/regression-6b51102da11049a0b4fcfb39902da538/regression.json`，退出码 0 且连接描述已清理；PowerShell 语法检查和 `git diff --check` 通过。

能力矩阵还记录了沿用 P5/P8 能力及明确边界：音轨自动化只提供实验性 DSP 参数曲线，力度/表情/音量自动化、力度清除、细粒度符杠分组及排版、任意乐器/指法为宿主受限；系统剪贴板为实验性且默认关闭；剩余技法组合不作穷举。矩阵通过 `gp_p9_status` 和 `gp_capabilities.p9` 提供，未核验的宿主 ABI 不会因菜单可枚举或 DLL 加载而被标为完成。

## P10：偏好设置与基础音频/MIDI 控制

状态：已完成最小可核验范围（2026-09-09）。P10 面向截图中的全局偏好设置，复用现有 Qt 偏好模型和 `gp_audio_device` 路径。所有字段通过明确 allowlist 和可读回的宿主 `QMetaProperty` 提交；控件属性变化、菜单状态或按钮点击本身不计为能力完成。宿主没有创建相应模型时返回 `status=host_limited`，不把菜单可见或属性名猜测成已实现。

### P10.1 一般偏好

扩展 `gp_preferences` 的 `general` 模型，覆盖 `defaultTemplate`、`defaultStylesheet`、`pageMode`、`zoom`、`forceStylesheet`、`forcePageMode`、`forceZoom`、`forceNotation`、`forcePlayback`、`restoreOpenFile` 和 `embedAudioFiles`。返回 `property_info`、实际类型和宿主枚举 choices；默认模板复用 `gp_templates` 的宿主模板枚举；样式、布局、谱表、音源和缩放使用宿主实际枚举或数值，不把中文界面文字作为协议值。专项已验证强制选项读回和 `forceNotation` 跨宿主重启持久化。

更新检查、检查频率、Beta 渠道以及会触发更新器、重启或界面重建的操作不纳入本小节的稳定写入范围；若后续确认有稳定模型 setter，另设专项验证。

### P10.2 界面偏好

扩展 `gp_preferences` 的 `gui` 模型，覆盖已确认的 `showFretlightButton`、`uiLanguage` 和播放游标样式属性，并在同一 allowlist 中调查 `cursorStyle`、`plusMinusKeyBehavior`、`showMSB`、`showExamples` 是否为可写 `Q_PROPERTY`。已存在的 `autoOpenFxPopup`、`highlightBar`、`includeChordsInCopyPaste`、`playSoundWhileEditing` 和 `useMediaKeys` 保持回归覆盖；语言切换后的对象快照需重新获取。

语言切换可能触发界面重翻译并使 Qt 对象快照失效；验收必须读回最终状态，并允许重新建立 MCP 会话或重新获取快照。不能用 `gp_set_property` 直接改控件来代替模型提交。

### P10.3 我的资讯默认值

新增 `UserInfoPreferencesModel` 的显式 `model=user_info` 入口，覆盖 `artist`、`lyrics`、`music`、`copyright`、`instructions` 和 `tab` 六个字段。专项已区分默认资讯与当前文档的 `gp_edit_metadata`，用 Unicode/空白安全的文本值核对 `gp_new` 新曲谱继承、读回和恢复；设置失败会恢复旧值。

### P10.4 音频与 MIDI 基础设置

沿用 `gp_audio_device` 的应用级无撤销语义，补齐 `audioOutputChannels` 的宿主 choices 和设置后的读回。状态同时返回 `property_types`；保留播放中拒绝、设备变更失败恢复和音频层运行状态检查。设备 choices 必须来自当前宿主，无法读出合法声道时不提供猜测值。

在同一 Qt 模型路径上调查并加入 `gp_preferences model=midi` 的 `midiInput`、`selectedMidiOutputs` 和 `midiCaptureSensitivity`。协议支持 `QStringList` 输出列表，灵敏度只有在宿主提供可读写属性时才开放；模型不可见时返回 `host_limited`，不增加独立转接服务或猜测设备列表。

每路 MIDI 输出延迟、通道检测单选项、音频装置齿轮以及“检查/测试”按钮目前没有稳定的模型字段或终态路径，不属于 P10 基础写入范围；在确认宿主 setter、读回和持久化前标记为宿主受限或待调查。

### P10.5 API、回归与完成门槛

- `gp_preferences` 继续使用显式模型和属性 allowlist，state 返回实际值及 `property_info` 的 choices/type 信息；枚举、数值、布尔、字符串和字符串列表分别校验，错误输入不得改变设置。
- 应用偏好不进入曲谱撤销栈，但必须验证设置失败恢复、Qt 主线程顺序、多个文档不受错误目标影响，以及配置不写入源码目录。
- `test/test-p10.ps1` 覆盖一般/界面/我的资讯/音频/MIDI 的读取、allowlist 拒绝、同值设置和读回、音频 choices、乐谱错误五项、跨宿主重启持久化和新建曲谱默认资讯继承；缺失模型仍按 `host_limited` 记录。
- 只在 `native/supported-host.json` 已核验的 Guitar Pro 8.1.1.17 上启用；新宿主构建必须单独记录模型属性、枚举、行为和回归证据。没有实际模型读回和持久化证据时，P10 保持“计划中”或按项标记为“宿主受限”。

### P10.6 当前实现证据

`test/test-p10.ps1 -SessionFile <session.json> -VerifyRestart` 在 Guitar Pro 8.1.1.17 上通过 98 项：五类模型均可访问，实际可写字段完成同值读回，显式 allowlist 和错误输入拒绝、音频输出通道 choices、MIDI 输出列表/采集灵敏度、五项乐谱错误开关、`forceNotation` 跨宿主重启持久化，以及 `user_info.tab` 到新建曲谱 `Tabber` 的默认继承。具名证据为 `artifacts/native-p10-89b706d861a941659cc7b1806098b3c5/verification.json`，其中 `complete=true`；同一构建插件 SHA-256 为 `B5DB3991C4BCA16F5C76134F1F730D23310B5DE6FBA541B8C44FDCCE7EF85FA7`。更新/Beta、每路 MIDI 延迟、通道检测和驱动控制面板仍按宿主受限或待调查保留。

### P10.7 RSE EffectsChain 与 IAudioBuffer 边界

`gp_audio_abi` 是开发者可调用的原生边界入口。`state` 生成不含地址的 UUID 句柄，并把 `Musician::coreTrack()` 与当前文档 `Score::tracks()` 逐项比对；`resolve` 和 `buffer_probe` 每次重新验证对象链，文档重开、音轨结构变化、声音替换和宿主重启后旧句柄均必须重新读取。`buffer_probe` 在 `GPMCP_DEVELOPMENT=1` 下构造真实 `AMAudio::AudioBuffer`，核对 `IAudioBuffer` 交错数据、锁/解锁和 `EffectsChain::processDSP`，不把 HTTP 线程接入实时音频回调。

当前 8.1.1.17 隔离宿主的 `test/test-audio-abi.ps1 -RequireProbe` 已通过 20 项，连续 3 次验证 2 声道 64 帧写读和 DSP 边界；证据为 `artifacts/native-audio-abi-18ddea72de4e45f19b1234c6f84241be/verification.json`。最小/Steel Guitar 夹具的 `Conductor::Sound` 尚未产生可观察 `EffectsChain`，故 `chain_mapping_status=host_limited` 会被记录而不被猜测为成功。需要强制实时链证据时，用构造了 RSE Sound 的曲谱运行同一脚本并加 `-RequireBoundChain`；在该专项通过前，产品接口只承诺 `track_binding_status=verified` 和转换链的验收路径。

## P11：界面截图与窗口状态采集

状态：已实现最小 Qt 离屏路径，实验性。提供 `gp_screenshot` 让 MCP 客户端读取 Guitar Pro 当前窗口的可视状态；调用在 Qt 主线程执行，不激活窗口、不抢焦点、不发送输入事件，也不依赖外部常驻服务。截图范围是 Guitar Pro 窗口及其当前活动模态对话框，不包含整个桌面。真实宿主全矩阵尚未完成，不能把实验性结果写成完整验收。

### P11.1 协议与返回

- 扩展当前 `tools/call` 结果，使截图以标准 MCP `image` content（PNG）返回，同时保留结构化元数据：目标窗口、`capture_mode`、尺寸、DPI、是否存在活动模态对话框和采集时间。
- 先限制尺寸、编码耗时和响应体积，再决定是否需要分辨率参数；不得把截图写入源码目录、日志或凭据目录。
- `gp_screenshot` 必须绑定当前 MCP 实例身份，不能跨 Guitar Pro 进程或跨窗口猜测目标。

### P11.2 窗口定位与采集路径

- 通过已登记的 Qt 顶层窗口、`QWindow`/`QWidget` 关系和活动模态链定位主窗口及对话框；不以标题文字、鼠标位置或前台窗口作为唯一身份。
- 正常和后台状态优先验证 Qt 窗口渲染；被遮挡和最小化状态必须调查 `QWidget::render`、Qt 窗口抓取及 Windows 窗口渲染路径，选择实际读回稳定的方案。
- 最小化或被遮挡时不能把桌面合成像素当作可靠来源；返回的 `capture_mode` 必须明确是窗口像素还是宿主离屏渲染。若离屏结果与当前 UI 无法证明等价，返回 `status=host_limited`。
- P11 的无参数调用优先捕获实际阻塞用户操作的活动模态对话框，并与 `gp_dialogs` 的消息、按钮和模态状态交叉核对；对话框不存在时才捕获主窗口。P12 的显式窗口选择另见下文。

### P11.3 验收矩阵与交付物

- 在 Guitar Pro 8.1.1.17 的已核验宿主上分别验证：前台、后台但未最小化、被其他窗口遮挡、最小化、普通文档、未保存文档、保存/打开/错误模态对话框、无文档和多文档。
- 每种状态核对截图非空、窗口边界和 DPI、模态文本/按钮、`gp_documents`/`gp_dialogs` 状态、焦点未被改变，以及宿主仍可继续编辑；同时验证截图失败时不会影响普通 Guitar Pro 使用。
- 已交付 `gp_screenshot` 工具注册、MCP image 响应、API/README 说明和 PowerShell 专项脚本；当前最小专项覆盖正常、隐藏、最小化、关闭确认模态对话框和焦点保持，见 [P11 最小专项](COVERAGE.md#p11-最小专项)。其他模态类型、遮挡、多文档及无文档矩阵仍需补验，因此能力标记为“实验性”，失败状态使用“宿主受限”。

## P12：多窗口枚举与指定窗口截图

状态：已实现，核心真实宿主专项已通过（2026-09-10）。`gp_windows` 与 `gp_screenshot(window_id)` 已交付；截图继续使用 `experimental` 状态。目标及范围唯一见 [AGENTS.md 的 P12 范围约定](../AGENTS.md#p12-范围约定)，完整字段、限制和错误语义见 [窗口 API](../native/API.md#窗口截图)，具名证据见 [P12 验收](COVERAGE.md#p12-验收)。

### P12.1 窗口枚举与身份

已在 Guitar Pro 8.1.1.17 隔离宿主盘点窗口。实际可同时存在主窗口、虚拟键盘、虚拟指板、非模态偏好对话框和关闭确认模态；此外有大量已构造但隐藏的菜单、工具提示和弹出窗口。Qt 桌面代理及普通嵌入式控件不计入；不同工作区的实际数量随已构造对象变化，不固定为某个数字。

`WindowCapture` 用实例 UUID、递增序号和 `QPointer` 保存窗口身份，独立于 `gp_objects/gp_actions` 快照。发现过程结合顶层 QWidget、实际 `Qt::SubWindow` 和已有 QWindow，对 QWidget 的 QWindow 去重。枚举默认包含隐藏窗口，过滤只作用于列表；父关系和状态取自 Qt。上限和不完整统计由 API 明确返回，不创建 HWND。

### P12.2 按 ID 截图

已复用 P11 的 Qt 绘制、PNG 编码和 MCP image 响应。无参数保持活动模态优先，否则主窗口；显式 ID 仅指向该对象，返回该目标的实际状态及另一个字段 `active_modal_window_id`。模态和原生操作等待期间均可只读调用，失效/格式错误/跨实例 ID 拒绝且无图像。

真实验证发现 Qt 5.15 的 `render()` 会派发其他隐藏窗口的待处理几何事件，还会初始化未布局的隐藏菜单。实现以局部 Qt 标志保护在绘制期间保留待处理 move/resize 事件，结束后恢复；未准备好的隐藏目标直接 `host_limited`，不显示、调整或初始化它来帮助截图。Qt 夹具验证待处理事件仍在正常显示时到达。只有 QWindow、GPU/原生嵌入内容及会包含其他独立 SubWindow 的路径明确受限。

### P12.3 专项验收矩阵

`test/test-p12.ps1` 使用 `.tools` 隔离宿主与 `artifacts` 测试文档；`test/test-p12-windows.ps1` 验证 Qt 机制，不能替代真实宿主窗口证据。`test/test-instances.ps1` 复用既有启动/退出流程验证重连和重启后的窗口 ID。矩阵中的剩余项不计为通过。

| 场景 | 本次核验与边界 |
| --- | --- |
| 数量与状态 | 已验证主窗口及两个同时显示的浮动窗口、默认/隐藏过滤、唯一 ID、父子与模态关系、关闭隐藏及重新显示；无文档和多文档下按 Qt 对象计数，曲谱标签不增加窗口记录 |
| 任意选取 | 已验证主窗口、关闭确认、非模态 PreferencesDialog、VirtualKeyboardDockWidget、VirtualFretboardDockWidget，PNG 尺寸及可辨识内容对应目标；Qt::SubWindow 指定截图与 QWindow-only 拒绝由夹具验证，真实宿主未观察到这两类目标 |
| 模态并存 | 已验证原生关闭请求等待中，主窗口、两个浮动窗口、偏好对话框和活动模态可按 ID 选择；无参数仍选模态。下层模态选择通过 Qt 夹具，真实宿主多层模态尚未构造，不计通过 |
| 后台与显示状态 | 已验证正常、隐藏、最小化、最大化、模态遮挡及当前宿主 96 DPI；核对实际图像内容和逻辑/PNG 尺寸。Qt 夹具另验 1.0/1.5 缩放，其他真实显示器/DPI 配置未验收 |
| 生命周期与隔离 | 已验证双客户端交错读取、独立查询快照、标题变化、隐藏/显示、模态销毁及旧 ID 无图像拒绝；同名窗口由不同对象 ID 区分，Qt 夹具验证同地址重建和格式边界，实例专项验证重连及宿主重启后的失效。独立 GUI 同时多进程沿用 P2 宿主限制 |
| 只读性与恢复 | 每次截图保留前后证据，比较前台 HWND/PID、所有窗口几何/显示/活动/模态状态、活动文档、dirty、光标及撤销/重做；核对原文件字节，并验证宿主仍可编辑、撤销重做、保存重开 |
| 失败与资源 | 真实隐藏菜单在绘制前受限，未调整窗口或返回裁切图；20 次重复截图后资源无增长。Qt 夹具验证零/超限尺寸、GPU/QWindow、512 窗口截断及销毁；真实分配/编码故障、8 MiB 响应上限和绘制卡死未注入，不计通过，2000 ms 仍仅为返回后检查 |

证据保存在忽略目录 `artifacts/native-p12-*/`，包含枚举、PNG、截图元数据、前后状态、矩阵、源码/插件/宿主哈希和 `verification.json`。纯系统原生、外部驱动窗口、未构造的弹出窗口及特殊渲染组合仍不承诺可枚举或可渲染，按 [P12 范围约定](../AGENTS.md#p12-范围约定) 保留边界。

### P12.4 交付核对

| 顺序 | 交付物 | 结果 |
| --- | --- | --- |
| 1 | 实际窗口盘点、`gp_windows`、生命周期身份 | 已完成；真实宿主读回与 Qt 夹具分别留证 |
| 2 | `gp_screenshot(window_id)`、默认兼容与错误拒绝 | 已完成；模态存在时显式目标保持，未准备窗口明确受限 |
| 3 | P12、P11、会话/模态及完整原生回归 | 实际运行结果及构建哈希统一记录于 [P12 验收](COVERAGE.md#p12-验收) |
| 4 | API、覆盖清单、用户/开发说明及阶段状态 | 已更新；当前目标继续仅在 AGENTS 维护 |

C++/Qt 构建、PowerShell 语法和 `git diff --check` 与上述专项一起执行。完整回归包括既有会话/模态、P11 和 P12；未穷举的宿主矩阵不因完整回归通过而自动计为已验证。

## P13：音频 Provider 与多插件接口设计计划

状态：已完成最小进程内 Provider 契约与 MCP 适配。`audioControllers`、`enumerateAudioBindingsV1`、`gpmcp_audio_bridge_version`、`gpmcp_audio_bridge_get_info` 和 `gpmcp_audio_enumerate_v1` 已实现并通过源码构建；独立原生消费者在真实宿主中核对效果链绑定、加载顺序与生命周期。Provider 只交付绑定快照；未就绪音轨和无可观察 Conductor 的非活动文档保持 `host_limited`，PCM 获取未实现。P13 服从 [AGENTS.md](../AGENTS.md) 的进程内运行约束，MCP 工具、字段和数据模型可以在提高版本并提供迁移说明后调整。

### P13.1 能力归属与协议设计

- 宿主音频发现、ABI 校验、文档/音轨/声音/效果链绑定和生命周期属于进程内 Audio Provider。Provider 可以先由 MCP 插件承载，也可以迁移到独立原生插件或由其他插件承载；MCP 只是其中一个协议适配器。
- 同一实时宿主对象图必须有明确的权威 Provider。MCP、VST3 和其他插件通过 Provider 接口消费结果，不复制第二套 `Score`、`Track`、`Musician`、`Sound` 或 `EffectsChain` 解析。
- 现有 `gp_audio_abi` 作为行为和验收基线，但不再限制目标设计。若 Provider 需要新的对象模型、参数或状态语义，可以调整现有工具或引入带主版本的新工具；不得在同一版本中静默改变字段含义。
- 每次 MCP 协议调整都必须明确协议版本、迁移说明、请求/响应样例和失败降级路径。Provider 不可用、版本不匹配、宿主哈希未核验或对象暂不可观察时，MCP 必须返回明确的稳定失败状态，普通 Guitar Pro 仍可用。内部 Provider ABI 版本与 MCP 协议版本分开管理。

v1 的最小协商示例：

```text
gpmcp_audio_bridge_get_info({struct_size: sizeof(gpmcp_audio_bridge_info)})
  -> {abi_version: 1, status: ready|not_ready|host_limited, generation, capabilities, host_build_sha256}
gpmcp_audio_enumerate_v1(1, visitor, user, result)
  -> result {status: ok|not_ready|host_limited|abi_mismatch|wrong_thread, generation, count}
```

请求方遇到 `abi_mismatch` 时不得继续读取 v1 字段；遇到 `not_ready`/`host_limited` 时保留宿主正常运行并等待下一次显式发现。新增不兼容字段提高 ABI 主版本，MCP 工具继续沿用现有 JSON 语义并在工具描述中声明迁移版本。

### P13.2 Provider 抽象与对象解析

- 把当前音频发现和绑定逻辑从 MCP HTTP 分发中抽出，形成独立 Provider 内核；保留 MCP 适配层和其他插件适配层。
- 对多个 `ConductorController` 建立确定性选择顺序，记录选中的控制器和曲谱身份；每次绑定都重新核对 `Score -> Track -> Musician -> Sound -> EffectsChain` 的对象归属。
- 修复句柄复用时的旧 `Musician` 指针，清理关闭文档、曲谱替换和音轨结构变化后的过期句柄，并使用文档/曲谱 `generation` 拒绝旧绑定。
- 把发现快照与 `updateAll()`、DSP 调用分开；枚举接口只产生经过验证的快照，不因读取请求隐式改变宿主状态。活动文档不可确认时返回未知语义，不把所有文档标成活动。

### P13.3 内部 ABI、线程与生命周期

- 提供独立的 `audio_bridge_api.h`，定义 ABI 版本、结构体大小、调用约定、宿主文件哈希、能力列表、状态码和 `generation`。Provider 版本不通过 MCP JSON 猜测。
- 明确回调中的字符串和对象指针只在回调期间有效；消费者必须复制元数据，不能把 `EffectsChain*` 保存到宿主重建后的其他线程继续使用。需要跨线程或长期使用时，改为带代数的快照/受控句柄。
- `enumerate`、`resolve` 和注册表操作只能在 Qt/控制线程执行。VST3 `process()` 等实时线程只读取消费者自己的不可变缓存，不调用 Qt、MCP、对象发现或 `updateAll()`。
- Provider 缺失、加载顺序变化、卸载、宿主退出和 ABI 不匹配都必须可安全返回；不得阻塞 Guitar Pro 正常启动、编辑、播放或退出。

### P13.4 消费者与加载顺序

- 先编写独立 native probe，验证 `GetModuleHandle`/`GetProcAddress`、版本协商、线程拒绝、回调数据和 Provider 缺失路径；再接入真实 VST3 或其他插件。
- MCP 适配器把 Provider 结果映射为当前选定版本的 MCP 工具；其他插件只消费同一内部 ABI。加载方不得依赖 MCP HTTP 会话或客户端令牌。
- 如果 Provider 尚未加载，消费者采用有限重试和明确的 `not_ready`/`host_limited` 状态；不创建第二个 Provider，也不静默切换到其他曲谱或实例。

### P13.5 音频获取的后续边界

- `enumerateAudioBindingsV1` 只解决对象绑定，不等同于音频获取。`buffer_probe` 继续作为开发验收边界；它使用测试 buffer 和 `processDSP`，不代表正在播放的实际 PCM。
- 若产品需要曲谱离线音频，另行设计有时长/大小上限的渲染接口，复用已验证的 `AudioExportManager` 路径；可以新增工具或调整现有工具，但必须使用明确的协议版本和迁移说明。
- 若产品需要实时播放 PCM，另行验证宿主输出 tap、采样率/声道/时间戳、无锁环形缓冲区、丢帧统计、开始/停止和文档切换。系统扬声器或 Windows 混音采集不属于当前进程内 Provider 范围。

### P13.6 举一反三的能力层模式

P13 只建立可复用的 Provider 规则，不创建一个大而杂的总接口。后续领域按独立 ABI 拆分：

- `AudioBinding`：音轨、声音、效果链和音频状态；
- `PlaybackTransport`：播放头、速度、循环和播放状态；
- `MidiBinding`：MIDI 设备、输出和采集状态；
- `AutomationBinding`：音量、声像和自动化点；
- `WindowBinding`：窗口身份、状态和截图目标。

每个领域都必须具备宿主哈希校验、对象身份、generation、线程规则、错误状态和消费者失效处理；领域之间不共享未经验证的宿主裸指针。

### P13.7 交付与验收顺序

1. 定义目标 MCP/Provider 请求、响应和版本迁移方案，增加新契约测试；已完成 `audio_bridge_api.h` v1、版本协商和失败状态。
2. 完成 Provider 抽象、确定性解析、句柄清理和线程/生命周期契约；已完成控制器排序、generation 失效和宿主退出清理。
3. 通过 Provider probe 和加载顺序测试，再接入一个真实插件消费者；已完成独立 native probe、缺失 Provider 路径及 `audio-bridge-consumer.cpp` 原生 Qt 插件；两种加载顺序和真实导出回调通过专项，VST3 消费者未实现。
4. 在 Guitar Pro 8.1.1.17 上验证多控制器、曲谱重建、音色替换、关闭重开、Save As、宿主重启和多文档隔离；已验证音轨复制、撤销重做、关闭重开、Save As、重启和多文档切换；未构造的多控制器并存和全部音色重建组合保留为未验证。
5. 若确认需要 PCM 获取，单独完成离线渲染或实时输出 tap 专项，不把桥接枚举证据写成音频采集完成；
6. 更新 `native/API.md`、`native/README.md`、`docs/COVERAGE.md`、安装/打包脚本和回归入口，执行 C++/Qt 构建、`git diff --check`、专项测试及完整原生回归。

P13 最小契约与原生消费者接入已完成：`test/test-audio-provider-host.ps1` 在 Guitar Pro 8.1.1.17 通过 213 项，证据为 `artifacts/native-audio-provider-30b630ada0de439e97fe857cf3b32d5d/verification.json`。独立 fixture/缺失 Provider 检查通过 2 项，不能替代真实宿主结果。版本、发布包和完整回归记录见 [覆盖清单](COVERAGE.md#p13-provider-abi)；VST3、实时 PCM 和系统混音未实现，未构造的多控制器组合不计为已验证。

## 历史记录

旧版阶段快照、历史验收口径和逐次执行日志已移至 [开发计划历史归档](archive/DEVELOPMENT_HISTORY.md)。归档中的状态和数字只用于追溯，不能覆盖本文件的阶段总览或当前 P9/P10 结论。
