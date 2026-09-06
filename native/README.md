# 原生插件开发与调用

本目录实现运行在 `GuitarPro.exe` 内的 C++ MCP 服务器。当前通过 Qt 通用插件入口加载，并直接使用 Qt 和经过验证的 GPCore 接口。Python、Node.js、UIA、输入模拟和外部转接服务不在运行链路中。

工程目标及剩余工作见 [覆盖清单](../COVERAGE.md)。以下仅描述当前代码提供的能力。

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `guitarpro_mcp.cpp` | Qt 插件入口、MCP 工具目录、Qt 对象检查和请求分发 |
| `mcp_server.cpp` / `.h` | HTTP、JSON-RPC、初始化、会话、鉴权和工具参数校验 |
| `guitarpro_api.h` | 文档定位/切换、实时曲谱编辑、光标、撤销重做、保存和播放 |
| `guitarpro_clipboard.h` | 原生曲谱快照、复制/剪切/粘贴及兼容性检查 |
| `guitarpro_abi.h` / `gpcore.def` / `gprse.def` | 已确认的原生导出声明及导入库定义 |
| `object_registry.h` | Qt 对象生命周期观察和失效指针保护 |
| `discovery.h` | 只读指针与 RTTI 校验；开发模式下的对象关系探索 |
| `build.ps1` | 使用项目内 Qt SDK 和已安装的 Visual Studio 构建 DLL |
| `mcp-client.ps1` | 供开发验证使用的 PowerShell HTTP MCP 客户端 |
| `test-*.ps1` | 协议、后台曲谱及音轨编辑、音符技法、小节记谱与反复定位、文档生命周期、多文档播放、结构和模板检查 |

`guitarpro_abi.h` 只声明已使用的导出接口，模型对象由 Guitar Pro 持有。插件本地构造已验证布局的值对象：8 字节的 `ScoreModelRange`、56 字节且 8 字节对齐的 `RhythmValue`，以及 3 字节 RGB `Color`。前两者的构造、析构和内部资源管理都调用宿主导出函数；颜色为三个无符号字节，不含透明度。小节记谱还使用 8 字节且 4 字节对齐的 `TimeSignature`，以及 16 字节且 8 字节对齐、具有虚析构函数的 `KeySignature`；两者调用宿主构造函数，后者调用宿主析构函数。大小由对应构造/析构实现、容器步长或复制指令核实，并有静态断言；RGB 顺序另以保存后的 GPIF 检查。MSVC 负责成员调用及返回值的 ABI，不手写 `std::string` 或 `std::shared_ptr` 的返回约定。

## 构建和加载

正式安装使用根目录的 `Install.cmd` / `install-plugin.ps1`，说明见 [INSTALL.md](../INSTALL.md)。`autoload.cpp` 作为 Qt 图像插件加载器，在主事件循环中校验宿主并加载现有 MCP 核心；`host_build.h` 提供宿主检查，`plugin_config.h` 管理用户配置与诊断，`plugin_status.h` 提供软件内状态入口。它不参与图像编解码。正常安装默认可见，开发启动脚本默认后台。

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

启动脚本为该新进程设置 `QT_PLUGIN_PATH`、`QT_QPA_GENERIC_PLUGINS=guitarpro_mcp` 和 `GPMCP_SESSION_FILE`，然后恢复调用进程的这些环境变量。临时目录设在项目 `.cache/tmp` 中。

服务默认只监听 `127.0.0.1:18432`。`GPMCP_PORT` 可指定其他端口；`-SessionFile` 可指定会话文件位置。多实例的端口、令牌/配置目录和启动日志隔离尚未完成统一测试，当前建议使用一个插件实例。

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

