# 原生 MCP API 参考

构建、加载、ABI 和测试入口见 [原生插件开发](README.md)。当前目标和范围见 [AGENTS.md](../AGENTS.md)，验收证据见 [覆盖清单](../docs/COVERAGE.md)。

| 内容 | 入口 |
| --- | --- |
| 连接与调用 | [协议边界](#协议边界)、[工具目录与调用示例](#使用原生曲谱工具) |
| 曲谱编辑 | [选区](#原生选区)、[连音](#原生连音)、[连奏与延音线](#连奏与延音线)、[剪贴板](#原生剪贴板)、[音符技法](#音符技法)、[小节记谱](#小节记谱) |
| 文档、播放和窗口 | [文档生命周期](#原生播放与文档生命周期)、[播放与音频](#播放与音频)、[窗口截图](#窗口截图)、[Qt 对象工具](#qt-对象工具) |
| 文件与编曲 | [文件与工作区](#p6-文件与工作区)、[P8 JSON、和弦和歌词](P8.md) |
## 协议边界

- MCP 协议版本：`2025-06-18`；不再宣称支持旧版原始 TCP 或 stdio 转接协议。
- `POST /mcp`：初始化、通知、`ping`、`tools/list` 和 `tools/call`。
- `DELETE /mcp`：结束客户端会话，不关闭 Guitar Pro。
- `GET /mcp`：返回 405；当前不提供主动 SSE 通知流。
- 支持有长度的请求体及分块传输，每个 TCP 连接处理一次请求后关闭。
- 请求体最多 1 MiB，请求头最多 16 KiB。单连接超时为 10 秒；会话上限 32 个，空闲约 30 分钟后清理。
- 校验访问令牌、Host、Origin、会话、协商版本、必填参数、未知参数和基本 JSON 类型。工具调用在 Qt 主线程中执行，并拒绝嵌套的原生操作请求。

本地配置位于 `.cache/mcp-client.json`。该文件包含访问令牌，已经被 Git 忽略。服务描述文件 `.cache/native-session.json` 不含令牌。

## 使用原生曲谱工具

本文件维护 MCP 工具目录、参数和原生行为；P8 JSON 字段和批量编曲格式见 [P8 编曲与语义 JSON](P8.md)。

下面的 PowerShell 仅作为开发客户端；产品 MCP 服务器本身是 C++ DLL。

```powershell
. ./native/mcp-client.ps1
$connection = New-McpSession
try {
    Invoke-McpTool $connection gp_capabilities
    Invoke-McpTool $connection gp_documents
    Invoke-McpTool $connection gp_score
    Invoke-McpTool $connection gp_read_bars @{track=0; staff=0; bar=0; count=2}
} finally {
    Close-McpSession $connection
}
```

曲谱工具的可选 `document` 参数使用 `gp_documents` 返回的独立 UUID，保存在该原生文档对象的动态属性中，不修改宿主控件名称。只有一个文档时可以省略；存在多个文档时必须指定。ID 在文档生命周期内稳定，关闭重开及宿主重启后失效，不能使用 `GPDocumentView_0` 等可复用的控件名称定位曲谱。

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `gp_templates` / `gp_new` | 无 / `template` | 枚举内置模板；新建返回请求 ID，通过 `gp_documents.creation` 读回完成状态 |
| `gp_open` | `path` | 绝对路径的已有 `.gp` 文件；通过 `QFileOpenEvent` 异步打开，已有文档返回 `already_open` |
| `gp_close` | `document`, `unsaved?`, `path?`, `overwrite?` | 明确保存、丢弃或取消后关闭；默认拒绝未保存修改；返回请求 ID |
| `gp_operation` | `request` | 返回 `operation` 状态，查询当前文档操作、P8 编辑及最近 64 条被替换的请求记录 |
| `gp_cancel` | `request` | 取消未调度的操作或识别到的原生对话框；返回 `cancelling` 时须继续确认结果 |
| `gp_recover` | `request` | 重试 `recovery_available=true` 的标签回滚、保存状态恢复或新建模板路径复原；P8 未知提交只观察模型，不重放编辑；文档集合变化时只核验当前映射 |
| `gp_activate` | `document` | 调用原生 `activateNextDocumentView` 导航至目标，并读回文档管理器确认 |
| `gp_score` | `document?` | 读取元数据、音轨摘要、光标、未保存和撤销重做状态 |
| `gp_read_bars` | `document?`, `track?=0`, `staff?=0`, `bar?=0`, `count?=1`, `include_dynamic?`, `include_clef?`, `include_stem?` | 每次读取 1–16 个完整存在的小节，音符包括 `effects`；`include_dynamic=true` 额外返回节拍 `dynamic`/`dynamic_value`，`include_clef=true` 额外返回小节 `clef`，`include_stem=true` 额外返回节拍 `stem`（符干方向和用户方向标志）；默认结构不变 |
| `gp_read_master_bars` | `document?`, `bar?=0`, `count?=1` | 每次读取 1–128 个全曲共享小节的拍号、实音调号、反复和小节线状态 |
| `gp_edit_measure` | `document?`, `operation` 及对应参数 | 修改光标所在的单个全曲共享小节；`clef` 支持 `G2`、`F4`、`C3`，其他参数见下表；支持原生撤销 |
| `gp_edit_metadata` | `document?`, `property`, `value` | 属性名使用 `gp_score.metadata` 的原始键，例如 `Title`；值最长 16384 个 UTF-16 代码单元 |
| `gp_edit_tempo` | `document?`, `value`, `unit?`, `label?` | 修改初始速度，`value` 为 1–400 的整数，省略单位或标记时保留原值 |
| `gp_automation` | `document?`, `operation`, `track?`, `parameter?`, `bar?`, `position?`, `value?`, `linear?`, `text?` | `types/state` 读取宿主音轨自动化；`set/remove` 仅对 `DSPParam_00..DSPParam_31` 提供实验性曲线写入，提交时保留同轨道其他自动化及旁路状态，参数语义和播放影响尚未完成宿主专项验证 |
| `gp_edit_track` | `document?`, `track`, `property`, `value` | 修改 `name`、`short_name`、`color`、`volume`、`pan`、`playback_state` 或记谱 `transposition` |
| `gp_edit_tuning` | `document?`, `track`, `staff?`, `tuning?`, `capo?`, `partial_capo?`, `partial_capo_strings?`, `preserve_pitch?` | 修改弦乐谱表的调弦、变调夹及部分变调夹，支持撤销 |
| `gp_transpose` | `document?`, `semitones`, `scope?=cursor` | 光标单拍或明确选区的实音移调，范围为 -24..24 半音；拒绝打击乐 |
| `gp_edit_tracks` | `document?`, `operation`, `track`, `other?` | `duplicate` 复制到源轨之后，`remove` 删除，`swap` 与 `other` 交换 |
| `gp_insert_track` | `document?`, `source_document?`, `source_track`, `index?`, `copy_content?=false` | 基于现有音轨配置新增，源文档默认目标文档，插入位置默认末尾 |
| `gp_cursor` | `document?`, `axis`, `index` | `axis` 为 `track`、`staff`、`bar`、`voice` 或 `beat`；每次修改一个索引；声部 0–3 |
| `gp_selection` | `document?`, `operation?=state`, `base?`, `extent?`, `note_index?`, `all_voices?`, `all_tracks?`, `tracks?`, `staves?`, `voices?` | 读取、构造并提交原生选区；三个索引数组只用于 `beats` 筛选 |
| `gp_set_fret` | `document?`, `string`, `fret` | 修改当前光标节拍中指定弦的已有音符；品位 0–36 |
| `gp_edit_note` | `document?`, `operation`, `string?`, `fret?`, `midi?` | 弦乐用弦号和品位；键盘和打击乐用 MIDI 0..127，不能混用两套定位参数；`set` 新增、`remove` 删除 |
| `gp_edit_note_effect` | `document?`, `string?`, `note_index?`, `property`, `value` | 用弦号或 `notes` 数组下标选择已有单音，支持原生撤销；取值见下表 |
| `gp_edit_beat_effect` | `document?`, `property`, `value` | 修改当前单拍的装饰音、扫拨方向、渐强弱、轮指等技法，支持撤销 |
| `gp_edit_beat` | `document?`, `operation`, `denominator?`, `dots?`, `text?`, `dynamic?`, `orientation?`, `scope?=cursor`, `level?`, `actual?`, `normal?`, `enabled?` | `insert` 插入休止拍，`rhythm` 设置基础时值，`dots` 设置附点，`tuplet` 设置连音，`text` 设置节拍文本，`dynamic` 设置 `PPP`–`FFF` 力度标记，`stem` 设置 `Upward`/`Downward` 或 `auto` 符干方向，`clear` 清空音符，`remove` 删除节拍；`scope=selection` 接受 `rhythm/dots/tuplet/text/dynamic/stem`；力度清除和力度/表情自动化仍未核验 |
| `gp_edit_connection` | `document?`, `kind`, `enabled`, `scope?=cursor`, `string?`, `note_index?` | `legato` 连奏或 `tie` 延音线；光标延音线可用弦号或音符数组索引指定单音；选区支持跨声部、音轨及谱表 |
| `gp_clipboard` | 按操作提供 `document?`, `id?`, `scope?`, `repeat?`, `include_text?`, `track?`, `staff?`, `bar?`, `count?` | 原生独立快照的复制、剪切、读取和粘贴；见原生剪贴板章节 |
| `gp_edit_bars` | `document?`, `operation`, `index`, `count?=1` | `insert` / `remove` 同步增删所有音轨的小节，数量 1–128；曲谱最多 100000 小节 |
| `gp_undo_redo` | `document?`, `operation` | `operation` 为 `undo` 或 `redo`，必须存在相应历史 |
| `gp_save` | `document?`, `path`, `overwrite?` | 调用 `IDocument::saveToFile` 保存 `.gp` 副本，不改变原文档保存路径和未保存状态 |
| `gp_save_as` | `document?`, `path`, `overwrite?` | 保存并校验后更新原生打开/保存路径与通知，采用新文件并同步标签和窗口标题 |
| `gp_save_current` | `document?` | 保存到当前 `.gp` 路径；未命名文档需要先另存为 |
| `gp_create_from_spec` | `template`, `spec` | 从宿主模板批量建谱，返回请求 ID，终态为 `created` |
| `gp_apply_spec` / `gp_import_json` | `document?`, `spec`, `mode?=replace`, `bar?` | 批量应用或导入 `guitarpromcp.p8` v1；支持 `replace/append/insert`，一次原生撤销 |
| `gp_insert_tab` | `document?`, `text`, `track?`, `staff?`, `voice?`, `string?`, `denominator?`, `mode?`, `bar?` | 单弦 riff 如 `0-2-2-r|3-5`；替换指定声部或新增全局小节 |
| `gp_export_json` / `gp_structure` | `document?` | 导出语义规格或统一歌曲结构摘要 |
| `gp_export_tab` | `document?`, `track?`, `staff?`, `bar?`, `count?`, `voice?` | ASCII 六线谱、调弦、声部、时值及不可表示清单 |
| `gp_read_chords` / `gp_read_lyrics` | `document?`, `track?`, `staff?`, `bar?`, `count?`, `voice?` | 读取实际节拍关联的和弦对象或歌词行 |
| `gp_edit_chord` / `gp_edit_lyrics` | `document?`, `track`, `staff`, `bar`, `voice`, `beat`，以及 `chord/operation` 或 `line/text` | 精确定位的符号/和弦图或歌词片段编辑，返回请求 ID |
| `gp_read_sections` / `gp_edit_section` | `document?`，写入另需 `bar`, `name?`, `text?`, `operation?` | 读段落起止；异步设置或移除原生段落起点 |
| `gp_presentation` 的页面元数据 | `document?`, `operation=set`, `page_metadata` | 标题、作者、作曲者、版权、页眉页脚和页码，异步整组提交及一次撤销 |
| `gp_p9_status` | 无 | 读取 P9 能力矩阵及“已实现、已验证、实验性、未实现、宿主受限”状态，不改变曲谱 |
| `gp_audio_abi` | `document?`, `operation=state/resolve/buffer_probe`, `track?`, `sound?`, `track_id?`, `chain_id?`, `frames?` | 返回不透明 `track_id`/`chain_id` 及逐次归属核验；开发模式 `buffer_probe` 验证 `AudioBuffer`/`IAudioBuffer` 交错写读、锁和 `EffectsChain::processDSP` |
| `gp_audio_stream` | `operation=state/start/stop/snapshot/read/diagnose/recover`, `document?`, `stream_id?`, `layers?`, `backend?`, `max_frames?`, `max_bytes?` | P14 进程内实时 WASAPI loopback 会话、实际 PCM、快照、有限值/连续性指标、诊断和恢复 |
| `gp_windows` | `include_hidden?` | 只读枚举当前实例 Qt 窗口，返回数量、稳定 `window_id`、父窗口关系和实际状态；默认包含隐藏窗口，过滤不改变统计总数 |
| `gp_screenshot` | `window_id?`, `include_frame?` | 按 `gp_windows` 的 ID 读取单个窗口；省略参数仍优先活动模态，否则主窗口。默认通过 Qt `QWidget::render` 返回客户区；Windows 上传 `include_frame=true` 时额外用同进程 `WM_PRINT(PRF_NONCLIENT)` 补入系统标题栏和边框。无效 ID 拒绝且无图像，无法可靠渲染时返回 `status=host_limited` |

P8/P9 编辑请求通过 `gp_operation` 查询 `applied/unchanged/error`，新建为 `created`；`gp_documents.editing` 提供最近编辑状态。格式、默认值、上限、模板复用及恢复语义见 [P8 编曲与语义 JSON](P8.md)；P9 能力边界和专项证据见 [覆盖清单](../docs/COVERAGE.md#p9-验收)。PowerShell 客户端仅自动等待保存工具，P8/P9 请求需要显式查询终态。

`gp_edit_beat operation=text` 使用 `text` 字段写入当前光标或明确选区内节拍的原生 `Beat::freeText`；空串用于清除，Unicode 和空白按宿主 GPIF 可保存范围保留。请求会逐项读回实际文本并进入宿主撤销栈，支持 `scope=selection` 及 `tracks/staves/voices` 筛选；调用方应检查 `gp_operation`、`gp_score.dirty`，并在保存重开后再次读取。文本操作不接受 rhythm/tuplet 的参数，未核验的布局按钮仍由 `gp_p9_status` 标为宿主受限。

`gp_edit_beat operation=dynamic` 使用 `dynamic` 字段写入当前光标或选区内节拍的原生 `Beat::dynamic`，接受 `PPP`、`PP`、`P`、`MP`、`MF`、`F`、`FF`、`FFF`（大小写不敏感）。选区写入按每个实际节拍提交为一个宏命令，调用方应通过 `gp_read_bars include_dynamic=true` 读回 `dynamic`/`dynamic_value`，再检查撤销和保存重开。当前宿主没有可靠的力度清除写入路径，空值或额外参数会被拒绝；`gp_p9_status` 将清除标为宿主受限。

`gp_edit_beat operation=stem` 使用 `orientation` 字段写入符干方向：`Upward`、`Downward` 或 `auto`（大小写不敏感）。`auto` 调用宿主 `setAutoStemOrientations` 清除用户方向，其他两项调用 `setUserStemOrientations`；光标和选区都支持 `tracks/staves/voices` 筛选并进入原生撤销栈。用 `gp_read_bars include_stem=true` 读取 `stem.drawing`、`stem.concert`、`stem.transposed` 及 `has_user_*` 标志。该接口只修改 GPCore 符干状态，不承诺细粒度符杠、连音括号或页面间距布局。

`gp_automation operation=state` 读取整条音轨的原生自动化点及旁路状态，包含宿主尚未列入公共枚举的类型。`set/remove` 目前只开放 `DSPParam_00..DSPParam_31` 的实验性路径；写入前会保留该音轨的其他自动化和旁路映射，并在读回不一致时拒绝报告成功。参数对应的宿主 UI 语义、力度/表情/音量映射和 PCM 影响尚未核验，因此 `gp_p9_status.track_automation` 保持“实验性”，不能把它当作完整自动化交付。

所有索引从 0 开始。弦索引沿用宿主内部顺序，并不直接等于日常所说的“第一弦”。光标尚未选中音符时，`note_string` 和 `note_midi` 可能为 `-1`。

编辑、光标、撤销重做和另存为工具先激活目标文档，确保宿主更新正确文档的未保存标记；因此会改变软件内的活动文档。光标请求被宿主钳制时返回错误及实际位置，调用方应读回后决定下一步。

切换声部后光标可能没有选中节拍，随后用 `bar` / `beat` 定位。声部超出 0–3、谱表超出当前音轨范围的请求在调用原生函数前拒绝；钢琴下谱表和第二声部的编辑隔离已实测。

原生撤销能够恢复内容，但宿主的未保存标记不一定随之清零。插件如实报告这个状态。`gp_save` 也不会清零该标记；`gp_save_as` 使用宿主真正的保存流程更新状态，不直接伪造 `isDirty=false`。

三个保存工具均异步返回 `{status: "scheduled", request: "..."}`。用 `gp_operation` 轮询同一请求；`saved` 后从 `operation.result` 读取路径、字节数和未保存状态，`error` 时检查错误与恢复字段。`gp_documents.saving` 也包含当前保存请求。目标文档在调度时绑定，执行前再次校验并激活；保存中允许读回及对话框控制，拒绝其他编辑。原生保存抛出 C++ 异常时，在备份仍有效的范围内恢复，并返回 `native_exception=true`；确认恢复后以 `error` 结束，允许后续操作。原生路径或未保存状态恢复未完成，或恢复通知再次抛异常时，返回 `outcome_unknown` 并保留写入阻塞，不能直接重试修改。仅目标文件回写失败且原生状态已恢复时，通过 `file_restored=false` 和 `recovery_path` 报告已知失败，仍可将未保存内容另存到其他路径。

PowerShell 的 `Invoke-McpTool` 默认等待三个保存工具的结果，保持原有脚本读取 `path`、`dirty` 等字段的用法，并附加 `request` 和 `status`。`-NoWait` 返回原始调度结果，适用于主动处理 `gp_dialogs` 或取消的客户端。等待 12 秒仍未完成会抛出含请求 ID 的提示，不自动重试。其他 MCP 客户端必须显式轮询保存请求。`gp_cancel` 可结束本次保存所观察到的原生对话框；仅有“确定”的保存错误提示关闭后仍报告 `error`，不能当作原生保存取消成功。

`gp_save` 和 `gp_save_as` 覆盖已有文件必须设置 `overwrite=true`，所有保存均拒绝覆盖其他已打开文档。复制到自身打开/保存路径会被拒绝，应使用 `gp_save_current`。覆盖前在目标目录创建临时备份，并预检文件可写性；原生保存失败后恢复原文件、打开/保存路径和原本为真的未保存标记，返回 `file_restored`、`opened_path_restored`、`save_path_restored`、`dirty_state_restored`、`dirty_before` 和 `dirty`。失败恢复不会把未保存标记清零。文件或原生状态恢复未完成时，保留已有目标的备份并返回 `recovery_path`；恢复通知异常另有 `recovery_error`，并继续尝试恢复未保存标记。保存后关闭共用该恢复逻辑，失败时保留文档。只有文件、两种路径及未保存状态均已恢复，且没有原生异常或未知结果，保存取消才报告 `cancelled`。不得仅根据 HTTP 成功判断保存成功。

`opened_path` 对应宿主当前 `openedFilePath`，不是不可变的来源记录。另存成功后它和 `save_path` 一同采用新文件，文档 UUID 与撤销历史保持不变；原路径重新打开为独立文档，新路径重复打开返回已有文档。保存副本不改变两种路径。实现沿用宿主 `saveAs` 的顺序：原生保存并校验输出后调用 `setOpenedFilePath`，再发出 `openedFilePathChanged` 和 `filePathChanged`，让宿主更新标签、提示、窗口标题和文档菜单名称。两个路径设置方法本身不会发出这些通知，生产代码通过 Qt 元对象调用，不使用调查时的私有地址。

`test/test-saving.ps1` 的 47 项检查覆盖当前路径保存、显式覆盖、复制和另存为、跨文档保护、锁定目标和缺失目录、GPIF 与原生重开、未命名文档拒绝及临时文件清理，并检查中文文件名、两种路径、标签/提示/窗口/对应菜单名称、旧路径独立打开和新路径复用。菜单名称检查按当前 `Tab_N` 对应的 `OpenedDocumentAction_N` 定位，因为宿主会保留已关闭文档的动作对象；此检查不证明菜单可用性。锁定文件的拒绝发生在原生写入之前，不能代替写入中途失败后的恢复验证。保存后撤销再重做恢复内容，当前宿主仍可能报告未保存；再次保存会恢复其原生已保存状态。

`test/test-save-recovery.ps1` 向独立测试进程加载 `save-fault-probe`，只对随机命名的目标及其宿主备份注入 Windows 部分写入错误、输出损坏、恢复锁定和原生通知 C++ 异常。宿主会先重试备份写入，再尝试直接写目标，因此写入故障持续到当前请求结束。保存后校验测试在观察到原生 `isDirtyChanged(false)` 后破坏输出，验证原文件、路径和未保存标记恢复，以及撤销、重做和再次保存重开。恢复再次异常时保留备份、未保存内容和写入阻塞；`gp_recover` 只重试保留的路径及未保存状态通知，不重新写文件。测试也锁定已恢复的输出文件，确认状态恢复不依赖再次覆盖文件。探针通过独立构建生成，生产安装包不包含它；测试只接受 `.tools` 下的隔离宿主。

```powershell
./test/build-save-fault-probe.ps1
./test/test-save-recovery.ps1 -Exe '<isolated .tools host>/GuitarPro.exe'
```

完整 P2 回归入口为 `test/test-p2.ps1 -HostDirectory '<isolated .tools host>'`，依次构建核心及测试探针，在 PowerShell 7 和 Windows PowerShell 5.1 下执行完整功能回归、保存恢复、晚到的新建/打开结果、标签恢复及文档集合变化、连接身份和 DDE 流程。标准客户端检查使用官方 MCP Inspector 2.5.0 和 Node 22，可用 `-NodeExe C:/path/to/node.exe` 指定测试运行时；测试前可运行 `npm install --prefix .tools/mcp-client --ignore-scripts --no-audit --no-fund @modelcontextprotocol/inspector@2.5.0`。Inspector 只属于开发测试环境，不进入插件或安装包。测试宿主需要正常写入 Guitar Pro 自己的自动备份目录，运行时不能用文件沙箱拒绝该目录的写入。

新建/打开超时表示结果尚未确认；插件继续观察，不自动重放。晚到的原生文档被识别后更新原请求并解除阻塞。`recovery_available=false` 时不能用 `gp_recover` 强制清除未知结果。取消只适用于尚未执行的请求或当前可取消的原生对话框；同步原生调用未处理事件时无法被抢占，实际保存完成优先于取消请求。原生保存进度流程仍需独立证据，不能用取消错误提示框的测试代替。

`gp_score.tracks` 包含名称、简称、乐器类型、播放状态、音量、声像、移调偏移和颜色。`gp_edit_track` 的名称、简称、颜色及播放状态要求字符串；颜色格式为 `#RRGGBB`，播放状态为 `Default` / `Solo` / `Mute`。音量和声像要求数值 `0..1`，声像 `0.5` 居中；这些值不是分贝或百分数。混音设置调用原生 `setTrackChannelStripParameter`，声像参数为 11、音量参数为 12。除播放状态外均支持原生撤销；播放状态返回 `undoable=false`，不会伪造撤销历史。

复制、新增、删除和交换音轨使用宿主结构命令并读回数量和对象顺序，最多支持 1024 条音轨。删除最后一轨会留下零音轨曲谱，可撤销恢复。新增音轨时宿主克隆源配置；默认清空内容并按目标主音轨重建小节，不修改源文档。`copy_content=true` 目前只接受源轨与目标小节数相同的情况。原音轨及克隆的音符数据独立，跨文档钢琴双谱表插入和零轨恢复首条音轨已验证。

### 乐器和音高

乐器配置继续复用 `gp_templates` / `gp_new` 和 `gp_insert_track`，从内置模板或已打开曲谱克隆配置。`gp_score.tracks` 的 `stringed`、`unpitched` 区分弦乐与无固定音高乐器；`staff_details` 返回每个谱表的调弦和变调夹。钢琴的 `staff=0/1` 分别访问上下谱表，各自支持声部 0..3。宿主内部保留的钢琴、打击乐 `string/fret` 字段不是实际琴弦或品位，音符编辑应使用 `midi`，单音技法使用 `note_index`。

打击乐可用音符由 `percussion_notes` 给出，MIDI 输入选择宿主对应的默认演奏法，不支持的 MIDI 会在修改前拒绝。重复设置已有 MIDI 不删除音符。无固定音高乐器的 `accidental` 返回 `null`。`sounding_midi` 包含宿主的调弦、变调夹及泛音计算；它不是弯音或揉弦随时间变化的连续音高曲线。

`gp_edit_tuning` 的调弦数组为 1..12 个 MIDI 音高，按宿主弦序排列，标准吉他为 `[40,45,50,55,59,64]`。两个变调夹值各为 0..24，合计最多 36；部分变调夹的布尔数组长度必须与弦数一致。省略字段保留当前值，`preserve_pitch=true` 为默认值，要求每个现有音符在原弦上仍可用 0..36 品演奏；不自动搜索替代指法。`false` 保留指法并改变实音。删除已占用弦或超出 MIDI 范围时拒绝修改。

`gp_edit_track property=transposition` 设置 -24..24 的记谱偏移，保留音符实音和品位，但宿主可能改变升降号拼写。`gp_transpose` 改变实际音高，弦乐要求当前弦上结果仍在 0..36 品；不自动搜索替代指法。选区沿用 128 小节、20000 拍限制，混入打击乐时整体拒绝。宿主实音移调的撤销快照可能给未写满的声部补齐休止符，调用方应以返回的实际模型为准。

`gp_edit_note` 和默认 `scope=cursor` 的 `gp_edit_beat` 从当前光标创建独立的单拍范围。弦号还会按当前谱表的调弦数量检查。新增音符使用宿主自动升降号拼写，删除最后一个音符后保留该拍为休止。空白占位拍上输入使用宿主的下一次输入时值；插入休止拍后可能仍有占位拍，读取时应以 `placeholder` 区分占位拍和真实节拍。

基础时值的 `denominator` 为 `1, 2, 4, 8, 16, 32, 64, 128`，对应全音符至一百二十八分音符。附点通过独立的 `dots` 操作设置，取值 `0..2`。基础时值修改保留已有附点和连音比例，每个操作使用独立原生命令，可单独撤销。小节时值可能因此不足或超出，不自动重排或补齐。

`insert` 要求 `denominator`，可同时指定 `dots`。小节插入索引允许位于曲谱末尾；删除范围必须全部存在。删除全部小节时，宿主保留一个空小节，撤销可恢复原内容。

`gp_score.cursor.selection` 和 `gp_selection` 返回相同的原生选区状态：`base/extent` 保留选择方向，`lower/upper` 返回排序端点；取消选区时 `extent=null`。`multi_selection` 表示是否明确选择了范围，`multi_voice/multi_track` 表示范围模式。`native_modes` 是宿主原始标志；不能仅凭普通光标保留的模式判断编辑范围。`beats` 是宿主范围计数，跨音轨整小节模式的拍索引为 `-1`，此时拍数可为 0，不代表没有内容，也不是全曲音符总数。

## 原生选区

| `operation` | 参数 | 行为 |
| --- | --- | --- |
| `state` | 无，默认操作 | 读取选区，不切换活动文档 |
| `beats` | 无 | 列出明确选区的真实节拍位置 `beats`、总数 `count` 和 `skipped_placeholders`；只读，受下述范围限制 |
| `range` | `base`, `extent` | 五个索引均必填：`track/staff/bar/voice/beat`；首尾均包含，支持反向选择；两端属于同轨、同谱表、同声部 |
| `note` | `base`, `note_index` | 按 `gp_read_bars` 中 `notes` 数组的下标定位已有单音；不以音高猜测和弦中的音符 |
| `all` | 无 | 选择当前谱表、当前声部的全部内容 |
| `clear` | 无 | 结束多选并停在原 `extent`；清除继承的跨轨/声部模式 |

`range/all` 可指定 `all_voices=true` 扩展全部声部，或 `all_tracks=true` 扩展为所选整小节的全部音轨、谱表及声部。后者不能同时指定 `all_voices=false`。任意部分音轨集合、跨谱表的任意节拍端点、空声部端点和同前小节记号的端点暂未支持；未知字段、非整数、越界或被宿主规范化的端点会被拒绝。

插件本地构造并由宿主析构 8 字节的 `ScoreModelIndex` 和 `ScoreCursor` 值对象，使用原生 `ScoreCursor::copy` 建立独立选区，在副本上调用选择函数、重置残留模式，再通过 `moveToCursorAndNotify` 提交。不会直接修改宿主当前选区的内部存储。通知可能根据谱表线补充光标音符字段，因此单音操作另以原生音符对象核对。

宿主通知还会清理离开的输入位置上的临时占位拍。这类拍为 `placeholder=true`、休止且无音符；实测真实音符和时值不变，但原始内存模型的拍数可能减少。钢琴空谱表和刚输入过音符的第二声部均观察到此行为。保存重开后，空声部也可能重新生成一个占位拍；测试仅接受原本为空的声部增加一个无音符、休止的占位拍，并在 `regenerated_placeholders` 中记录其位置和状态，其他差异均使检查失败。

```powershell
Invoke-McpTool $connection gp_selection @{
    operation='range'
    base=@{track=0;staff=0;bar=0;voice=0;beat=1}
    extent=@{track=0;staff=0;bar=1;voice=0;beat=2}
}
Invoke-McpTool $connection gp_edit_beat @{scope='selection';operation='rhythm';denominator=8}
Invoke-McpTool $connection gp_undo_redo @{operation='undo'}

Invoke-McpTool $connection gp_selection @{operation='all';all_tracks=$true}
Invoke-McpTool $connection gp_selection @{operation='beats'}
Invoke-McpTool $connection gp_edit_beat @{scope='selection';operation='dots';dots=1}
Invoke-McpTool $connection gp_undo_redo @{operation='undo'}
```

批量时值/附点/连音要求存在明确选区，支持单声部、多声部及全部音轨，最多 128 小节和 1024 条音轨。实际扫描的小节区域内最多 20000 拍，包括占位拍及同区域未选中的拍；这是原生遍历前的开销上限。空临时占位拍会跳过，返回 `skipped_placeholders`；只有占位拍时可读回空列表，但不能批量编辑。同前小节记号、不可用模型，以及无法绕过的区间内部占位拍会在编辑前被拒绝。

非跨轨选区使用原生 `flatten::beats(range)` 按音乐时间映射声部。四声部夹具验证：一个四分音符的时间范围可同时选中另一声部的两个八分音符，以及同起点的二分和全音符；选区起点之前开始的长音不会因延续到选区内而被纳入。时值修改会改变音乐时间，所以再次编辑之前应重新读取实际目标，不能假设多声部的目标列表保持不变。

`gp_selection operation=beats` 和 `gp_edit_beat scope=selection` 接受可选的 `tracks`、`staves`、`voices` 非空、无重复索引数组，只筛选本次调用的目标，不改变界面选区，也不影响其他工具。跨轨或跨谱表筛选先建立 `all_tracks=true` 选区；只扩展声部时先用 `all_voices=true`。每条选中音轨必须存在指定谱表，缺失索引或越出原选区会在修改前拒绝。扫描上限仍按完整原选区计算。

批量 `clear` 将选中节拍变为休止并保留时值；`remove` 删除节拍但保留全曲小节结构。两者沿用逐声部原生命令及一次撤销。筛选同样适用于 `rhythm/dots/tuplet`；先以完全相同的筛选调用 `gp_selection beats` 核对目标。音轨集合剪贴板仍按单轨或全轨模式使用，不保存另一套插件选区。

宿主的 `flatten::beats` 和时值命令不会自动展开全部音轨。插件先检查各轨、各谱表的节拍，再构造独立单声部范围，逐一与原生遍历结果核对。涉及多个范围时，使用已验证为 24 字节、8 字节对齐的 `MacroCommandRecorder` 排队，在提交后的析构中执行，产生一条原生撤销记录；单范围直接使用宿主命令。逐拍读回后返回实际 `beats` 和 `affected_beats`，相同目标全部已为请求值时不增加历史。整曲和跨轨固定小节范围已验证重复设置、一次撤销、重做和原生保存重开。

## 原生连音

`gp_edit_beat operation=tuplet` 调用宿主可撤销的 `Score::setBeatTuplet`。比例由两个无符号字节保存，`actual` 和 `normal` 均接受整数 `1..255`：例如 `3:2` 表示三枚音符占用两枚同基础时值音符的时间。`1:1` 不作为启用的连音接受，应使用 `enabled=false` 清除指定层。

`level` 为 `primary`（默认）或 `secondary`，分别对应宿主枚举 0 和 1。两层可独立设置或清除；省略 `enabled` 视为 `true`，清除时不接受 `actual/normal`。修改保留另一层、基础时值、附点、音符和当前选区；两层都启用时，时长比例相乘。单独保留次层也已验证保存重开。

```powershell
Invoke-McpTool $connection gp_edit_beat @{operation='tuplet';scope='selection';actual=3;normal=2}
Invoke-McpTool $connection gp_edit_beat @{operation='tuplet';scope='selection';level='secondary';actual=5;normal=4}
Invoke-McpTool $connection gp_edit_beat @{operation='tuplet';scope='selection';level='secondary';enabled=$false}
```

省略 `scope` 时只修改光标所在一拍，即使界面上另有大选区。`scope=selection` 使用上一节的范围校验和原生宏命令，支持跨小节、声部、全部音轨及钢琴上下谱表。它改变节拍的音乐时间，后续多声部编辑前应重新读取实际选区目标。不会自动补齐、拆分或重新排列小节，也不自动改连音括号和分组排版。

`gp_read_bars` 每拍新增 `tuplets.primary` 和 `tuplets.secondary`，每层包含 `enabled/actual/normal`。没有连音时通常为 `false/0/0`；字段来自宿主 getter，保留原始比例。原有 `rhythm` 字符串继续提供，但客户端无需解析它来读取连音。

`test/test-tuplets.ps1` 的 175 项检查验证十种比例（含 `255:254`、`255:1`、`1:255`）、非法参数、光标与选区隔离、另一层及基础时值/附点保持、重复设置、一次撤销/重做、反向跨小节、跨声部/音轨、钢琴谱表及 GPIF。嵌套与单独次层已保存重开，嵌套连音还通过插件独立缓冲区复制粘贴验证。尚未验证任意比例组合的实际发声、所有分组/括号排版和极端时长的播放行为。

## 连奏与延音线

`gp_edit_connection` 调用宿主的 `Score::setBeatLegato`、`setBeatTied` 和 `setNoteTied`，使用宿主撤销栈。`kind` 为 `legato` 或 `tie`，`enabled` 必须是布尔值。`scope` 默认 `cursor`，即使界面存在更大选区也只以当前拍作为操作位置。

| 模式 | 原生语义 |
| --- | --- |
| `legato`，光标 | 当前拍作为起点，连接下一拍；清除时解除这条连接 |
| `legato`，选区 | 在所选连续节拍之间建立或清除连接，最后一拍作为终点 |
| `tie`，光标，省略 `string` | 从前一拍延续到当前拍；可能复制前一拍的音高、品位和升降号，或补入当前拍缺少的弦音符 |
| `tie`，光标，指定 `string` | 对当前拍指定弦上的已有音符执行延音线命令；可能同步改变该音符的音高，已验证和弦其他音符保持不变 |
| `tie`，选区 | 按宿主规则连接选区内可以匹配的音符，不保证每个音符都能连接；解除延音线保留当时的音高 |

`scope=selection` 要求明确选区，使用既有的音乐时间映射和范围校验。各声部、音轨及谱表使用独立原生范围，多范围通过 `MacroCommandRecorder` 合并为一次撤销。上限为 128 小节、1024 条音轨和被扫描区域内 20000 拍；空占位拍跳过，只有占位拍时拒绝编辑。

```powershell
Invoke-McpTool $connection gp_edit_connection @{kind='legato';enabled=$true;scope='selection'}
Invoke-McpTool $connection gp_edit_connection @{kind='tie';enabled=$true;string=0}
Invoke-McpTool $connection gp_edit_connection @{kind='tie';enabled=$false;string=0}
```

`gp_read_bars` 每拍的 `legato`、每个音符的 `tie` 均含 `origin/destination` 两个布尔值，直接读取宿主 getter。这与音符技法中的 `let_ring` 不同；连音比例仍通过 `tuplets` 表示。

命令返回 `observed_beats`（所选节拍的位置、连奏和音符状态）、`changed_selected_beats`、`requested_enabled` 及 `cursor_preserved`。光标模式的相邻连接端点可能在这份读回列表以外，需用 `gp_read_bars` 查看前后小节。`status=executed` 表示完成调用，并不表示每个音符都具有请求的连接状态；例如曲谱第一拍没有前置音符，延音线可能没有效果。宿主可能为没有模型变化的重复命令保留撤销记录，此工具尚不消除这些记录，不能作为幂等设置接口盲目重试。

单音延音线命令会克隆 `Score::cursor` 并读取其当前音符，仅设置范围中的弦号和音高不足以定位和弦单音。插件在调用期间以原生 `ScoreCursor::selectNote` 及通知方法选中目标，随后恢复原光标和选区；没有鼠标、按键或前台窗口操作。

原有专项验证 153 项：光标与较大选区隔离、正反向跨小节、整拍及和弦单音、音高与升降号更新、缺少弦音符补入、清除、重复命令、撤销重做、跨声部/音轨的一次撤销、钢琴下谱表隔离、GPIF 连接两端及保存重开。P3 结构专项另验证跨两小节八拍连奏/八音延音链、整链移调及弯音组合。装饰音、打击乐与其他技法的全部组合、复杂排版和各音源声学效果未穷举。

## 原生剪贴板

`gp_clipboard` 使用宿主 `SerializedScore` 保存独立曲谱快照。该值对象为 16 字节、8 字节对齐，包含虚表和实现指针，构造及虚析构由宿主完成。快照由 `shared_ptr` 持有；关闭或修改源文档后仍有效，原生粘贴命令可保留自己的引用供撤销重做使用。

| `operation` | 参数 | 行为 |
| --- | --- | --- |
| `state` | 无，默认操作 | 返回 `available`、当前 `id`、来源选区与实际节拍位置、小节/音轨数量、声部/音轨模式及 `tracks[].staves` |
| `clear` | 无 | 清空插件当前缓冲区，使旧 `id` 失效 |
| `copy` / `cut` | `document?` | 从明确选区构造快照；剪切随后调用原生删除命令 |
| `read` | `id`, `track?=0`, `staff?=0`, `bar?=0`, `count?=1` | 分页读取快照，最多 16 小节；索引属于快照，非源文档 |
| `paste` | `id`, `document?`, `scope?=cursor`, `repeat?=1`, `include_text?=false` | `cursor` 插入；`selection` 替换；重复 1..100 次，可包含节拍文本 |

每个插件实例仅保留一个当前快照，所有客户端共享；`read/paste` 必须提供匹配的 `id`，拒绝旧快照请求。`copy/read/state` 不激活源文档，`cut/paste` 在参数和兼容性校验之后才激活目标。复制范围沿用上述选区的 128 小节、1024 音轨和 20000 拍扫描上限；纯占位拍选区不能复制。重复后的片段最多 128 小节、20000 拍（含快照补齐的休止及占位拍），目标总小节数的保守插入上界为 100000；超限在修改前拒绝。

单小节、非多轨片段使用 `Score::pasteBeatRange`。多轨或超过一个小节的片段使用 `Score::pasteBarRange`，`repeat` 直接传入原生命令，整次粘贴可以一次撤销。默认模式为 0；`include_text=true` 仅启用特别粘贴的文本位 2，保留节拍自由文本。`gp_read_bars` 与快照 `read` 的节拍 `text` 可读回。其他特别粘贴过滤项未开放。

插入全曲共享小节时，其他音轨的原内容顺移；复制单轨片段时，其他轨的新小节为空。返回 `native_method`、`previous_bar_count` 和 `global_bar_delta`，应再次读取目标范围确认结果。跨小节或多轨片段以 `scope=selection` 替换时，必须先明确建立 `all_tracks=true` 整小节选区；宿主的部分小节替换会丢失选区末端以后的拍，因此插件在修改前拒绝这种请求，不自动拼接边界内容。

多声部片段要求目标光标处于全部声部模式。可先调用 `gp_selection range`，设置 `all_voices=true`，再以 `scope=cursor` 插入；不要在两次调用之间清除选择模式。原生兼容性检查拒绝不匹配的多轨数量或模式，返回 `native_incompatibility`。插件另拒绝有音高与无固定音高打击乐之间的粘贴，并预检目标打击乐是否有全部 MIDI 演奏法。键盘片段粘到弦乐需指法分配，本次不支持；弦乐来源必须能在目标原弦的 0..36 品保留音高。已验证不同调弦、变调夹及记谱移调的实音保持，未进行自动指法搜索。

快照可能包含宿主自动补齐的休止，故 `beat_count` 是源选区的实际拍数，不是快照的总拍数。实测两个四分音符的选择范围在较短声部末尾补入一个四分休止。钢琴快照保留双谱表，可用 `tracks[].staves` 和 `source_selection` 确定读取位置；下谱表仍用 `staff=1`。跨小节粘贴后，光标所在的最后一拍还可能是新生成的空占位拍。测试分别核对这些新增内容。

普通单声部剪切使用 `Score::removeBeatRange`，多轨剪切使用 `Score::removeBarRange` 删除全曲共享小节。宿主直接删除多声部范围会在撤销记录之外补齐短声部；插件改用已核对的逐声部范围与原生宏命令，保持一次撤销并恢复原始音乐内容。单小节多声部及跨小节剪切已验证边界保留、撤销重做和保存重开。

```powershell
$snapshot = Invoke-McpTool $connection gp_clipboard @{operation='copy';document=$source}
Invoke-McpTool $connection gp_clipboard @{operation='read';id=$snapshot.id;staff=0}
Invoke-McpTool $connection gp_clipboard @{operation='paste';id=$snapshot.id;document=$target}
Invoke-McpTool $connection gp_undo_redo @{operation='undo';document=$target}
```

此缓冲区位于 Guitar Pro 进程内，与 Windows 系统剪贴板独立。宿主剪贴板互通处于以下实验阶段；本次按最小必要范围不增加独立 Windows 用户环境、任意音轨集合剪贴板、其余特别粘贴过滤项或自动指法映射。

### 宿主剪贴板实验

以下 `gp_clipboard` 操作只在启动时设置 `GPMCP_DEVELOPMENT=1` 后开放，**尚未完成验证，默认禁用**。

| 操作 | 参数 | 实验行为 |
| --- | --- | --- |
| `native_state` | 无 | 当前实例的剪贴板所有权、序号、曲谱标记及已验证快照结构 |
| `native_copy` | `document?`, `sequence` | 调用宿主复制函数复制明确选区；覆盖系统剪贴板，保留插件缓冲区 |
| `native_import` | `sequence` | 持有宿主快照的共享引用，放入插件缓冲区并返回新 `id`；后续沿用 `read/paste` |

`sequence` 必须来自最近的 `native_state`。复制不会切换活动文档；导入拒绝其他进程的剪贴板和过期序号。仅有 Windows `app/gp` 格式不代表可读取的乐谱：该格式的数据只是一个空格，实际 `shared_ptr<SerializedScore>` 保存在 `EditFeature::Impl` 中。当前只针对同一 Guitar Pro 实例，不能跨进程传输乐谱。

对象从已有的 `QPointer` 生命周期注册表定位。已核对该构建的 `EditFeature + 0x20 → Impl`、`Impl + 0 → EditFeature` 回指及 `Impl + 0x08` 的共享快照；复制使用 EXE RVA `0x10E690`，动作更新使用 `0x3D60D0`。这些位置受宿主 SHA-256 校验保护，不使用开发扫描中的相邻内存路径。

初步运行已观察到原生复制和快照导入，但隐藏窗口下的菜单复制/粘贴不可用，不能将其视为菜单互通已验证。完整的保存重开、对象替换和跨进程标记拒绝测试仍待完成。

`test/test-system-clipboard.ps1` 仅允许在 `GuitarProMCP-Test-*` 独立 Windows 窗口站执行，并核对宿主的 `gp_capabilities.window_station` 与测试进程一致；普通桌面入口会在接入 MCP 前拒绝运行。项目内隔离启动探针位于 `.tools/run-isolated-clipboard.ps1`，本机 `CreateWindowStation` 返回访问被拒绝，因此尚无该组通过记录。

早期真实桌面测试的剪贴板恢复代码发生过栈溢出，原剪贴板未能确认恢复；后续真实剪贴板测试被自动审批拒绝。该恢复代码已移除，当前测试不再尝试备份或恢复用户桌面剪贴板。失败证据保留在 `artifacts/native-system-clipboard-*/failure.json`，不计入通过数。

## 音符技法

`gp_read_bars` 返回每个音符的 `effects` 对象。下面的属性可由 `gp_edit_note_effect` 修改；同一次请求只设置一项。

| `property` | `value` | 含义 |
| --- | --- | --- |
| `palm_mute` | 布尔值 | 掌根闷音 |
| `let_ring` | 布尔值 | 延音标记 |
| `left_hand_tapping` / `right_hand_tapping` | 布尔值 | 左手或右手点弦 |
| `vibrato` | `None`, `Slight`, `Wide` | 无揉弦、轻揉弦、宽揉弦 |
| `anti_accent` | `None`, `Soft`, `Normal`, `Strong` | 宿主的弱音级别编码 |
| `left_fingering` / `right_fingering` | `None`, `P`, `I`, `M`, `A`, `C`, `Open` | 宿主指法编码；`Open` 为空弦指法标记 |
| `dead` / `hopo` | 布尔值 | 死音、击勾弦起点 |
| `staccato` / `staccatissimo` / `accent` / `heavy_accent` / `tenuto` | 布尔值 | 断奏、极短断奏、重音、强重音、保持音；互斥规则由宿主处理 |
| `ornament` | `None`, `Turn`, `InvertedTurn`, `LowerMordent`, `UpperMordent` | 回音或波音 |
| `trill` | `{enabled:true,midi:42}` 或 `{enabled:false}` | 颤音的另一个音高，使用原生十六分音符速度 |
| `slide` | `{kind,enabled}` 或 `{kind:"None"}` | `Shift`, `Legato`, `OutDownwards`, `OutUpwards`, `InFromBelow`, `InFromAbove`, `OutDownwardsPickScrape`, `OutUpwardsPickScrape` |
| `harmonic` | `{type,fret}` 或 `{type:"None"}` | `Natural`, `Artificial`, `Pinch`, `Tap`, `Semi`, `Feedback`；错误品位返回可选节点 |
| `bend` | `{enabled,origin_value,middle_value,destination_value,origin_offset,middle_offset1,middle_offset2,destination_offset}` | 三个音高值为 0..12 半音，四个位置为有序的 0..1；清除仅传 `{enabled:false}` |

布尔属性用 `false` 清除，枚举属性用 `None` 清除；大小写必须匹配。不接受不存在的音符或休止/占位拍。键盘和打击乐的通用技法可通过 `note_index` 修改；弯音、滑音等弦乐技法拒绝非弦乐音轨，颤音拒绝打击乐。枚举名称由宿主转换函数提供，`Open` 指法标记不会修改已有音符的实际品位。

单音范围从当前拍构造，选择模式为 0，同时设置两个端点的弦号与 MIDI 音高，再通过原生 `ScoreModelIndex::note()` 核对目标对象。只设置弦号不足以定位，音高尚未指定时宿主会返回空对象。局部范围不会改动界面光标或选区；编辑使用宿主可撤销命令，读回目标属性、音高、品位和同拍其他音符。相同值不会重复加入撤销记录。掌根闷音和延音命令关闭了连续命令合并，使每次实际变化可独立撤销。

原有 21 种取值由 `test/test-effects.ps1` 验证，新增技法由 `test/test-notation.ps1` 验证。GPIF 通过主小节、音轨小节、声部、节拍和音符引用定位检查对象，不能把 XML 音符定义数量当作实际发声次数。曲谱状态和持久化检查不代替 P5 的各音源声音效果验收。

`gp_edit_beat_effect` 使用 `grace`、`pick_stroke`、`fade`、`hairpin`、`golpe`、`ottavia`、`rasgueado`、`bar_vibrato`、`bass_attack`、`arpeggio`、`brush` 的原生名称；无效值返回 `choices`。通常以 `None` 清除，`hairpin` 以 `NoHairpin` 清除。琶音和扫弦采用宿主默认演奏时序；不另设时序编辑器。`whammy` 与上表 `bend` 使用相同七点格式，三个音高值范围为 -12..12 半音。`dead_slap` 使用布尔值，`tremolo` 使用 8/16/32/64，0 清除。装饰音转换会改写时值，清除装饰音保留转换后的时值；死拍会清空原音符，清除死拍保留休止。原生撤销可恢复这些内容。

验证空声部时发现：撤销首音输入后，宿主会留下一个无音符的空白占位拍。音符技法测试单独检查这一状态，并重开原始夹具，避免后续检查继承不同的占位拍结构。

## 小节记谱

`gp_read_master_bars` 返回全曲共享的小节状态，与某条音轨内的节拍和音符分开读取。`time_signature` 包含 `numerator` / `denominator`；`key_signature` 包含升降号数量 `accidentals`、大小调标记 `major` 和宿主编码 `native_label`。后者可能为 `M`、`mbbbbbbb` 等，并不是常用调名。其他字段为 `repeat_start`、`repeat_end`、`repeat_count`、`double_bar` 和 `free_time`。

| `gp_edit_measure.operation` | 参数 | 行为 |
| --- | --- | --- |
| `time_signature` | `numerator`, `denominator` | 分子 `1..64`；分母为 `1,2,4,8,16,32,64,128` |
| `key_signature` | `accidentals`, `major` | 升降号数量 `-7..7`，负数为降号；`major=true` 为大调，`false` 为小调 |
| `repeat_start` | `enabled` | 设置反复开始标记 |
| `repeat_end` | `enabled`, `repeat_count?=2` | 开启时次数为 `2..100`；关闭时不接受次数参数 |
| `double_bar` / `free_time` | `enabled` | 设置双小节线或自由拍号 |
| `alternate_endings` | `endings` | 1..8 的不重复数组，空数组清除反复房子 |
| `direction` | `direction`, `enabled` | 使用 `direction_marks` 返回的有效 ID 0..18；同一记号从原小节移动到新小节；清除指定记号保留同小节其他记号，可一次撤销 |

工具先检查操作对应的参数，再通过原生命令修改，并读回所有小节字段。独立的 `ScoreModelRange` 设置 `setMultiSelection(true)`，确保拍号、调号只作用于光标所在小节，阻止宿主自动延伸到后续小节。这里的单小节仍由全曲各音轨共享。

调号使用实音模式。宿主会调整音符的升降号拼写，已验证 MIDI 音高、弦、品位和节奏不变，撤销恢复原拼写。修改拍号也不会自动调整现有节拍时值，小节可能不足或超出。移调乐器和复杂曲谱上的完整记谱行为尚未验证。

关闭反复结束标记或撤销新增标记后，宿主仍可能保留 `repeat_count` 缓存。插件如实返回该值，仅在 `repeat_end=true` 时解释为有效反复次数。反复编辑通过宿主更新播放时间线，更新可能异步完成。

## 原生播放与文档生命周期

`gp_new` 通过 `:/GPBase/MainWindow/Templates/` 中列出的模板创建独立文档，随后调用宿主方法清空打开和保存路径。返回 `scheduled` 不代表成功，必须轮询并匹配 `gp_documents.creation.request`；成功为 `created`。`requested` 和 `cancelling` 是中间状态，必须继续观察。原生调用返回后，未观察到文档且已超过 10 秒时报告 `error`、`outcome_unknown=true`，继续观察迟到结果并阻止新的写入；这不是原生调用的强制截止时间，也不代表已经取消。同一时刻只允许一个待完成请求。模板的文件名保持宿主原始名称。

`gp_open` 返回 `scheduled` 和独立 `request`。通过 `gp_operation` 返回的 `operation` 或 `gp_documents.opening` 核对同一请求的 `opened` 及文档 ID。ZIP/GPIF 校验错误返回 `status=error` 和 `failure_stage=validation`，不会进入原生打开。未观察到结果且超过 10 秒时返回 `error`、`outcome_unknown=true`，继续观察迟到的文档并阻止新的写入；该状态不代表确认失败或取消。迟到的新建/打开结果及新建/打开/关闭后的原生异常已有专项验证；确认完成时报告实际终态，并保留 `native_error`。未观察到结果时不能强制解除阻塞。重复打开已识别路径返回 `already_open`。

`gp_close` 通过 `TabWidgetProxy::tabCloseRequested(int)` 进入宿主关闭流程。执行前激活目标，校验页面与索引，异步回调再次确认对象身份。`unsaved=save` 先通过原生保存更新状态，未命名文档需要 `path`；保存失败保留文档。`discard` 只在本次关闭栈内、目标主窗口所属的保存/丢弃/取消对话框中，按标准按钮枚举选择丢弃。`cancel` 不关闭文档；`prompt` 保留原生对话框，可使用 `gp_cancel` 取消。它不伪造已保存状态，不调用曲谱视图的 `QWidget::close()`，不模拟输入。

新建、打开、保存、关闭一次只允许一个待完成操作，期间允许读回和对话框内操作。当前记录也出现在 `gp_documents` 的 `creation/opening/saving/closing` 中。请求 ID 可通过 `gp_operation` 读取，64 条被替换记录之外的旧 ID 明确报错。取消只针对原请求和观察到的对话框；已完成操作不能取消。`cancelling` 必须继续轮询，若原生操作已经成功，结果仍报告真实成功。新建/打开过程中，只有“确定”按钮的加载错误提示被 `gp_cancel` 关闭后，`cancel_decision_available=false`，最终仍为 `error`，不会误报 `cancelled`。原生标签拖动和保存进度取消列为宿主限制；未穷举的模态及异常组合继续纳入 P7 验证，无可信终态时保持阻塞。

### 文档标签重排

`gp_documents` 在验证宿主标签与页面映射后按标签顺序返回文档，每个文档包含从 0 开始的 `tab_index`。映射不可用时返回 `tab_order_available=false`、`tab_order_error` 和空索引；空文档列表的顺序有效。

`gp_move_document` 必须提供 `document` UUID 与整数 `index`，目标位置为移动后的索引，范围是 `0..文档数-1`。原位置返回 `unchanged`，实际移动返回 `moved`，都包含 `previous_index`、`tab_index`、`undoable=false` 和 `request`。操作同步完成，可在 `gp_operation` 或 `gp_documents.moving` 读取 `kind=move` 的结果，替换后的请求沿用 64 条历史记录。重排保留活动文档、未保存状态和曲谱撤销历史，仅影响当前会话。存在模态窗口或待完成文档操作时拒绝执行。

该版本使用自定义 `am::gui::Tab`、`QBoxLayout` 与 `QStackedWidget`，并非 `QTabBar`。重排前保存全部标签和页面的对象快照，在 Qt 线程内同步排列并屏蔽页面栈的中间信号，再由原生标签通知更新宿主状态。完成校验包含全部标签/页面顺序和活动文档，不能只核对目标索引。

原生通知抛异常或校验失败时，尝试恢复整个原排列；恢复时先同步当前页面对应标签，再选择原活动标签，避免宿主保留的选择索引使激活被跳过。确认恢复后返回 `error`、`rolled_back=true`，允许后续操作；异常另有 `native_exception=true`。回滚再次异常或无法确认时返回 `rolled_back=false`、`outcome_unknown=true`，异常细节在 `recovery_error`，请求保留写入阻塞。`gp_cancel` 不会把已经执行的重排当作可取消操作。

有保留快照时，失败响应及 `gp_operation` 的 `recovery_available=true`。使用 `gp_recover request=...` 重试恢复；它拒绝原生操作尚在执行、存在模态对话框、过期请求及已完成恢复。再次恢复失败保留阻塞和上下文，可在排除故障后继续恢复。成功返回 `status=recovered`，清除当前请求的 `outcome_unknown` 并释放快照，但原请求 `status=error` 和原始 `result` 保持不变；后续结果在 `operation.recovery`，另有 `recovery_attempts` 和 `recovered=true`，归档后仍可查询。

`resolution=rolled_back` 表示完整原顺序和活动文档已恢复。宿主关闭主窗口时会先关闭干净文档，再询问未保存文档，因此取消确认框后可能只剩部分文档。原对象已销毁且剩余标签、页面、相对顺序、文档数量和原生活动文档均可验证时，恢复返回 `resolution=documents_closed`、`closed_documents` 和 `rolled_back=false`；全部原文档关闭也可核验。存在新增文档时返回 `resolution=documents_changed` 和 `added_documents`，不重新打开已关闭的文件。剩余状态无法核验时继续阻塞。保存失败保留的恢复步骤也通过 `gp_recover` 重试，见保存章节。

独立 `test/test-tab-recovery.ps1` 的标准分支执行 391 项检查，覆盖迟到的新建/打开结果、原生新建/打开/关闭完成后的异常、标签回滚及显式恢复、模态拒绝、普通原生动作和属性写入阻塞、过期/重复请求、全部原文档关闭及随后重开。`-CloseCleanDocuments -AddDocumentDuringRecovery` 另覆盖部分原文档关闭后新增文档的核验。保留原有身份、内容、撤销、保存副本、再次移动和历史记录检查。探针只绑定标记测试目录中的文档，不进入生产包。

```powershell
./test/build-tab-fault-probe.ps1
./test/test-tab-recovery.ps1 -Exe '<isolated .tools host>/GuitarPro.exe'
./test/test-tab-recovery.ps1 -Exe '<isolated .tools host>/GuitarPro.exe' -CloseCleanDocuments
```

`test/test-document-tabs.ps1` 的基础 196 项覆盖同名路径、两份同模板未命名文档、四份未保存文档、边界及错误参数、活动文档与 UUID、撤销重做、标签坐标、模态拒绝、保存重开、错位关闭，以及原生关闭确认框存在时恢复窗口后仍可取消。`-VerifyDocumentMenu` 扩展到 281 项，实际触发重排前后及三次隐藏/恢复后的五个文档菜单，逐项核对目标并验证重新隐藏后不占前台。`test/test-all.ps1` 默认启用这一分支，动作未启用或目标不符均失败。

用户确认直接拖动标签后顺序不变。插件重排不视为原生拖动验收；未命名文档另存后的标签和提示由保存路径通知更新，其验证见保存专项。

GPIF 预检使用宿主 `Qt5Gui.dll` 的 `QZipReader` 和 Qt XML 流解析器，并校验精确 DLL 哈希。要求唯一、普通的 `Content/score.gpif`，解压大小最多 64 MiB、根元素为 `GPIF`，拒绝 DTD 和 XML 语法错误。顶层 `GPRevision.required` 必须是非负整数且不超过当前已验证宿主的 13007；`recommended` 不作为拒绝依据。不兼容版本曾使原生打开静默结束并留下未知结果，预检现在明确拒绝。此检查不做文件解压落盘，也不声称完成 GPIF 模型语义验证。保存后的文件通过同一检查，不合格时进入已有恢复流程。

存在多个文档时先 `gp_activate`，然后调用 `gp_playback`。控制器通过 `Conductor::score()` 与目标文档的 `Score` 对象匹配，避免把播放指令发往其他曲谱。

| `gp_playback.operation` | 参数 | 行为 |
| --- | --- | --- |
| `state`，默认 | `document?` | 播放、循环、节拍器、倒计时、tick/frame、总长度和原谱小节数 `score_bar_count` |
| `play` / `stop` | `document?` | 请求播放/停止，需轮询 `state` 确认完成 |
| `seek` | `document?`, `bar`, `tick?=0` | 原曲谱小节索引从 0 开始，tick 为该小节内偏移；按原生小节时值检查边界 |
| `seek_tick` | `document?`, `tick` | 展开反复后的绝对 tick，范围 `0..total_ticks-1`；不接受 `bar` 或 `enabled` |
| `set_loop` / `set_metronome` / `set_countdown` | `document?`, `enabled` | 修改相应开关并返回状态 |

测试使用初始速度 90 和 120 的两份曲谱核对第二小节起点的帧数比为 0.75，并验证播放时间线实际推进、停止后保持不动。P5 扩展见下方“播放与音频”。

两个 4/4 小节的测试曲谱原长为 3840 tick，反复 3 次后为 11520 tick，原谱小节数仍为 2。`seek bar=1,tick=0` 定位到原谱第二小节的首次出现（1920 tick）；第三次的第二小节使用 `seek_tick tick=9600`。最后有效位置为 11519；反复 100 次时为 383999。P3 结构专项另验证六小节曲谱的反复房子展开为 8 小节，反复内插入小节后为 10 小节，嵌套反复为 15 小节，D.C. al Fine 为 8 小节；均核对末尾 tick 定位，并验证实际播放帧推进。

`gp_score.tempo` 读取主音轨的初始速度，字段为 `value`、`unit`、`label`、`quarter_bpm` 和可用单位 `units`，不代表当前播放位置的速度。单位包括 `Eighth`、`Quarter`、`QuarterDotted`、`Half`、`HalfDotted`，等效四分音符 BPM 分别为速度值的 0.5、1、1.5、2、3 倍，使用宿主转换函数计算。

`gp_edit_tempo` 调用 `Score::setTempo`，支持撤销重做。`value` 为以指定单位计数的 1–400 整数；宿主虽然接收浮点参数，实际会截断小数，因此插件预先拒绝。省略 `unit` 或 `label` 时保留当前值，文字使用与元数据相同的字符检查。五种单位的保存值、中文标记、定位帧数以及后续变速点不被覆盖均已实测。

## 播放与音频

`gp_tempo` 的 `state` 返回 `points`；`set` 以 `bar` 和 `position` 定位速度点，`remove` 删除该点。`position` 是原谱小节内比例 `[0,1)`，默认 0；`value` 为 1..400 整数；`unit` 使用 `gp_score.tempo.units`。已有点省略单位、文字或渐变时保留原值，新点默认初始单位、空文字、不渐变。`linear=true` 从该点向下一个速度点渐变；最后一点的渐变没有后续目标。最多 4096 点，初始 `(0,0)` 不可删除。克隆原生自动化后通过 `Score::modifyMasterTrackAutomations` 一次提交，不直接修改活跃指针；支持撤销重做和保存。编辑及撤销后调用原生 `updateTempoManagerAsync`，解决停止时帧数沿用旧值的问题。该宿主 `isUpdatingData` 可能长期为真，返回的 `updating` 只作原始诊断，完成应以预期 tick/帧数和播放状态核验。

`gp_playback operation=timeline` 返回实际展开序列 `bars`：`bar` 为原谱小节，`start_tick/end_tick` 为展开位置，`frames` 为本次播放时长。使用 `offset` 和 `limit=1..1024` 分页，最多 100000 次小节出现；总长度为 `total_ticks/total_frames`。定位同一小节的后续反复应使用 `seek_tick`。反复、反复房子和 D.C. al Fine 已逐小节核对，嵌套反复沿用 P3 回归；未穷举所有跳转组合。

`set_loop_range` 使用 `base/extent` 的五个索引（`track/staff/voice/bar/beat`），端点包含在内，通过原生选区设置播放范围。它会改变光标和选区，不额外保存插件循环范围。`clear_loop_range` 清选区并关闭循环；两者均要求停止播放。状态 `range` 返回实际 `start_tick/end_tick/loop_start_tick/loop_end_tick`，结束 tick 不包含在范围内；`-1` 表示宿主尚未形成范围。普通 `set_loop` 只改变启停状态。另提供 `set_metronome_volume value=0..1`、`set_countdown_bars value=1..4`。播放控制必须先激活目标文档；`stop` 用于停止或取消尚未开始的播放，仍须轮询确认。

`gp_audio_track track=...` 的操作：

| operation | 参数与行为 |
| --- | --- |
| `state` | 返回 `sounds`、效果 ID/旁路/参数、MIDI bank/program 和 `forced_sound` |
| `select` | `sound` 为现有索引，`-1` 恢复曲谱音色自动化；不进宿主撤销栈 |
| `copy` | 将 `source_document/source_track/source_sound` 的已有音色写入目标 `sound`（默认 0）；可从 `gp_new` 模板复用，拒绝有音高/打击乐混用 |
| `midi_program` | `value=0..127`，只修改 MIDI 音色部分 |
| `effect_bypass` | `effect` 索引和 `enabled`，true 表示旁路 |
| `effect_parameter` | `effect`、`parameter` 现有索引和归一化 `value=0..1` |
| `effect_swap` / `effect_remove` | 交换 `effect/other` 或删除 `effect` |

除 `select` 外，修改独立的原生 `Sound` 副本后通过 `Score::setTrackSound` 提交，支持撤销重做及保存重开。音色复制保留目标音轨的 MIDI/RSE 引擎选择；RSE 音轨可从模板创建或通过 `gp_insert_track` 复用，不增加引擎或乐器定义系统。效果参数沿用宿主索引，不引入参数名称数据库、任意新效果构造或自动化曲线编辑。音量、声像、独奏和静音继续使用 `gp_edit_track`。

`gp_audio_abi` 提供给需要直接验证原生音频边界的开发者。`operation=state` 逐音轨返回进程内不透明的 `track_id`；当当前 `Conductor` 已为该文档构造 RSE 声音时，同时返回 `chain_id`、声音索引、链索引和名称。`operation=resolve` 携带 `track_id` 或 `chain_id` 可检查句柄仍绑定原对象。句柄只是随机 UUID，不编码 native 地址；每次 `resolve` 或 `buffer_probe` 都重新定位当前文档的 `Score`、`core::Track`、`Musician`、`Sound` 和 `EffectsChain` 并逐级核对 RTTI 与对象身份。文档关闭/替换、音轨重排/删除、声音或链替换、宿主重启以及实例切换都会使旧句柄失效，调用方必须重新读取 `state`，不能缓存地址或把旧 ID 用到其他实例。`track_binding_status=verified` 只表示 `Musician::coreTrack()` 与目标音轨匹配；`chain_mapping_status=host_limited` 表示该宿主时刻没有可观察的 RSE `Sound/EffectsChain`，不会猜测或回退到别的音轨。

`operation=buffer_probe`（仅 `GPMCP_DEVELOPMENT=1`）在宿主线程分配真实 `AMAudio::AudioBuffer`，经 `IAudioBuffer::fromInterleavedData`、`lock/unlock`、`toInterleavedData` 验证可写交错 PCM 边界，并调用 `GPRSE::EffectsChain::processDSP`。传入 `chain_id` 时使用已绑定的实时链；省略时使用当前曲谱 `core::EffectChain` 经 `SESoundConverter::convertEffectChain` 得到的验收链，返回 `process_source=bound_track_chain` 或 `converted_core_sound_chain`。两条路径都只用于边界验收；实时播放线程的长期复用、线程安全和无锁音频回调仍需单独专项，HTTP 请求不能直接持有实时 buffer。当前 8.1.1.17 隔离宿主已验证 64 帧、2 声道、有限值、写读和 DSP 改变；真实 `Conductor` 链尚未由最小夹具构造时，`state.status=experimental` 且 `chain_mapping_status=host_limited`，不会伪造绑定链成功。

`gp_audio_device state` 返回 `scope=application`、`configuration`、`property_types`、当前宿主 `choices` 和 `running`。`set property=... value=...` 只接受返回 choices 中的精确值；`audioOutputChannels` 只有在宿主模型可读时才会列出当前合法值，不猜测声道数量。通过宿主配置模型的 Qt 属性提交，原生配置负责持久化，不进入曲谱撤销。播放中拒绝设备修改；未知选项在修改前拒绝，原生设置失败尝试恢复旧值。Standard、Studio 2 PRO 输出与 512/1024 缓冲区已验证；ASIO、热拔插、厂商控制面板及驱动故障未验收，不声明自动恢复所有设备错误。

`GPMCP_DEVELOPMENT=1` 时提供 `gp_audio_probe`，通过宿主 `AudioExportManager` 渲染最多 30 秒的测试曲谱，返回双声道浮点 PCM 的帧数、RMS、峰值及哈希。仅用于验收，不作为 P6 文件导出接口，不采集系统或麦克风声音。`test/test-audio.ps1 -Render` 验证速度、渐变、反复、音量/声像、效果和音色变化；默认最小夹具是 MIDI 音轨，测试副本改为 RSE 并复用 Steel Guitar / Acoustic Piano 模板。验收使用 `C:/ProgramData/Arobas Music/Soundbanks/com.arobas-music.soundbank.standard`，不能用接近静音的 MIDI 渲染证明 RSE 发声正确。

### P13 Audio Provider 内部 ABI

`native/audio_bridge_api.h` 定义进程内 Provider 的 C ABI，当前 `GPMCP_AUDIO_BRIDGE_ABI_VERSION=1`。MCP 插件导出 `gpmcp_audio_bridge_version`、`gpmcp_audio_bridge_get_info` 和 `gpmcp_audio_enumerate_v1`；兄弟原生插件通过 `GetModuleHandle`/`GetProcAddress` 协商版本后使用，不依赖 HTTP 会话或客户端令牌。调用方必须把 `struct_size` 设置为当前结构体大小，并复制回调期间的 `document_id`、`track_id`、`score_key`；`chain` 及字符串指针在回调返回后失效。

`gpmcp_audio_bridge_info` 回报 ABI 版本、Provider 状态、能力位、宿主 `GuitarPro.exe` SHA-256 和当前 `generation`。`gpmcp_audio_enumerate_v1` 只在 Qt 控制线程执行，返回 `GPMCP_AUDIO_OK`、`GPMCP_AUDIO_NOT_READY`、`GPMCP_AUDIO_HOST_LIMITED`、`GPMCP_AUDIO_ABI_MISMATCH`、`GPMCP_AUDIO_WRONG_THREAD` 或其他稳定状态；Provider 未加载、宿主哈希未核验、对象暂不可观察和版本不匹配均保留明确状态，不切换到其他实例或曲谱。每个 binding 同时带有 generation、控制器序号、音轨/声音索引、活动文档和选中音轨标记。

generation 在观察到文档 Score、音轨指针或音轨集合变化时递增，旧 `track_id`/`chain_id` 会被拒绝；关闭文档清理句柄，宿主退出清空注册表。binding 的 generation 对应该文档修订，枚举结果及 info 的 generation 对应 Provider 已观察的全局修订；它不延长宿主指针寿命。`active_document`/`selected_track` 为 0（否）、1（是）或 2（无法确认），不根据文档数量猜测。

`GPMCP_AUDIO_HOST_LIMITED` 可以携带已核验的音轨上下文：未就绪链为 `chain=nullptr`、`sound_index=-1`、binding `status=GPMCP_AUDIO_HOST_LIMITED`。非活动文档可能没有 Conductor，此时不返回该文档绑定，枚举总状态为 `HOST_LIMITED`；切换回文档后重新发现。回调内不得编辑宿主、处理 Qt 事件、重新进入 Provider 或抛异常；消费者只复制元数据，DLL 卸载后不得调用旧函数地址。

0.11.0 保留 MCP 协议 `2025-06-18`、`gp_audio_abi` 和 P13 Provider 参数/状态含义，新增 P14 `backend`、`capture_scope`、PCM 读取和诊断字段；客户端可忽略新增字段。`state`/`resolve` 和原生枚举均只观察现有对象，不再隐式调用 `Musician::updateAll()`；链未就绪时保留 `host_limited`。P14 实时流使用独立 `audio_stream_api.h` v1，进程级 WASAPI loopback 不改变 P13 ABI；旧消费者继续工作。偏好模型额外允许写入 `currentRow`，以支持列表选择控件的原生读回。

### P14 实时音频流

`native/audio_stream_api.h` 定义独立的 `GPMCP_AUDIO_STREAM_ABI_VERSION=1`，不改变 P13 `audio_bridge_api.h`。ABI 明确结构体大小、状态码、能力位、宿主哈希、generation 和固定字符串字段，并导出 `gpmcp_audio_stream_version`、`gpmcp_audio_stream_get_info`、`gpmcp_audio_stream_enumerate_v1`。枚举只允许 Qt 控制线程，返回当前实时会话的实际格式和累计帧数；PCM 通过 MCP `read` 有界读取，不暴露宿主或 COM 指针。

`gp_audio_stream` 的 `operation` 为 `state`、`start`、`stop`、`snapshot`、`read`、`diagnose` 或 `recover`。`start` 必须指定已核验 `document`，可选 `layers`（`input`/`source`/`track`/`effects`/`mix`/`audiolayer`/`endpoint`）、`backend=auto|standard|asio|process_loopback|render_loopback`、`max_frames=1..4096` 和 `max_bytes=4096..1048576`；最多同时运行四个捕获会话，返回不透明 `stream_id`。会话绑定当前实例、文档和 generation，文档或宿主重建后旧 ID 返回 `status=stale`、清空待读 PCM 且不能 recover，不会回退到其他曲谱；显式传入其他 `document` 也会拒绝。`recover` 只重启当前 loopback 会话，返回实际重启结果，不修改宿主音轨或驱动配置。

`guitarpro_audio_stream.h` 的实时回调边界是固定 256 帧、8 声道块和 32 块 SPSC ring；`WasapiLoopbackCapture` 在独立 COM 线程优先激活 Windows 进程级 loopback，只捕获 Guitar Pro 进程树音频，激活失败时回退默认渲染端点。`capture_scope`、`endpoint` 和 `sample_format` 返回实际来源，不把端点混音冒充独立音轨 tap。采集循环不调用 Qt、不做对象发现或文件 I/O；控制线程读取帧数、WASAPI 100ns 时间戳、设备位置间隙、宿主/监测丢帧、underrun/overrun/xrun、回调耗时、RMS、峰值、DC、削波和非有限样本。`read` 的 `chunks[].pcm_base64` 是交错 `f32le` PCM，`max_bytes` 限制 compact structured result（包含 JSON/base64 开销），同时受 `max_frames` 约束；`layer_states` 将当前没有单独采样点的内部层标为 `not_observed`。

## 窗口截图

先调用 `gp_windows({include_hidden: true})`，再把返回记录的 `window_id` 传给 `gp_screenshot`。两者在 Qt 主线程执行，模态对话框存在或原生操作等待期间仍可读取。`gp_windows` 不刷新 `gp_objects` 的快照；多客户端、重新建立 MCP 会话、标题变化及隐藏/最小化不改变窗口 ID。ID 绑定实例和 QObject 生命周期，窗口销毁或宿主重启后失效，客户端应将它作为不透明字符串使用。

`gp_windows` 返回 `instance_id`、`pid`、`scope=qt_windows`、`total_count`、`visible_count`、`hidden_count`、`returned_count`、`windows`、`observed_at`。`include_hidden` 默认 `true`；设为 `false` 只过滤列表。统计来自同一次观察，不把曲谱标签数当作窗口数。发现路径为 Qt 顶层 QWidget、具有窗口语义的 QWidget（含 `Qt::SubWindow`）和已有 QWindow，QWidget 的原生 QWindow 不重复计数，不通过 `winId()` 创建原生窗口。

每条记录包含 `window_id`、`parent_window_id`（无可确认父窗口时为 `null`）、`kind`、`class`、`object_name`、`title`、`source=qwidget/qwindow`、`qt_window_type`、`visible`、`minimized`、`maximized`、`fullscreen`、`active`、`modality`、`active_modal`、`geometry`、`dpi`、`device_pixel_ratio`。`kind` 按实际 Qt 类型分类为 `main/dialog/tool/popup/tooltip/subwindow/splash/window`；非模态对话框仍为 `dialog`，模态性单独使用 `non_modal/window_modal/application_modal`。`active` 是 Qt 的活动状态，不等于 Windows 前台 HWND。`geometry` 是内容区在屏幕坐标中的 Qt 逻辑像素，DPI 为逻辑 DPI。标题和对象名分别截取 1024/256 字符，发生时 `text_truncated=true`，不影响 ID。

枚举最多返回 512 个窗口，QWidget/QWindow 扫描上限各为 20000；达到限制时 `truncated=true`、`count_scope=observed_subset`，`truncation_reasons` 指明限制，此时数量只覆盖已观察集合。完整 Qt 集合使用 `count_scope=complete_qt_set`，仍不包含桌面代理、外部窗口包装、普通嵌入式控件、未构造窗口、纯系统原生窗口或其他进程窗口；具体口径由 `scope_note` 返回。

`gp_screenshot({})` 保留 P11 行为：优先当前活动 QWidget 模态对话框，否则选 `gp::gui::MainWindow`。显式指定 ID 时仅绘制该对象，主窗口被模态阻塞时也不会替换目标。`include_frame` 默认为 `false`；设为 `true` 时，Windows 顶层 QWidget 会在 Qt 客户区外补入现有 native window 的系统标题栏和边框，不创建 native handle、不激活窗口。返回窗口记录中的身份和状态，以及 `target_window=main/active_modal/window`、`target_class`、`target_object_name`、`active_modal_window_id`（不存在为 `null`）、`capture_mode=qt_widget_render` 或 `qt_widget_render_with_win32_frame`、`frame_requested`、`frame_included`、`frame_reason`（成功为 `win32_wm_print`；无标题栏时为 `not_applicable`）以及 PNG 像素 `width/height`、`capture_ms` 和 `captured_at`。`frame_included=true` 时另返回 `frame_insets`（物理像素）和客户区 `client_width/client_height`。`active_modal` 只表示选中对象是否为活动模态，不能用于判断宿主是否存在另一个模态。

PNG 通过标准 MCP `image` content 返回，结构化元数据同时作为 `structuredContent` 和 `text` content 返回；内部 `__mcp_image` 不暴露给客户端。默认图像表示目标 Qt 内容区及普通子控件，不含桌面或其他独立窗口；`include_frame=true` 且 `frame_included=true` 时还包含该窗口的系统标题栏和边框。没有现成 native handle、目标不是顶层 QWidget、非 Windows 平台或 Windows 无法可靠绘制非客户区时返回 `status=host_limited`，不伪造标题栏成功。成功状态仍为 `experimental`，已核验的具体窗口类型与剩余矩阵见 [P12 验收](../docs/COVERAGE.md#p12-验收)。

| 失败状态 | `reason` 与处理 |
| --- | --- |
| `status=error` | `invalid_window_id`：空值或格式错误；`foreign_instance`：其他实例或旧宿主；`window_not_found`：未知或已销毁；`window_not_available`：存活对象已不属于当前可观察窗口。均 `isError=true`、无图像，不回退选择其他窗口 |
| `status=host_limited` | `no_window`、`qwindow_render_unsupported`、`special_rendering`、`embedded_subwindow`、`render_scan_limit`：不存在目标、只有 QWindow、含 GPU/原生内容、会合成其他独立 SubWindow 或子控件扫描超限 |
| `status=host_limited` | `unprepared_hidden_window`：隐藏窗口尚未完成布局，Qt 绘制会初始化或调整其尺寸，故在绘制前拒绝；不会为截图显示、恢复或初始化窗口 |
| `status=host_limited` | `dimensions_limit`、`allocation_failed`、`window_destroyed`、`encoding_failed`、`render_timeout`、`image_size_limit`：尺寸、分配、存活、编码、耗时或响应限制，均无图像且说明原因 |
| `status=host_limited` | `frame_handle_unavailable`、`frame_geometry_unavailable`、`frame_geometry_invalid`、`frame_geometry_mismatch`、`frame_allocation_failed`、`frame_paint_failed`：请求 `include_frame=true` 时无法安全取得或绘制现有 Windows 非客户区，均无图像；`not_applicable` 表示无系统标题栏（无边框/弹出样式），仍返回客户区图像 |

限制沿用 P11：单边不超过 4096 像素、总像素不超过 16 Mi、PNG 和 base64 各不超过 8 MiB。2000 ms 检查在绘制及编码返回后执行，不能中断阻塞中的 Qt 绘制。截图不会发送输入、激活窗口或改变文档及撤销历史；未准备好的隐藏菜单和没有可靠 QWidget 路径的窗口可以被枚举，但不代表可截图。

## Qt 对象工具

`gp_objects` 和 `gp_actions` 支持 `query`、`offset`、`limit`、`include_hidden`。每次查询返回新的 `snapshot` 和对象 ID，并列出方法、信号、基本属性和页面容器内容。快照有效期 60 秒，后续查询会使旧快照失效。

`gp_trigger`、`gp_set_property` 和 `gp_close_window` 必须携带刚观察到的 `snapshot` 与 `id`。动作会在 Qt 事件循环中调度；返回 `scheduled` 仅表示已安排，需要再次读回结果。允许写入的属性会在对象查询中列出。

这些工具没有使用鼠标事件或键盘快捷键，但 Qt 动作是否启用仍由宿主上下文决定。存在待完成操作或未知结果时，`gp_trigger` 和 `gp_set_property` 只允许操作当前模态对话框内的控件，不能绕过文档写入阻塞。窗口显示与正常关闭保留原生确认流程。控件属性修改不等于模型修改；曲谱业务操作应优先使用前述 GPCore 工具。

`gp_window` 的 `state` 为 `hide`、`minimize` 或 `restore`。显式 `GPMCP_BACKGROUND=1` 时隐藏主窗口，并对 `QWidget` 及已有 `QWindow` 同步设置 `WindowDoesNotAcceptFocus`；底层窗口不能只等下一次显示才更新。`restore` 解除插件设置的标志，调用 `showNormal()` 和 `activateWindow()` 显示并请求激活主窗口；它可将窗口带到前台。`hide` 重新进入不抢焦点的后台模式。开发启动脚本默认设置该变量，正常安装启动不设置。

宿主在 Qt 原生焦点窗口变化时重新计算动作可用性。仅显示窗口会在反复隐藏后留下禁用菜单；仅设置 Qt 的逻辑活动窗口也没有触发该更新。`restore` 通过公开窗口激活方法恢复宿主上下文，不直接写入菜单的启用属性。普通后台曲谱读写仍使用原生文档接口，无需恢复窗口；原生菜单和其他界面动作仍受宿主的模态及焦点条件约束。Windows 可能根据当前桌面或焦点策略拒绝激活，调用方应读回实际状态。

后台模式关闭 Qt 的“最后窗口关闭即退出”，避免无可见窗口时关闭或重开曲谱导致服务退出。恢复可见窗口时恢复原退出设置。`gp_close_window` 显式关闭主窗口时，只有宿主接受关闭才退出应用；有未保存内容时保留宿主确认流程。进程退出可能先于关闭请求的 HTTP 响应完全发送，客户端应以宿主退出和连接断开确认服务已停止。

`gp_capabilities` 的 `foreground_pid` 和 `foreground_window` 在宿主内读取 Windows 的真实前台窗口；`hidden_mode` 表示插件是否维持隐藏模式。主窗口隐藏不必然代表前台 PID 已切走，因此测试仍独立检查前台进程。修复后的检查无需预先最小化，包含恢复窗口后再隐藏的路径。

## P6 文件与工作区

插件运行时仅使用 Guitar Pro 自带的 GPCore、GPIO、GPRSE、AMUtils、AMPainting 和 Qt。无需安装 Python、Node.js、FFmpeg、Poppler、虚拟打印机或其他转换程序；音频继续使用宿主已有音源和音色库。

`gp_formats` 区分宿主注册表与插件的 `export_extensions`。`gp_export` 按扩展名输出 GP5、GPX、XML/MusicXML、MIDI、WAV、PDF 或 PNG；`.gp` 保存继续使用 `gp_save`/`gp_save_as`/`gp_save_current`。目标须为现有目录中的绝对路径，覆盖须 `overwrite=true`，拒绝覆盖打开的曲谱。先写同目录临时文件，再核对原目标并原子提交；用 `gp_operation` 等待 `exported`，用 `gp_cancel` 请求取消，已完成的输出不会被撤销。转换器原生警告通过 `result.warnings` 返回。

PDF 复用宿主原生排版和 QPrinter 打印流程，受控打印目标就是 PDF 文件，不提交物理打印队列。PNG 为同一原生绘制器输出的单页，`page` 从 1 起，默认 1；144 DPI，最多 256 页、单页 6400 万像素。WAV 为整曲 44.1 kHz 双声道 16 位 PCM，最多 30 分钟，不含节拍器和预备拍；MIDI 音轨须使用宿主可渲染的音源，不能把静音文件解释为有效发声。

`gp_open` 异步导入 GP5、GPX、MusicXML 和 MIDI。MIDI 请求停在原生参数对话框时，用 `gp_midi_import request=<id>` 读回选项，`operation=set` 设置 `dot/is2ChannelsPerTrack/live/multivoice/staccato/triplet` 布尔值或 `quantization` 2..8（全音符至六十四分音符），`operation=accept` 导入为新曲谱；继续轮询原打开请求，取消使用 `gp_cancel`。不向当前曲谱合并。GP3/GP4、MXL 等宿主可打开的扩展仍需各自样本验收。GP5/GPX 可能丢失新版本记谱及音色信息；MusicXML 保留记谱而非完整 RSE，五线谱和六线谱可分别成为输出谱表；MIDI 保留演奏事件，不保留原始排版和完整技法语义。

`gp_preferences` 只操作整个软件，`scope=application`，`model=general/gui/score/user_info/midi`；允许属性由 `property_info` 的显式 allowlist 列出，`values` 只返回宿主实际存在且可读的字段。枚举返回 `choices`，一般偏好覆盖默认模板/样式、页面模式、缩放和强制选项，界面偏好覆盖语言、播放游标及已确认的编辑选项，`user_info` 覆盖 `artist`、`lyrics`、`music`、`copyright`、`instructions`、`tab`，`midi` 覆盖可读的 `midiInput`、`selectedMidiOutputs`、`midiCaptureSensitivity`。设置失败会尝试恢复旧值；没有匹配的宿主模型明确返回 `status=host_limited`。偏好不进入曲谱撤销栈。`gp_presentation` 只操作返回 ID 对应的文档，一次修改页面尺寸、页面元数据、视图或谱表一组。页面边长 50..1000 毫米，边距须留下至少 20 毫米内容区域；尺寸、边距、方向和谱表显示可保存重开。缩放 0.25..4 及编辑视图属于会话状态，返回 `requested` 时应再次读取 `state` 确认。P6 的页面尺寸及显示设置不进入宿主撤销栈，同值页面设置不制造脏状态；P8 的 `page_metadata` 使用异步原生提交，整组可以一次撤销，见 [页面元数据](P8.md#页面元数据)。声音和设备参数复用 P5 的 `gp_audio_track`/`gp_audio_device`。

专项：`./test/test-p6.ps1 -SessionFile <session.json>`，使用 Windows 自带的 PowerShell/.NET 核验交换格式、PNG、PCM、设置恢复和临时文档隔离。`test/test-exchange.ps1` 仅解析本项目简单验收夹具，不是通用转换器。开发者可显式加 `-RenderPdf` 使用已准备的 Poppler 独立复核 PDF；该选项不是普通测试、插件安装或运行的前提，测试脚本不进入安装包。当前证据见 [P6 验收](../docs/COVERAGE.md#p6-验收)。

P10 专项：`./test/test-p10.ps1 -SessionFile <session.json> -VerifyRestart`，读取五类偏好和音频/MIDI 模型，核对 allowlist、错误输入拒绝、同值写入读回、choices、重启持久化与新建曲谱默认资讯继承。底层 setter 失败时实现会尝试恢复旧值；跨重启分支只用于隔离开发宿主，宿主未退出时按 `host_limited` 记录，不强制结束用户实例。当前证据见 [P10 验收](../docs/COVERAGE.md#p10-验收)。