曲谱工具的可选 `document` 参数使用 `gp_documents` 返回的 ID。只有一个文档时可以省略；存在多个文档时必须指定。ID 属于当前宿主会话，关闭或重新打开文档后应重新读取。

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `gp_templates` / `gp_new` | 无 / `template` | 枚举内置模板；新建返回请求 ID，通过 `gp_documents.creation` 读回完成状态 |
| `gp_open` | `path` | 绝对路径的已有 `.gp` 文件；通过 `QFileOpenEvent` 异步打开，已有文档返回 `already_open` |
| `gp_close` | `document` | 关闭无未保存修改的文档，返回请求 ID，通过 `gp_documents.closing` 读回 `closed` / `error` |
| `gp_activate` | `document` | 调用原生 `activateNextDocumentView` 导航至目标，并读回文档管理器确认 |
| `gp_score` | `document?` | 读取元数据、音轨摘要、光标、未保存和撤销重做状态 |
| `gp_read_bars` | `document?`, `track?=0`, `staff?=0`, `bar?=0`, `count?=1` | 每次读取 1–16 个完整存在的小节，音符包括 `effects`；单次节拍/音符读取量有上限 |
| `gp_read_master_bars` | `document?`, `bar?=0`, `count?=1` | 每次读取 1–128 个全曲共享小节的拍号、实音调号、反复和小节线状态 |
| `gp_edit_measure` | `document?`, `operation` 及对应参数 | 修改光标所在的单个全曲共享小节，参数见下表；支持原生撤销 |
| `gp_edit_metadata` | `document?`, `property`, `value` | 属性名使用 `gp_score.metadata` 的原始键，例如 `Title`；值最长 16384 个 UTF-16 代码单元 |
| `gp_edit_tempo` | `document?`, `value`, `unit?`, `label?` | 修改初始速度，`value` 为 1–400 的整数，省略单位或标记时保留原值 |
| `gp_edit_track` | `document?`, `track`, `property`, `value` | 修改 `name`、`short_name`、`color`、`volume`、`pan` 或 `playback_state` |
| `gp_edit_tracks` | `document?`, `operation`, `track`, `other?` | `duplicate` 复制到源轨之后，`remove` 删除，`swap` 与 `other` 交换 |
| `gp_insert_track` | `document?`, `source_document?`, `source_track`, `index?`, `copy_content?=false` | 基于现有音轨配置新增，源文档默认目标文档，插入位置默认末尾 |
| `gp_cursor` | `document?`, `axis`, `index` | `axis` 为 `track`、`staff`、`bar`、`voice` 或 `beat`；每次修改一个索引；声部 0–3 |
| `gp_selection` | `document?`, `operation?=state`, `base?`, `extent?`, `note_index?`, `all_voices?`, `all_tracks?` | 读取、构造并提交原生选区；参数和范围见下文 |
| `gp_set_fret` | `document?`, `string`, `fret` | 修改当前光标节拍中指定弦的已有音符；品位 0–36 |
| `gp_edit_note` | `document?`, `operation`, `string`, `fret?` | `set` 新增或修改音符，需要品位 0–36；`remove` 删除该弦音符，不接受 `fret` |
| `gp_edit_note_effect` | `document?`, `string`, `property`, `value` | 修改当前拍指定弦的已有音符技法，支持原生撤销；取值见下表 |
| `gp_edit_beat` | `document?`, `operation`, `denominator?`, `dots?`, `scope?=cursor`, `level?`, `actual?`, `normal?`, `enabled?` | `insert` 插入休止拍，`rhythm` 设置基础时值，`dots` 设置附点，`tuplet` 设置连音，`clear` 清空音符，`remove` 删除节拍；`scope=selection` 接受 `rhythm/dots/tuplet` |
| `gp_edit_connection` | `document?`, `kind`, `enabled`, `scope?=cursor`, `string?` | `legato` 连奏或 `tie` 延音线；指定弦单音仅用于光标延音线；选区支持跨声部、音轨及谱表 |
| `gp_clipboard` | 按操作提供 `document?`, `id?`, `scope?`, `track?`, `staff?`, `bar?`, `count?` | 原生独立快照的复制、剪切、读取和粘贴；见原生剪贴板章节 |
| `gp_edit_bars` | `document?`, `operation`, `index`, `count?=1` | `insert` / `remove` 同步增删所有音轨的小节，数量 1–128；曲谱最多 100000 小节 |
| `gp_undo_redo` | `document?`, `operation` | `operation` 为 `undo` 或 `redo`，必须存在相应历史 |
| `gp_save` | `document?`, `path` | 调用 `IDocument::saveToFile`，仅创建新的 `.gp` 副本 |
| `gp_save_as` | `document?`, `path` | 创建副本后调用 `setSaveFilePath` 和宿主 `save()`，完成另存为及保存状态更新 |

所有索引从 0 开始。弦索引沿用宿主内部顺序，并不直接等于日常所说的“第一弦”。光标尚未选中音符时，`note_string` 和 `note_midi` 可能为 `-1`。

编辑、光标、撤销重做和另存为工具先激活目标文档，确保宿主更新正确文档的未保存标记；因此会改变软件内的活动文档。光标请求被宿主钳制时返回错误及实际位置，调用方应读回后决定下一步。

切换声部后光标可能没有选中节拍，随后用 `bar` / `beat` 定位。声部超出 0–3、谱表超出当前音轨范围的请求在调用原生函数前拒绝；钢琴下谱表和第二声部的编辑隔离已实测。

原生撤销能够恢复内容，但宿主的未保存标记不一定随之清零。插件如实报告这个状态。`gp_save` 也不会清零该标记；`gp_save_as` 使用宿主真正的保存流程更新状态，不直接伪造 `isDirty=false`。

`gp_score.tracks` 包含名称、简称、乐器类型、播放状态、音量、声像、移调偏移和颜色。`gp_edit_track` 的名称、简称、颜色及播放状态要求字符串；颜色格式为 `#RRGGBB`，播放状态为 `Default` / `Solo` / `Mute`。音量和声像要求数值 `0..1`，声像 `0.5` 居中；这些值不是分贝或百分数。混音设置调用原生 `setTrackChannelStripParameter`，声像参数为 11、音量参数为 12。除播放状态外均支持原生撤销；播放状态返回 `undoable=false`，不会伪造撤销历史。

复制、新增、删除和交换音轨使用宿主结构命令并读回数量和对象顺序，最多支持 1024 条音轨。删除最后一轨会留下零音轨曲谱，可撤销恢复。新增音轨时宿主克隆源配置；默认清空内容并按目标主音轨重建小节，不修改源文档。`copy_content=true` 目前只接受源轨与目标小节数相同的情况。原音轨及克隆的音符数据独立，跨文档钢琴双谱表插入和零轨恢复首条音轨已验证。

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

`test-tuplets.ps1` 的 175 项检查验证十种比例（含 `255:254`、`255:1`、`1:255`）、非法参数、光标与选区隔离、另一层及基础时值/附点保持、重复设置、一次撤销/重做、反向跨小节、跨声部/音轨、钢琴谱表及 GPIF。嵌套与单独次层已保存重开，嵌套连音还通过插件独立缓冲区复制粘贴验证。尚未验证任意比例组合的实际发声、所有分组/括号排版和极端时长的播放行为。

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

已验证 153 项：光标与较大选区隔离、正反向跨小节、整拍及和弦单音、音高与升降号更新、缺少弦音符补入、清除、重复命令、撤销重做、跨声部/音轨的一次撤销、钢琴下谱表隔离、GPIF 连接两端及保存重开。尚未覆盖装饰音、打击乐、长延音链与其他技法的全部组合、复杂排版和实际发声。

## 原生剪贴板

`gp_clipboard` 使用宿主 `SerializedScore` 保存独立曲谱快照。该值对象为 16 字节、8 字节对齐，包含虚表和实现指针，构造及虚析构由宿主完成。快照由 `shared_ptr` 持有；关闭或修改源文档后仍有效，原生粘贴命令可保留自己的引用供撤销重做使用。

| `operation` | 参数 | 行为 |
| --- | --- | --- |
| `state` | 无，默认操作 | 返回 `available`、当前 `id`、来源选区与实际节拍位置、小节/音轨数量、声部/音轨模式及 `tracks[].staves` |
| `clear` | 无 | 清空插件当前缓冲区，使旧 `id` 失效 |
| `copy` / `cut` | `document?` | 从明确选区构造快照；剪切随后调用原生删除命令 |
| `read` | `id`, `track?=0`, `staff?=0`, `bar?=0`, `count?=1` | 分页读取快照，最多 16 小节；索引属于快照，非源文档 |
| `paste` | `id`, `document?`, `scope?=cursor` | `cursor` 使用独立光标范围插入；`selection` 使用当前明确选区替换 |

每个插件实例仅保留一个当前快照，所有客户端共享；`read/paste` 必须提供匹配的 `id`，拒绝旧快照请求。`copy/read/state` 不激活源文档，`cut/paste` 在参数和兼容性校验之后才激活目标。复制范围沿用上述选区的 128 小节、1024 音轨和 20000 拍扫描上限；纯占位拍选区不能复制。粘贴按插入上界检查总小节数不超过 100000。

单小节、非多轨片段使用 `Score::pasteBeatRange`。多轨或超过一个小节的片段使用 `Score::pasteBarRange`，重复次数为 1，模式为宿主普通粘贴的不适配模式 0。插入全曲共享小节时，其他音轨的原内容顺移；复制单轨片段时，其他轨的新小节为空。返回 `native_method`、`previous_bar_count` 和 `global_bar_delta`，应再次读取完整目标范围确认结果。

多声部片段要求目标光标处于全部声部模式。可先调用 `gp_selection range`，设置 `all_voices=true`，再以 `scope=cursor` 插入；不要在两次调用之间清除选择模式。原生兼容性检查还会拒绝不匹配的多轨数量或类型，返回宿主的 `native_incompatibility` 编码。已验证单小节选区替换；复杂跨小节替换、不同调弦/移调和打击乐之间的粘贴尚需扩大验证。

快照可能包含宿主自动补齐的休止，故 `beat_count` 是源选区的实际拍数，不是快照的总拍数。实测两个四分音符的选择范围在较短声部末尾补入一个四分休止。钢琴快照保留双谱表，可用 `tracks[].staves` 和 `source_selection` 确定读取位置；下谱表仍用 `staff=1`。跨小节粘贴后，光标所在的最后一拍还可能是新生成的空占位拍。测试分别核对这些新增内容。

普通单声部剪切使用 `Score::removeBeatRange`，多轨剪切使用 `Score::removeBarRange` 删除全曲共享小节。宿主直接删除多声部范围会在撤销记录之外补齐短声部；插件改用已经核对过的逐声部范围与原生宏命令，保持一次撤销并恢复原始音乐内容。单小节多声部剪切的精确恢复已验证，跨小节剪切和复杂节奏仍需扩大测试。

```powershell
$snapshot = Invoke-McpTool $connection gp_clipboard @{operation='copy';document=$source}
Invoke-McpTool $connection gp_clipboard @{operation='read';id=$snapshot.id;staff=0}
Invoke-McpTool $connection gp_clipboard @{operation='paste';id=$snapshot.id;document=$target}
Invoke-McpTool $connection gp_undo_redo @{operation='undo';document=$target}
```

此缓冲区位于 Guitar Pro 进程内，与 Windows 系统剪贴板独立。宿主剪贴板互通处于以下实验阶段；特别粘贴过滤项、重复粘贴次数和其他自适应模式尚未实现。

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

`test-system-clipboard.ps1` 仅允许在 `GuitarProMCP-Test-*` 独立 Windows 窗口站执行，并核对宿主的 `gp_capabilities.window_station` 与测试进程一致；普通桌面入口会在接入 MCP 前拒绝运行。项目内隔离启动探针位于 `.tools/run-isolated-clipboard.ps1`，本机 `CreateWindowStation` 返回访问被拒绝，因此尚无该组通过记录。

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

布尔属性用 `false` 清除，枚举属性用 `None` 清除；大小写必须匹配。不接受不存在的弦、没有音符的休止/占位拍或无品位音符。枚举名称由宿主转换函数提供，`Open` 指法标记不会修改已有音符的实际品位。

单音范围从当前拍构造，选择模式为 0，同时设置两个端点的弦号与 MIDI 音高，再通过原生 `ScoreModelIndex::note()` 核对目标对象。只设置弦号不足以定位，音高尚未指定时宿主会返回空对象。局部范围不会改动界面光标或选区；编辑使用宿主可撤销命令，读回目标属性、音高、品位和同拍其他音符。相同值不会重复加入撤销记录。掌根闷音和延音命令关闭了连续命令合并，使每次实际变化可独立撤销。

已验证 21 种非默认取值、清除、撤销重做、和弦内单音隔离、第二声部和另一音轨不变、逐项 GPIF 保存及组合技法的原生保存/重开。GPIF 通过主小节、音轨小节、声部、节拍和音符引用定位检查对象，不能把 XML 音符定义数量当作实际发声次数。这些检查证明记谱状态和持久化，不代表已经完成各音源的声音效果验证；弯音、滑音、连奏和其他技法仍待接入。

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

工具先检查操作对应的参数，再通过原生命令修改，并读回所有小节字段。独立的 `ScoreModelRange` 设置 `setMultiSelection(true)`，确保拍号、调号只作用于光标所在小节，阻止宿主自动延伸到后续小节。这里的单小节仍由全曲各音轨共享。

调号使用实音模式。宿主会调整音符的升降号拼写，已验证 MIDI 音高、弦、品位和节奏不变，撤销恢复原拼写。修改拍号也不会自动调整现有节拍时值，小节可能不足或超出。移调乐器和复杂曲谱上的完整记谱行为尚未验证。

关闭反复结束标记或撤销新增标记后，宿主仍可能保留 `repeat_count` 缓存。插件如实返回该值，仅在 `repeat_end=true` 时解释为有效反复次数。反复编辑通过宿主更新播放时间线，更新可能异步完成。

## 原生播放与文档生命周期

`gp_new` 通过 `:/GPBase/MainWindow/Templates/` 中列出的模板创建独立文档，随后调用宿主方法清空打开和保存路径。返回 `scheduled` 不代表成功，必须轮询并匹配 `gp_documents.creation.request`；成功为 `created`，超时为 `error`。创建最多等待 10 秒，同一时刻只允许一个待完成请求。模板的文件名保持宿主原始名称。

`gp_open` 返回 `scheduled` 仅表示事件已投递。应轮询 `gp_documents` 的路径确认打开成功；当前没有异步失败通知，格式错误或宿主对话框仍需另行处理。重复打开已识别路径返回 `already_open`，不会自动切换到该文档。

`gp_close` 通过 `TabWidgetProxy::tabCloseRequested(int)` 进入宿主文档关闭流程。执行前原生激活目标，校验文档页容器、活动页和实际索引，并在异步回调中再次确认对象身份及未保存状态。它不调用曲谱视图的 `QWidget::close()`，也不模拟输入。`gp_documents.closing` 的状态为 `scheduled`、`requested`、`closed` 或 `error`，须匹配 `request`；10 秒后仍未销毁目标视图则报告错误。只记录最近一次关闭请求，仍在进行时拒绝第二次请求。手工重排标签、未保存内容的丢弃及所有模态上下文尚未验证。

存在多个文档时先 `gp_activate`，然后调用 `gp_playback`。控制器通过 `Conductor::score()` 与目标文档的 `Score` 对象匹配，避免把播放指令发往其他曲谱。

| `gp_playback.operation` | 参数 | 行为 |
| --- | --- | --- |
| `state`，默认 | `document?` | 播放、循环、节拍器、倒计时、tick/frame、总长度和原谱小节数 `score_bar_count` |
| `play` / `stop` | `document?` | 请求播放/停止，需轮询 `state` 确认完成 |
| `seek` | `document?`, `bar`, `tick?=0` | 原曲谱小节索引从 0 开始，tick 为该小节内偏移；按原生小节时值检查边界 |
| `seek_tick` | `document?`, `tick` | 展开反复后的绝对 tick，范围 `0..total_ticks-1`；不接受 `bar` 或 `enabled` |
| `set_loop` / `set_metronome` / `set_countdown` | `document?`, `enabled` | 修改相应开关并返回状态 |

测试使用初始速度 90 和 120 的两份曲谱核对第二小节起点的帧数比为 0.75，并验证播放时间线实际推进、停止后保持不动。当前尚未暴露完整混音、分段变速编辑和音频设备控制。

两个 4/4 小节的测试曲谱原长为 3840 tick，反复 3 次后为 11520 tick，原谱小节数仍为 2。`seek bar=1,tick=0` 定位到原谱第二小节的首次出现（1920 tick）；第三次的第二小节使用 `seek_tick tick=9600`。最后有效位置为 11519；反复 100 次时为 383999。测试同时验证次数修改和撤销后的时间线长度，但尚未覆盖反复房子、嵌套反复及跳转记号。

`gp_score.tempo` 读取主音轨的初始速度，字段为 `value`、`unit`、`label`、`quarter_bpm` 和可用单位 `units`，不代表当前播放位置的速度。单位包括 `Eighth`、`Quarter`、`QuarterDotted`、`Half`、`HalfDotted`，等效四分音符 BPM 分别为速度值的 0.5、1、1.5、2、3 倍，使用宿主转换函数计算。

`gp_edit_tempo` 调用 `Score::setTempo`，支持撤销重做。`value` 为以指定单位计数的 1–400 整数；宿主虽然接收浮点参数，实际会截断小数，因此插件预先拒绝。省略 `unit` 或 `label` 时保留当前值，文字使用与元数据相同的字符检查。读回包括未保存状态和撤销可用性，播放控制器可能异步更新时间线。五种单位的保存值、中文标记、定位帧数以及后续变速点不被覆盖均已实测；渐变速度和任意位置自动化尚未实现。

## Qt 对象工具

`gp_objects` 和 `gp_actions` 支持 `query`、`offset`、`limit`、`include_hidden`。每次查询返回新的 `snapshot` 和对象 ID，并列出方法、信号、基本属性和页面容器内容。快照有效期 60 秒，后续查询会使旧快照失效。

`gp_trigger`、`gp_set_property` 和 `gp_close_window` 必须携带刚观察到的 `snapshot` 与 `id`。动作会在 Qt 事件循环中调度；返回 `scheduled` 仅表示已安排，需要再次读回结果。允许写入的属性会在对象查询中列出。

这些工具没有使用鼠标事件或键盘快捷键，但 Qt 动作是否启用仍由宿主上下文决定。控件属性修改也不等于模型修改；曲谱业务操作应优先使用前述 GPCore 工具。

`gp_window` 的 `state` 为 `hide`、`minimize` 或 `restore`。显式 `GPMCP_BACKGROUND=1` 时隐藏主窗口，并对 `QWidget` 及已有 `QWindow` 同步设置 `WindowDoesNotAcceptFocus`；底层窗口不能只等下一次显示才更新。`restore` 解除插件设置的标志，使窗口可正常接受焦点，`hide` 重新进入后台模式。开发启动脚本默认设置该变量，正常安装启动不设置。

后台模式关闭 Qt 的“最后窗口关闭即退出”，避免无可见窗口时关闭或重开曲谱导致服务退出。恢复可见窗口时恢复原退出设置。`gp_close_window` 显式关闭主窗口时，只有宿主接受关闭才退出应用；有未保存内容时保留宿主确认流程。进程退出可能先于关闭请求的 HTTP 响应完全发送，客户端应以宿主退出和连接断开确认服务已停止。

`gp_capabilities` 的 `foreground_pid` 和 `foreground_window` 在宿主内读取 Windows 的真实前台窗口；`hidden_mode` 表示插件是否维持隐藏模式。主窗口隐藏不必然代表前台 PID 已切走，因此测试仍独立检查前台进程。修复后的检查无需预先最小化，包含恢复窗口后再隐藏的路径。

## 私有接口的版本约束

生产文档定位只在 `GuitarPro.exe` 和 `GPCore.dll` 的 SHA-256 与已验证构建完全一致时启用。播放接口另校验 `GPRSE.dll`，生命周期钩子另校验 `Qt5Core.dll`。对应的宿主文件哈希为：

```text
GuitarPro.exe B233B0F1C87DEB3AECE693D51E8D3C3A841C88FEE78828607B20034737C4C6DF
GPCore.dll    9425F3E8EB627D328E0CB01146D43045D86D1BA639F73718BBE7FCCF733BD250
GPRSE.dll     E983122951B94C2513A1F05828DD03DCB11620DDC50F6B497723CAE0EB32BA6A
Qt5Core.dll   C2F85BD55C31E5380DD99F0D517EE183A54C3852480BC497DC30A5483FD70FF2
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

## 验证

按根目录 [README](../README.md) 准备并打开测试副本后执行：

```powershell
./native/test-mcp.ps1
./native/test-native.ps1
./native/test-editing.ps1
./native/test-tracks.ps1
./native/test-measures.ps1
./native/test-effects.ps1
./native/test-selection.ps1
./native/test-lifecycle.ps1
./native/test-session.ps1
./native/test-structure.ps1
./native/test-clipboard.ps1
./native/test-tuplets.ps1
./native/test-connections.ps1
```

2026-09-06 的本机结果为 26 项协议、26 项原生后台、58 项音符/节拍编辑、90 项音轨、118 项小节记谱与反复定位、254 项音符技法、980 项选区和批量时值、40 项文档生命周期、103 项文档/播放、60 项结构/模板及 112 项剪贴板检查通过，共 1867 项。检查隐藏宿主窗口，验证内存模型、撤销重做、保存后的 GPIF，并核对源文件哈希。音轨检查还验证 RGB 顺序、音量/声像的持久化及无效输入、跨文档新增和克隆数据隔离。小节检查涵盖拍号/实音调号边界、相邻小节隔离、拼写与音高、反复次数 2/3/100、双小节线、自由拍号，以及展开时间线的定位和撤销。音符技法检查覆盖 21 种取值、清除、重复设置、单音/声部/音轨隔离、光标不变、撤销和 GPIF，以及组合技法原生重开。选区检查覆盖方向和模式、和弦单音、无效端点、占位拍清理和重建、单声部/四声部混合时值、跨轨整曲和单小节批量时值/附点、钢琴双谱表、128 小节限制及原生保存重开。测试独立核对目标位置、范围外隔离、宏命令的一次撤销、重做和重复设置，证据含各批目标列表。文档/播放检查包含五种速度单位、初始速度修改、后续变速点保留及实际播放帧数。生命周期检查覆盖关闭全部文档后重开、旧 ID、未保存修改保护及焦点策略恢复；双声部和钢琴夹具验证声部、谱表编辑隔离。模板检查验证重复新建、首音输入、跨文档未保存标记及多音轨小节同步。GPIF 会复用相同音符定义，编辑检查按节拍的音符引用计数。验证结果与可打开的曲谱副本输出到项目 `artifacts/`。

2026-09-07 新增连音专项 175 项，累计 2042 项。本轮协议、原生后台、节拍编辑、选区、插件独立剪贴板和连音六组共 1377 项通过；没有将尚未完成的系统剪贴板测试计入。连音证据在 `artifacts/native-tuplets-*/verification.json`。

同日新增连奏与延音线专项 153 项，十三组累计 2195 项。证据在 `artifacts/native-connections-*/verification.json`。音符技法回归进一步确认：空声部撤销后可能完全为空，也可能保留一个无音符占位拍；检查接受这两种明确状态，再对剩余曲谱执行完整比较。

最终 DLL 的最新八组回归为 1784 项通过：连接 153、协议 26、原生后台 26、节拍编辑 58、音符技法 254、选区 980、插件独立剪贴板 112、连音 175。汇总证据与构建哈希在 `artifacts/native-connections-ce6b417d13c046e0a4703353b0121ca9/regression.json`，所有原生检查均在同一个隐藏宿主进程内完成。

剪贴板检查覆盖快照独立性、源文档关闭后读取和粘贴、单小节选区替换、单/多声部及多轨剪切、原生宏命令精确撤销、多轨与跨小节全局插入及原内容顺移、空白目标、钢琴下谱表隔离、模式与轨数不兼容时拒绝，以及原生保存重开。证据在 `artifacts/native-clipboard-*/verification.json`，包括多声部休止补齐、跨小节末尾占位拍和钢琴快照。

按以上顺序执行；会话和结构检查会保留多份干净文档。再次运行时先关闭测试实例，再只打开 `artifacts/native-test.gp`。

这些检查未覆盖所有模型字段、复杂曲谱、全部模态状态、其他 Guitar Pro 构建或 Windows 无桌面服务环境。完整后台控制目标的剩余工作见 [覆盖清单](../COVERAGE.md)。
