# 原生控制覆盖清单

更新日期：2026-09-07。目标是无需输入模拟、无需前台窗口的完整 Guitar Pro MCP 插件。**该目标仍在进行中。** 以下按照具体能力记录证据，不以 DLL 加载成功、菜单可枚举或导出符号存在代替功能完成。

完整 P0–P7 阶段、执行顺序和验收标准见 [开发计划](DEVELOPMENT_PLAN.md)。本清单记录操作覆盖与验证证据，两份文档的未完成项共同构成交付范围。

## 已验证的范围

| 范围 | 已实现并验证 | 仍有边界 |
| --- | --- | --- |
| 插件与 MCP | C++ DLL 在 GuitarPro.exe 内提供 HTTP MCP；会话、令牌、Host/Origin 和参数检查；实例 UUID/PID/启动时间绑定、默认端口回退、两个客户端并发编辑、重连及重启失效；官方 MCP Inspector 2.5.0 配置导入、重启和端口变化后重新连接，旧配置明确拒绝；隔离宿主的 Windows DDE 文件关联打开；Windows PowerShell 5.1 中文路径与 UTF-8 描述读取 | 独立 GUI 多进程列为宿主限制；其他客户端、真实安装目录入口和长时间运行归后续验收；单独重复命令行启动不转发文件路径 |
| 后台执行 | 同步 QWidget / QWindow 焦点策略，显式后台启动保持隐藏，常规安装启动窗口可见；无需预先最小化即可执行模板新建、打开、关闭、切换、编辑、保存和播放；窗口恢复后可再隐藏 | 未验证无桌面环境、所有模态窗口和长时间运行 |
| 文档状态与切换 | 独立 ID、路径、未保存状态、原生 Score 和活动文档；打开/新建/关闭/重排请求跟踪和 64 条历史；明确保存/丢弃/取消及原生确认；迟到的新建/打开和新建/打开/关闭完成后异常的终态协调；损坏 ZIP/GPIF 及不兼容 required 修订明确拒绝；插件重排和故障回滚；显式恢复并核验部分/全部原文档关闭及新增文档，保留失败及恢复历史；未知结果阻止普通原生动作和属性写入；同名/未命名及多份未保存曲谱的身份、撤销、保存重开和关闭隔离；另存后的路径及界面名称同步；反复隐藏/恢复后的原生菜单及关闭确认取消 | 原生拖动列为宿主限制；完整 GPIF 模型语义、未穷举的异常组合和模态上下文属于后续可靠性验证；无可信终态时保持阻塞；原生菜单仍需宿主有效的焦点上下文 |
| 曲谱元数据 | 读取 11 项元数据；使用原生命令修改，支持撤销重做和中文保存 | 拒绝宿主不能可靠保存的补充平面 Unicode 字符和 XML 控制字符 |
| 曲谱读取 | 音轨、小节、谱表数量；分页读取声部、节拍、音符、弦、品位、MIDI 和发声音高、时值、休止、占位拍、记谱技法及调弦/变调夹 | 未暴露全部自动化、排版、音色和隐藏模型状态；发声音高字段不是连续弯音曲线 |
| 曲谱编辑 | 弦乐用弦/品位，键盘及打击乐用 MIDI 增删和弦音符、休止及占位拍首音；全音符至 128 分音符、0–2 附点；插入/清空/删除节拍；钢琴上下谱表、多声部及跨轨移调 | 打击乐按宿主默认演奏法映射；内容转移边界见下方 P4 验收 |
| 连音 | 两层比例结构化读取和原生编辑；单拍、选区、反向跨小节、跨声部/音轨、钢琴谱表；指定层独立清除；另一层及音符/基础时值/附点隔离；重复写入、原生宏命令一次撤销、重做、GPIF、嵌套与次层单独保存重开及插件内复制粘贴 | 比例为 1..255；不自动重排小节或改变连音括号/分组排版；任意比例组合的实际发声和极端时长播放尚未验证 |
| 音符及节拍技法 | 掌根闷音、延音、点弦、揉弦、弱音/重音、指法、死音、击勾弦、颤音、回音/波音、滑音、泛音、弯音；装饰音、扫拨、渐强弱、敲击、八度、轮指、拍弦/勾弦、琶音、扫弦及摇把曲线；支持清除、撤销重做、保存重开和单音隔离 | 颤音固定十六分音符；琶音/扫弦使用宿主默认时序；装饰音转换改变时值，死拍清空原音符；音源实际声音效果归 P5 |
| 连奏与延音线 | 原生起止状态读取；光标整拍、和弦单音、反向跨小节、跨声部/音轨及钢琴谱表；跨两小节八音长链、长链移调及弯音组合；清除、撤销重做、GPIF 和保存重开 | 原生连接可能改变音高或补入音符；重复命令可能留下撤销记录；全部技法组合和声学输出未穷举 |
| 小节管理 | 所有音轨同步插入和删除；首尾及中间插入、范围删除和撤销；反复房子、跳转及后续速度自动化随小节变化保持引用 | 删除全部小节时保留一个空小节；其余音色及效果自动化归 P5 |
| 小节记谱 | 拍号、实音调号、反复起止/次数、双小节线、自由拍号、反复房子及 19 种跳转记号；设置/移动/清除/撤销/重开，清除单个标记保留同小节其他标记；嵌套反复和 D.C. al Fine 播放 | 改调号可能调整升降号拼写；关闭反复结束后保留无效次数缓存；复杂时间线的全部组合归 P5 |
| 音轨管理 | 模板或已有音轨配置新增、复制、删除、交换、零轨恢复；名称/颜色/音量/声像、独奏/静音；调弦、变调夹、部分变调夹、记谱偏移和实际移调；混合吉他/钢琴/鼓曲谱 | 播放状态不入撤销栈；带内容新增要求小节数一致；调弦及实音移调保留原弦可演奏范围；按用户确认不增加任意乐器定义或指法搜索，效果链归 P5 |
| 光标与选区 | 原生端点、方向和模式；正反向跨小节、单拍、弦乐/键盘/打击乐单音；全谱表、全声部、全音轨整小节范围；取消和钢琴下谱表；实际目标可按音轨/谱表/声部集合筛选 | 端点仍同轨、同谱表、同声部；筛选只用于本次读取或批量节拍命令，不改变界面选区；空声部及同前小节端点不扩展 |
| 选区批量编辑 | 实际节拍列表；四声部音乐时间映射、跨轨/谱表时值/附点/连音；清空/删除；音轨、声部和钢琴下谱表筛选及范围外隔离；一次撤销、重做和保存重开 | 最多 128 小节、1024 音轨、完整扫描区域内 20000 拍；跳过空占位拍，拒绝内部占位拍及同前小节；改变时值后需重读实际目标；不增加其他技法的通用批处理接口 |
| 撤销重做 | 元数据、音符增删/修改、时值、附点、节拍插入/清空/删除、小节增删、拍号/调号/反复/小节线、音轨结构及名称/颜色/混音的原生撤销；首音输入重做 | 独奏/静音不入宿主撤销栈；尚未验证所有命令组合、命令合并及多文档历史 |
| 保存 | 当前路径保存、`.gp` 副本、原生另存为、显式覆盖；异步请求与错误对话框控制；保护其他已打开文档；原生部分写入、损坏输出、保存后校验失败及保存/路径通知 C++ 异常时恢复原文件/路径/未保存状态；恢复再次异常时保留备份和写入阻塞，显式重试恢复原生状态且不再次覆盖文件；保存后关闭失败保留文档；撤销重做与保存重开 | 原生保存进度取消列为宿主限制；无可信终态时拒绝修改和自动重放；其他格式、复杂曲谱保真度及外部状态改变后的异常组合归后续验证；重做到保存内容后宿主仍可能标记未保存 |
| 原生剪贴板 | 独立快照及源文档修改/关闭隔离；节拍/全局小节插入、多声部/钢琴/鼓组；跨小节剪切及全音轨整小节替换；1..100 次重复、文本特别粘贴；调弦/变调夹/记谱移调的实音保持；兼容性及上限拒绝；撤销重做、保存重开 | 系统剪贴板仍实验；重复结果限 128 小节/20000 拍；部分小节跨栏替换拒绝；无任意音轨集合剪贴板、键盘到弦乐的指法分配或其余特别粘贴过滤项；快照可能补齐休止 |
| Qt 内省 | 对象、方法、基本属性、动作枚举与有限原生调用 | 不等于全部 C++ 状态；控件属性变化不等于业务模型提交；动作可用性仍受宿主上下文影响 |
| 窗口 | 原生隐藏、最小化、恢复、关闭；后台无文档时保持 MCP 运行；显式关闭主窗口退出宿主 | 主窗口关闭有未保存修改时保留确认流程；退出可能中断最后一个 HTTP 响应 |
| 播放 | 与活动文档 Score 关联；播放/停止、按原谱小节或展开时间线 tick 定位、循环、节拍器、倒计时；反复 3/100 次的长度、定位边界和撤销；音轨音量/声像/独奏/静音；初始速度、单位和标记修改；五种速度单位的帧数、撤销与 GPIF 检查；保留后续独立变速点 | 分段/渐变速度编辑、完整混音/效果、设备、完整循环范围、复杂反复记号尚未覆盖；初始速度值限 1–400 整数，操作可能异步完成 |
| 对象生命周期 | Qt 生命周期钩子和真实事件观察；两类观察列表均保存 QPointer，快照复制已有引用；修复音轨回归中从失效裸指针重建引用的崩溃 | 尚未覆盖全部对象类型、复杂文档销毁、其他 Qt 观察器共存及长时间运行 |

## 尚未完成的原生操作

宿主剪贴板互通已加入仅开发模式可用的 `native_state/native_copy/native_import` 实验接口，未计入已验证范围。已定位并校验 `EditFeature` 的快照所有权；完整隔离测试因本机不能创建 Windows 窗口站而未完成。真实桌面测试曾恢复失败，当前测试脚本已强制独立窗口站，普通桌面会拒绝执行。详见 [宿主剪贴板实验](native/README.md#宿主剪贴板实验)。

| 范围 | 后续需要完成的工作 |
| --- | --- |
| 文件与文档 | 导入和更广泛的共同编辑、模态、GPIF 模型语义及异常组合验证；独立 GUI 多开、原生标签拖动和原生保存进度取消按用户决定列为宿主限制，不再作为 P2 完成条件 |
| 完整乐谱编辑 | P3 按用户确认的必要范围验收；自定义乐器定义、符杠/括号排版和指法搜索不作为 P3 完成条件，相关后续扩展另按 P5/P6 需求处理 |
| 选区和编辑上下文 | P4 按最小必要范围完成；系统剪贴板隔离验证、任意音轨集合剪贴板、其余特别粘贴过滤项和部分小节跨栏替换属于保留扩展，未声明可用 |
| 播放与音频 | 分段/渐变速度、循环范围、完整混音/效果、音频设备，以及复杂曲谱中的时序和反复段验证 |
| 文件导入导出 | MIDI、MusicXML、其他 GP 格式、PDF/图片/音频等原生流程及内容验证 |
| 设置与工作区 | 全局偏好、声音、插件、打印、视图和各类对话框的参数化原生接口 |
| 完整状态 | 按真实用户操作建立清单，为每项状态/修改建立读回和持久化验证 |
| 兼容性与可靠性 | 多文档、并发、长时间运行、取消、异常路径、宿主升级，以及安装和卸载体验 |

## 当前验证证据

### P4 验收

按本次“不要过度设计，能不做就不做”的要求完成必要范围，范围决定见 [P4 计划](DEVELOPMENT_PLAN.md#p4复杂选区与内容转移)。最终构建在 PowerShell 7.6.5 通过 20 组、3956 项回归，`complete=true`、退出码为 0，连接描述已清理：`artifacts/regression-1204f8c47bd54f778f5c17ab010e7dd9/regression.json`。

新增 `native/test-transfer.ps1` 通过 224 项，证据为 `artifacts/native-transfer-71beb2b2ef594e82b2537a510ca1514a/verification.json`。覆盖单拍/小节重复、100 次及 128 小节边界、51 轨片段重复后的 20000 拍拒绝、文本保留与过滤、跨小节剪切/整小节替换、多轨清空/删除、部分音轨/声部与钢琴下谱表隔离、键盘/打击乐单音、不同调弦/变调夹/记谱移调、乐器和原弦可演奏性拒绝、一次撤销/重做和原生保存重开。旧选区 980 项、剪贴板 112 项均在最终构建重新通过。

核心 SHA-256：`1CC3F53C596DBDA772A47C4AD5774E561E4D5F535C5858AD1710253C359EDE0F`；自动加载器：`16A588466C6C3199A55B8DC499C8630B8E9F8FFD0E11685583C5BCC4950C6519`。候选包：`artifacts/GuitarProMCP-0.3.0-9597dd29fefa4766baba900518efa781.zip`，SHA-256：`E2A6999843CF2A43B1E9C74430AED20B888C971A819300EE43B9E435E031D10D`；包内 DLL 与回归构建一致。未更新真实安装目录，P1 仍开放。

保留限制与调查结果：宿主兼容性检查会接受鼓组到吉他的无意义映射，插件已补前置拒绝。`artifacts/native-transfer-323b56aa6f7243b1811d0eda6075e1f0/verification.json` 的旧跨小节替换断言不足，进一步逐音核对发现未选中的末端 MIDI 52 消失；该记录不能证明边界隔离。最终版本拒绝部分小节跨栏替换，要求显式全音轨整小节范围，并断言完整音符序列。首次测试还遇到沙箱禁止宿主自动备份，改为普通用户权限运行隔离副本；失败夹具品位、单音字段、GPIF 文本格式及 PowerShell 保留变量断言均已修正，最终回归重新执行。

系统剪贴板测试入口 `.tools/run-isolated-clipboard.ps1` 在沙箱内外均于 `CreateWindowStation` 失败，在访问当前剪贴板前退出。没有系统剪贴板互通通过证据；`native_*` 仍默认禁用，测试仍要求独立窗口站。本次不搭建独立用户/虚拟机，不增加任意音轨集合剪贴板、自动指法或完整特别粘贴过滤系统。

### P3 验收

P3 已按 2026-09-07 用户确认的必要范围完成。最终构建在 PowerShell 7.6.5 通过 19 组、3732 项完整回归，`complete=true`、退出码为 0，连接描述已清理：`artifacts/regression-ae4ce003bf6c4bd18acd3f8f32a5672a/regression.json`。以下列出本阶段新增能力与保留边界；P2 双版本专项仍对应下方各自的验收构建。

| 操作 | 当前实现与验证 | 限制或剩余验收 |
| --- | --- | --- |
| 音符技法 | `gp_edit_note_effect` 支持弦号或 `note_index`；新增死音、击勾弦、回音/波音、重音类、颤音、8 种滑音、6 类泛音和弯音曲线，逐项修改/清除/撤销/重做/保存重开 | 颤音固定十六分音符；全部技法组合和音源实际效果未穷举 |
| 节拍技法 | `gp_edit_beat_effect` 支持装饰音、扫拨、渐强弱、敲击、八度、死拍、轮指、扫弦指法、摇把揉弦、拍弦/勾弦、琶音、扫弦和摇把曲线 | 琶音/扫弦采用宿主默认时序；装饰音转换改变时值，死拍清空音符，撤销恢复 |
| MIDI 与谱表 | 键盘及打击乐的 MIDI 增删、重复设置幂等、钢琴双谱表及多声部、和弦序号技法；返回弦乐/无固定音高分类及打击乐可用 MIDI | 打击乐选择宿主默认演奏法；内部 `string/fret` 不是实际琴弦/品位；独立演奏法选择未提供 |
| 调弦与移调 | 调弦、变调夹及部分变调夹；保留音高/保留指法；原弦可演奏性预检；区分记谱偏移与实音移调；全音轨及谱表选区一次撤销 | 保留音高要求原弦品位在 0..36，不搜索替代指法；实音移调拒绝打击乐；原生撤销快照可能补齐短声部的休止 |
| 乐器配置 | 复用 `gp_templates`、`gp_new`、`gp_insert_track` 克隆模板或已有音轨；吉他/钢琴/鼓混合曲谱通过 | 任意乐器定义及演奏法配置未实现；混音、音色与效果链另归 P5 |
| 连接与连音 | 沿用已验证的两层比例和跨声部/音轨批量命令；新增八拍连奏、跨小节八音延音链、整链移调及弯音组合的保存重开 | 自定义分组、符杠和括号排版未实现，按用户决定不作为 P3 完成条件 |
| 反复与跳转 | 反复房子 1..8、19 种跳转及逐项清除、同小节多记号隔离；嵌套反复、D.C. al Fine、时间线长度与播放帧推进；记号移动、删除前序小节及小节/音轨结构改变后的自动化引用 | 全部跳转组合与音频交互另归 P5/P7 |

最终回归中的 P3 专项：记谱 627 项，`artifacts/native-notation-236282e496334ac3929d6009778e7c4a/verification.json`；混合乐器 210 项，`artifacts/native-instruments-51e0780104f04c97b3d3fb9b46af0757/verification.json`；结构 307 项，`artifacts/native-score-form-d3d7d348c0c84f78995b6630ace8aaa3/verification.json`。包含原生模型、撤销重做、GPIF、保存重开和播放推进验证。

P3 核心 SHA-256 为 `2AFEC99F536990E0A7C2506A444B152D355D4799F09B73A7F743217D01AEDF19`，自动加载器为 `FC6E027A86D722656CA08560665B839A9146CB789C17F90C9C220DA1C7274F52`。安装包 `artifacts/GuitarProMCP-0.3.0-b2e49e7a7b7a4a14bec0998f211994d7.zip` 的 SHA-256 为 `EA8CCEF423BE8DC4644C21E0C228D184FECDCB3721AA8232452078A0F22BE299`，包内两份 DLL 与验收构建一致。未更新真实安装目录，P1 状态不变。

历史失败保留：结构专项 `artifacts/native-score-form-d2f3deaa91a94e88aef566cae4c07f48/verification.json` 在 147 项后发现跳转清除无效，现已使用原生 `NoDirection` 清除并在同一宏内恢复其余记号。回归 `artifacts/regression-34bf63c4598949f395eb63e8aaf88adf/regression.json` 在 53 项后因自动备份目录写入受限中断；沙箱外启动的自动审批及一次重试曾超时，用户随后明确授权隔离测试副本正常写入其备份目录，最终回归在该环境完成，未关闭全局备份。

回归 `artifacts/regression-f03d7c1a1022432c8174647c5b4e4d4c/regression.json` 发现剪贴板测试的手工占位拍缺少新增默认技法字段，补齐预期后仍按完整模型比较。`artifacts/regression-5327676ac06647d892651b4af83fcc0d/regression.json` 通过全部功能检查，但附加会话的 .NET 进程对象返回空退出码，收尾未通过。测试入口现保留原生进程句柄读取真实退出码，最终回归同时验证正常退出和连接描述清理；这两轮历史记录均不计为完整通过。

### P2 已验收基线

P2 必要范围在 2026-09-07 按用户决定排除三项宿主限制：独立 GUI 多开、原生标签拖动和原生保存进度取消。单实例、多文档、标准客户端、可确认的取消及失败恢复的完整入口为 `native/test-p2.ps1`。最终双版本证据在 `artifacts/p2-6716e7c27dd14c0599dc4c568de4cbcd/verification.json`，全部 14 个构建/执行步骤退出码为 0。

P2 验收核心 SHA-256：`9A6FC7D11C4C87B98838D556DDEE0B9D928B09D6E2831C5F040D1525949C6ACC`；自动加载器：`3F706CE5E0B73515F1766473A682C09F852EBC61183086B54111E8FA30BE3F05`。PowerShell 7 与 Windows PowerShell 5.1 各通过完整功能回归 2588 项、保存恢复 380 项、标签及原生异常恢复 405 项、文档集合变化 397 项、连接/Inspector/DDE 72 项，每个版本 3842 项，合计执行 7684 项。完整功能回归为 `artifacts/regression-64a332ab0d5b43cdbc3e39fde52334db/regression.json` 和 `artifacts/regression-3eb4aa4f71444e1185d08d3578674920/regression.json`；所有测试宿主正常退出并清理连接描述。

保存恢复证据：`artifacts/save-recovery-9dbadcff317d4a61929129ff0efd2ee9/verification.json`、`artifacts/save-recovery-1f923e90c80140baad7e6327ba12159c/verification.json`。标准标签/原生异常恢复证据：`artifacts/tab-recovery-a19cbb62067a44dc870c534c81b39d13/verification.json`、`artifacts/tab-recovery-4d7412538cdb43b1b0fac0968c563458/verification.json`；其中 `throw_after_open`、`throw_after_create`、`throw_close` 均保留异常并确认真实成功终态，`all_documents_closed` 验证全部原对象关闭后恢复与重开。`error_open`、`error_create` 验证只有“确定”按钮的加载错误提示关闭后仍为 `error`，不误报 `cancelled`，不遗留未知结果或文档。部分关闭并新增文档的证据：`artifacts/tab-recovery-92c7c9e3b81149dba94437b3076a27f6/verification.json`、`artifacts/tab-recovery-1eebab63af6f49ed9a5967dea1e83e02/verification.json`。

标准客户端证据：`artifacts/instances-10d101fa7689489eb13758c9d5058822/verification.json`、`artifacts/instances-f35b44e054b7475097617163c0da71df/verification.json`。固定客户端配置也绑定当前 UUID，旧配置在原端口重新启动宿主后返回 409；端口变化后由官方 MCP Inspector 2.5.0 重新导入配置并读取正确实例。未声称运行中的客户端自动刷新配置。

该构建另通过隔离安装 46 项和协议 27 项：`artifacts/installation-2349d95da47b4d95823bc98c70e0c3b2/verification.json`，含显式 `GPMCP_PORT` 冲突时报告 `service_error`、不发布错误描述且保留普通宿主。该检查在现有文件沙箱内运行，恢复隔离宿主 EXE/Qt DLL 后卸载测试插件；不代表 P1 真实安装验收通过。

共同编辑补验通过 8 项：`artifacts/native-coediting-6a31335393474265a7d400d50b166624/verification.json`。实际触发宿主 `actionUndo` 撤销 MCP 元数据编辑，再通过 MCP Redo 恢复，继续编辑并保存副本、原生重开，验证共享历史、内容持久化及源文件不变；宿主正常退出并清理描述。首次文件沙箱内运行在完成编辑/重开后，因宿主自动备份目录写入受限而收尾失败，失败证据保留为 `artifacts/native-coediting-3924216f6c3f433b988f028c8ab633e7/verification.json`；该首次运行不计入通过数量。

不兼容 GPIF 修订的修复前证据：`artifacts/native-load-dialog-05d5b1d5c79e44f7b595862da7b5606a/verification.json`，原生静默结束使请求长期保持未知。新增文档专项各 64 项，验证不兼容/非法 required 修订被预检拒绝、不遗留阻塞，以及 required=13007、recommended=999999 的兼容文件仍可原生打开。P1 真实安装及 P3-P7 不在本次 P2 完成范围内。

### 历史检查点

显式标签恢复检查点的核心 DLL SHA-256 为 `40213CBD82BDAC3EA454A792982E94C039B81E14824F1C8119B82E02D1E814C7`，自动加载器为 `E409DF16F3201CFA37A670A5BF49A59015E5A45E568A3BBEA4381A79CDBBC4CD`，宿主为 `B233B0F1C87DEB3AECE693D51E8D3C3A841C88FEE78828607B20034737C4C6DF`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 各完整通过十六组、2574 项并正常退出：`artifacts/regression-395453faa288485fb67164457b217930/regression.json`、`artifacts/regression-45dd4bebdb514544a7972482058f8a85/regression.json`。两轮源码哈希一致，281 项标签/原生菜单分支均记录 `menu_verified=true`：`artifacts/document-tabs-4e82228ab1a1429a96bfbb686a717687/verification.json`、`artifacts/document-tabs-6fe320c0d61e4d6898964718daf09a3f/verification.json`。

两个版本的标准显式恢复分支各通过 330 项：`artifacts/tab-recovery-8f72e220f904457c801022cbb9fa9643/verification.json`、`artifacts/tab-recovery-aec4e8fe39ca41f185a4746b35969380/verification.json`；部分原文档关闭后的核验分支各通过 327 项：`artifacts/tab-recovery-8d3a10bd36c948d2b282cf7569073bb2/verification.json`、`artifacts/tab-recovery-0455071f91334be096435427efd1952b/verification.json`。标签探针 SHA-256 仍为 `8A835AB1A8DF0D80B4560C9B9EAD614C9150EDBB40DB8FDD5D035FDE3951871C`。同一核心另在 Windows PowerShell 5.1 通过保存故障恢复 265 项：`artifacts/save-recovery-85a38cb13070403a9b98ce81124f4062/verification.json`，保存探针 SHA-256 为 `819A9C1E5A655708053DFE46DEC5EAA0998E01F32CAF5E95C9F1FECE575FAF56`。上述进程均正常退出并清理连接描述，原始夹具未变。

`gp_recover` 验证恢复请求绑定、重复失败时阻塞保持、模态与已完成/过期请求拒绝、恢复后编辑/保存重开，以及原失败和后续恢复历史分别保留。首次原生关闭再取消在 `artifacts/tab-recovery-9dc6e44848ed4907837ecfb54c631807/verification.json` 失败：宿主先关闭三份干净文档，再为唯一未保存文档显示确认框；取消不会重开前三份。恢复现在核验剩余对象、原相对顺序及活动文档，返回 `documents_closed` 与关闭的 UUID，不重开文档或误报完整回滚。该分支验证三份关闭、一份保留，全部原文档关闭尚无专项证据。保存/其他操作没有保留恢复上下文时明确拒绝 `gp_recover`，不会解除未知结果阻塞；这些缺口仍属于 P2。

标签故障回滚检查点的核心 DLL SHA-256 为 `950455B31A9B5E78517CDF23A68C24A8A8DB29B55DEFF1FB4F86EA008C1E41FE`，自动加载器为 `54F2A1A468F3DDA2D4A8A6EB9879D3271FA88A69B4F85535A21DB7AC14CF165E`，宿主为 `B233B0F1C87DEB3AECE693D51E8D3C3A841C88FEE78828607B20034737C4C6DF`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 分别完整通过十六组、2574 项并正常退出：`artifacts/regression-ece4d5f8e8f64b2e8a0af5e1a8038c57/regression.json`、`artifacts/regression-248282b0d46d4d11a1ff829960c98cd0/regression.json`。两轮源码哈希与本检查点一致，标签/菜单专项各为 281 项且 `menu_verified=true`：`artifacts/document-tabs-7e568d4d883d4b158337aa2289a3f4ee/verification.json`、`artifacts/document-tabs-29988c18193d4673a4b63fb3540baeb7/verification.json`。

同一核心在两个版本各通过 303 项标签故障恢复并正常退出：`artifacts/tab-recovery-a2ae563164d74a8c96f7a2df2d7288fc/verification.json`、`artifacts/tab-recovery-bed9ff2417ca4c19bad20c9c6c497d05/verification.json`。探针 SHA-256 为 `8A835AB1A8DF0D80B4560C9B9EAD614C9150EDBB40DB8FDD5D035FDE3951871C`。验证包括完整顺序、活动/非活动标签异常、额外重排、活动文档切换、撤销重做、保存副本重开和后续重试；恢复通知再次异常时如实保留未知结果及写入阻塞。同一核心另在 Windows PowerShell 5.1 通过保存故障恢复 264 项并正常退出：`artifacts/save-recovery-acbd8c29203e43eeb652ff3ad5b93928/verification.json`。上述进程均清理连接描述。

修复前的 `artifacts/tab-recovery-518dba2b610849ecb8a0f0813b941102/verification.json` 证明目标位置正确而另外两个标签被交换时仍误报 `moved`。首次回滚方案在活动文档被故障切换后未能恢复宿主活动文档，失败记录分别为 `artifacts/tab-recovery-20281610a1694c83bc183ab71e6c826f/verification.json` 和 `artifacts/tab-recovery-546c1a8288a548c5a6c65740552c630f/verification.json`。最终实现恢复完整排列后，先同步当前页面对应的原生标签选择，再选回原标签，并核对完整映射和宿主活动文档。`gp_move_document` 同步返回带 `request` 的结果；回滚失败的请求可在 `gp_operation`/`gp_documents.moving` 查阅，并阻止后续修改。回滚再次失败后的状态协调仍待完成，未计入 P2 完成。

保存异常恢复检查点的核心 DLL SHA-256 为 `C6FA4C8CC527E750A3939A7E6589B75762D6BC07F8FB8D4C63FE3C4DCD090345`，自动加载器为 `752C11B40009D362A4CEB48887A081BA581D3F47EB2E837159B979FB4DCACE0F`，宿主为 `B233B0F1C87DEB3AECE693D51E8D3C3A841C88FEE78828607B20034737C4C6DF`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 分别完整通过十六组、2574 项，退出码均为 0 且连接描述已清理：`artifacts/regression-56427ad87d9246caa72515d193b8fe0c/regression.json`、`artifacts/regression-7540a229688648ec86a9201797cd2cfa/regression.json`。两轮源码哈希与当前构建一致，标签专项各为 281 项且 `menu_verified=true`：`artifacts/document-tabs-7d5b373353974bd08fc86a09570031a0/verification.json`、`artifacts/document-tabs-bcc8b58847fa40e8bae9e389d4c16928/verification.json`。

同一核心在两个 PowerShell 版本各通过 264 项保存故障恢复并正常退出，分别见 `artifacts/save-recovery-070d927e63b94067ade50013c961976b/verification.json` 和 `artifacts/save-recovery-f23b76e7202740dfa742615c6db355d3/verification.json`。测试探针 SHA-256 为 `819A9C1E5A655708053DFE46DEC5EAA0998E01F32CAF5E95C9F1FECE575FAF56`。新增六种异常情形，覆盖原生保存通知、打开路径通知及恢复通知：恢复成功时原文件字节、两种路径、未保存内容、撤销重做及重开均已核验；恢复再次异常时保留完整备份及写入阻塞，不能当作恢复完成。该专项仍明确记录完整保存进度取消未验证。

修复前的复现为 `artifacts/save-recovery-cfe6e5ae39ba4fbea7b3df57e5db907f/verification.json`：原生通知抛出异常后，保存结果不明、两种路径不一致、未保存标记被清除，局部备份已在外层捕获前销毁。现在在备份存活期间捕获并恢复，恢复路径通知再次异常也继续尝试恢复未保存标记。独立测试脚本的两次失败另外保留：`artifacts/save-recovery-8d7a94e9a4f74863bccea7d2fe9a933d/` 在最后退出响应断开时中止，已补充退出码和描述清理核对；`artifacts/save-recovery-88dd7edb954c45769724edce93291b1a/` 遇到 PowerShell 5.1 控制文件 `Set-Content` 流错误，已改用 .NET 写入并在两个版本重跑通过。其他未知结果及恢复再次失败后的状态协调仍属 P2 未完成项。

窗口恢复检查点的核心 DLL SHA-256 为 `58A49CDD43C6829C03C4E4E60252A693380769628304EE4EC46BCFB6EC6C567F`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 分别完整通过十六组、2574 项，退出码均为 0 且连接描述已清理：`artifacts/regression-89d802af6b7048c1af5ca9b5b6f98e2a/regression.json`、`artifacts/regression-a9757085257743968b98fd9ffede8d9b/regression.json`。两轮都包含 281 项标签/原生菜单检查，`menu_verified=true`，分别见 `artifacts/document-tabs-a757a290bb3f4346bb3c155d66030314/verification.json` 和 `artifacts/document-tabs-93b5e00541df4318baea186a998b9811/verification.json`；相同核心另通过 Windows PowerShell 5.1 保存故障恢复 167 项并正常退出：`artifacts/save-recovery-bfe0efd62a504dcba05ff2e49774f1db/verification.json`。

反复隐藏后菜单被禁用的原因与修复已经验证：宿主在 Qt 原生焦点窗口变化时重新检查活动主窗口，只有 `showNormal()` 不能恢复该上下文。`restore` 现调用公开的 `activateWindow()`，可将窗口带到前台；后台曲谱接口无需这一操作。回归实际触发三次隐藏/恢复后的五个文档菜单，核对每个目标，并检查隐藏后不占前台、原生关闭确认仍可取消。只读探针调用栈及反汇编证据在 `artifacts/menu-probe-553f7e6f35784b4ea8984a42be527797/`；未直接修改菜单启用属性。其他桌面、窗口焦点策略及全部模态上下文仍需在 P7 覆盖。

另存路径与标签修复检查点的核心 DLL SHA-256 为 `7775931BBE25D049D095887C017F73DE44894416AD8ADC858E3FA45B14814971`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 分别完整通过十六组、2486 项，退出码均为 0 且连接描述已清理：`artifacts/regression-03bca8639e8a447b994d56f49deba77f/regression.json`、`artifacts/regression-b1474eed170c4298bc6d9526fad40170/regression.json`。两轮均记录六次原始夹具恢复；保存专项增加到 47 项，并验证旧路径与新路径的文档身份、中文文件名及原生界面名称。

同一核心在 Windows PowerShell 5.1 通过保存故障恢复 167 项：`artifacts/save-recovery-a706bcc394a04f8bb2bf2eef4b11427a/verification.json`，包括失败后的 `opened_path_restored`。新隔离宿主的原生菜单专项通过 221 项且 `menu_verified=true`：`artifacts/document-tabs-3a21e86f47334806a28be46a4afec6f7/verification.json`；该宿主使用 15000 ms 启动等待并正常退出，退出证据为 `artifacts/save-label-menu-bed7e9d147bf47ef91701d7cc2cd1e85/verification.json`。

首次整套回归 `artifacts/regression-a58ec49485ff46788c1621e7b8397559/regression.json` 停于菜单名称检查：宿主保留已关闭文档的勾选动作，当前标签对应的名称实际正确。保存测试现按当前标签对应动作核验，未放宽菜单可用性专项。额外的三次恢复/隐藏观察中，第二、三次恢复后的当前文档动作仍禁用，原始状态见同一菜单宿主目录的 `menu-cycles.json`；此历史观察不计入通过项，菜单上下文问题由后续窗口恢复检查点修复。

标签重排检查点的核心 DLL SHA-256 为 `35F81B75172BD1CBC5CEA17834C8757D3FF870D7BA3984C361315C84F1F7B355`。PowerShell 7.6.5 与 Windows PowerShell 5.1.19041.6456 分别完整通过十六组、2469 项，退出码均为 0 且连接描述已清理：`artifacts/regression-b2dd344767674bf0b1ef7e8f68a1b724/regression.json`、`artifacts/regression-2d306138117b48409e1a9b64dcf92898/regression.json`。其中标签基础专项为 193 项；另在新隔离宿主执行含原生菜单的 221 项，`menu_verified=true`：`artifacts/document-tabs-cfafc40ebb02415c9a7ae8fd9adc3aad/verification.json`。相同核心在 Windows PowerShell 5.1 通过保存故障恢复 167 项并正常退出：`artifacts/save-recovery-f662e3c6b0e34d8d866d5f8540db3a6d/verification.json`。

标签早期验证发现并修正了模板名称、未保存标记前缀及另存后空提示被误当作文件路径的校验问题；后续保存修复补齐路径通知，解决未命名文档另存后的空标签。原生菜单在反复隐藏/恢复的已有测试宿主中曾保持禁用，相关失败不计通过；新宿主的菜单专项不能证明所有窗口上下文已通过。用户确认原生拖动不改变顺序，插件重排不替代该项验收。同步重排故障回滚、显式恢复重试及部分文档关闭后的状态核验已有后续专项验证，其他复杂文档集变化仍待处理。

`09185ab` 历史构建在 Windows PowerShell 5.1 和 PowerShell 7 下均完整通过十五组、2276 项回归，两轮退出码均为 0，连接描述已清理。证据分别为 `artifacts/regression-9e09be6fb7784486bc7423a8a50cd9f5/regression.json` 和 `artifacts/regression-b7fb07a5f6c14bd5abe4811a36c14159/regression.json`。核心 DLL SHA-256 为 `A22ECD07B9C48776CF25CA1E9FA4A8C650CF9E93841F511380FF97FE7F73227F`。新增 HTTP UTF-8 解码对照检查，修复旧版 PowerShell 的中文路径/工具说明乱码，并让完整测试入口兼容该运行时。

同一构建的保存故障专项在 Windows PowerShell 5.1 下通过 167 项：`artifacts/save-recovery-a9adcab860bc4afd944359d371399572/verification.json`。已验证原生部分写入失败、宿主拒绝损坏输出、保存后校验失败、保存后关闭失败和恢复失败时备份保留；宿主正常退出并清理连接描述。保存错误提示关闭后仍报告 `error`；该专项明确记录完整原生保存进度取消尚未验证。

此前连接及两个客户端并发专项通过 53 项：`artifacts/instances-b41dfdb2831a4167be7453cf8d4907d9/verification.json`。后续确认 `.gp` 文件关联还使用 DDE `[open("%1")]`；单独重复执行 EXE 命令没有覆盖该协议。未加载 MCP 核心的宿主收到空单实例消息后，DDE 才触发文件打开，基线证据为 `artifacts/forwarding-probe-7e502806f8224290bbf07076d1299123/baseline.json`。真实安装入口、独立 GUI 多进程、真实 MCP 客户端配置重新加载、手工标签重排和未知原生结果恢复仍未通过验收。P1 实际安装目录仍为旧版，P2 仍是中间检查点。

`09185ab` 构建的 DDE/连接专项在 PowerShell 7 后台模式通过 61 项：`artifacts/instances-3833810d444349888852106424949221/verification.json`；Windows PowerShell 5.1 可见模式通过 60 项：`artifacts/instances-3b540bd0135545bc965d08b618631733/verification.json`。覆盖中文会话目录和文件路径、错误 DDE 接收进程拒绝、重复打开不重复建文档、并发编辑、重启失效和端口回退。两轮记录的启动等待均为 15000 ms，不代表较早退出已可靠。默认 5000 ms 的两次运行在重启后的宿主退出时仍卡于 `AMNetwork::NetworkServiceGuard`，失败证据和线程栈保留在 `artifacts/instances-69d4f4d62d6141b6b52b1c3fc4271ebd/` 与 `artifacts/instances-70832e139e884a3c895c1ceb8b32c41e/`。

此前回归 `artifacts/regression-d55d5d21f0cb4eaa81a816918169e7cb/regression.json` 在通过 1775 项后停于模板新建检查，保留宿主中已观察到成功创建。模板测试错误地将中间状态 `requested` 当作结束条件，已改为等待明确终态并在失败时输出实际状态。该轮失败记录仍保留，未计为完整通过。

P2 上一检查点十四组回归共 2225 项通过，退出码为 0，连接描述已清理：`artifacts/regression-dd6830958c334f7cb5ad42add6e4bd4d/regression.json`。其中新增保存专项 30 项，证据为 `artifacts/native-saving-b5e392dce3c84e17b2812cc960cd84c3/verification.json`。该轮包含独立文档 UUID 和已退出进程身份识别修复；保存中途失败恢复仍未计入通过范围。

同一构建的连接专项为 53 项通过，包括保留已退出进程句柄时重新接管旧连接描述。PowerShell 7 证据为 `artifacts/instances-d32b829a0032440a86a001624a5d01df/verification.json`，Windows PowerShell 5.1 证据为 `artifacts/instances-5524513fd40d4b2b988926b4abf5fd92/verification.json`。两轮均未将二次启动打开文件或独立 GUI 多进程计入通过范围。

连接专项 52 项通过：`artifacts/instances-019140371f2f41f882a28657709dbe21/verification.json`，覆盖发现去重、两个客户端同时编辑同一或不同文档、错误实例拒绝、重连、重启后旧文档 ID 失效、端口回退和退出清理。此记录对应保存功能加入前的构建。旧版 `test-instances.ps1 -CheckLaunchForwarding` 仅重复执行命令行，在后台和可见模式均未打开第二份曲谱，可见模式失败证据为 `artifacts/instances-fa5b0650158348838bc0f681a3f46daa/verification.json`。该失败记录保留；新版专项按实际注册协议加入 DDE，并核对接收进程与文档内容。

P1 候选检查点 DLL 的十三组回归共 2195 项通过，进程退出码为 0 且连接文件已清理，证据为 `artifacts/regression-f1463f227d554ba0b74060538e9ff651/regression.json`。安装检查 43 项及协议 26 项、安装文件归属和配置检查 23 项通过。阶段状态和安装包见 [开发计划](DEVELOPMENT_PLAN.md)。实际安装目录仍为旧版，最终真实启动入口验收尚未完成。

启动后立即关闭存在独立的宿主网络线程等待问题；仅使用 Qt 关闭窗口的探针、不加载 MCP 核心也能复现。证据及线程栈位于 `artifacts/exit-baseline-ee2f813e0b8343d7856fa611439c315e/`。普通编辑回归正常退出不代表快速启动/退出稳定性已经通过，该问题仍保留在发布验收范围。

2026-09-07 新增连奏与延音线专项 153 项，最新证据为 `artifacts/native-connections-ce6b417d13c046e0a4703353b0121ca9/verification.json`。十三组累计 2195 项通过。专项覆盖原生连接两端、音高变化、单音隔离、多声部/音轨和钢琴谱表，并独立读取 GPIF 和原生重开曲谱。

此前 DLL 的八组回归共 1784 项通过：连接 153、协议 26、原生后台 26、节拍编辑 58、音符技法 254、选区 980、插件独立剪贴板 112、连音 175。汇总文件 `artifacts/native-connections-ce6b417d13c046e0a4703353b0121ca9/regression.json` 记录各项证据、宿主 PID 及 DLL/相关源码哈希。真实系统剪贴板不在该轮测试中。

同日新增原生连音 175 项，最新证据为 `artifacts/native-tuplets-b7423876dcd8420e9e36b829fa92040a/verification.json`。该轮协议 26、原生后台 26、节拍编辑 58、选区 980、插件独立剪贴板 112、连音 175，共 1377 项通过；节拍批量分发修改后的现有操作回归通过。

2026-09-07 在默认配置重新运行协议 26 项、原生后台 26 项、插件独立剪贴板 112 项，共 164 项通过。另确认三项实验性 `native_*` 操作在默认模式下拒绝执行，且插件缓冲区不变。该轮原生证据为 `artifacts/native-verification-19374c9022ec416ea4d36317884fd6f6/verification.json` 和 `artifacts/native-clipboard-6dd5d970ccb34e99b7028e3131c22f67/verification.json`；没有将未完成的宿主剪贴板验证加入历史累计数。

- `native/test-mcp.ps1`：27 项协议、会话、鉴权、消息分帧、参数边界和 HTTP 客户端 UTF-8 解码检查。
- `native/test-native.ps1`：26 项真实宿主后台检查，读取保存文件内部的 `Content/score.gpif` 验证标题和音符变化。
- `native/test-editing.ps1`：58 项单拍音符/节拍编辑、无效参数、撤销重做、GPIF 音符引用和附点时值检查。
- `native/test-tracks.ps1`：90 项音轨新增/复制/删除/交换、零轨恢复、跨文档配置复用、名称/颜色/混音/播放状态、无效输入、撤销及 GPIF 持久化检查。
- `native/test-measures.ps1`：118 项拍号/实音调号边界、小节隔离、音高与拼写、反复/小节线/自由拍号、撤销和 GPIF；反复 3/100 次时的时间线、绝对 tick 定位和小节偏移越界检查。
- `native/test-effects.ps1`：254 项音符技法检查，覆盖 21 种非默认取值、清除、重复设置、单音/声部/音轨隔离、光标不变、撤销重做、逐项 GPIF 和组合技法的原生保存/重开。
- `native/test-selection.ps1`：980 项原生选区和批量时值检查，覆盖方向、端点、全选、模式复位、和弦/第二声部/其他音轨单音、无效输入、实际目标位置、四声部音乐时间映射、跨轨整曲和单小节、钢琴双谱表、128 小节限制、临时占位拍清理及重建、宏命令一次撤销、重做、重复写入和原生保存/重开。
- `native/test-saving.ps1`：47 项当前路径保存、显式覆盖、目标保护、写入前拒绝后的状态保留、两种路径及标签/提示/窗口/对应菜单名称更新、中文文件名、旧路径独立打开、新路径复用及保存重开检查。
- `native/test-save-recovery.ps1`：独立隔离宿主中的 264 项原生部分写入失败、损坏输出、保存后校验失败、原生保存/路径通知异常、恢复再次异常时保留备份与写入阻塞、错误提示控制、保存后关闭失败、撤销重做、再次保存重开及正常退出检查。使用单独构建的测试探针，不包含于常规回归或生产安装包。
- `native/test-tab-recovery.ps1`：独立隔离宿主中的 330 项完整顺序、故障回滚、显式恢复重试、过期及重复请求、模态保护、内容/撤销隔离、恢复后编辑保存重开及请求历史检查；`-CloseCleanDocuments` 分支为 327 项，另核验宿主关闭干净文档后取消确认、剩余文档状态及原关闭结果保留。独立构建探针不进入生产包。
- `native/test-document-operations.ps1`：50 项请求状态、保存/丢弃/取消关闭、原生确认与取消、过期请求隔离、64 条历史淘汰及损坏 ZIP/GPIF 拒绝检查。
- `native/test-document-tabs.ps1`：基础 196 项插件重排、同名及未命名文档、四份未保存曲谱、稳定身份、活动文档保持、撤销重做、可见标签坐标、模态恢复/拒绝/取消、保存重开与关闭隔离检查。`-VerifyDocumentMenu` 扩展至 281 项，逐项触发三次隐藏/恢复后的原生菜单并核对目标和后台焦点；`test-all.ps1` 默认启用此分支，失败不计通过。
- `native/test-lifecycle.ps1`：40 项定向关闭、未保存修改保护、旧 ID、无文档时继续服务、重开和窗口恢复/隐藏检查。
- `native/test-session.ps1`：103 项原生打开、重复打开、反复切换、声部导航与编辑隔离、播放控制器关联、定位及播放/停止、初始速度与单位修改、撤销和保存、后续变速点保留检查。
- `native/test-structure.ps1`：60 项模板新建、占位拍首音、跨文档未保存标记、节拍插入、小节管理、多音轨及钢琴上下谱表编辑隔离检查。
- `native/test-clipboard.ps1`：112 项快照独立性、源文档关闭、单小节插入/替换、单/多声部及多轨剪切、多轨/跨小节插入与原内容顺移、空白目标、钢琴谱表隔离、兼容性拒绝、撤销重做和原生保存重开检查。
- `native/test-tuplets.ps1`：175 项比例与参数边界、两层独立编辑/清除、嵌套、跨小节/声部/音轨、钢琴谱表、选区外隔离、时值/附点保留、重复写入、一次撤销/重做、GPIF、原生保存重开及插件内复制粘贴检查。
- `native/test-connections.ps1`：153 项连奏与延音线检查，证据在 `artifacts/native-connections-*/verification.json`；包括原生重复命令的无模型变化及撤销记录行为。
- `native/testdata/minimal.gp`：项目生成的简单夹具，1 条音轨、2 小节、8 个音符。
- `artifacts/native-verification-*/verification.json`：每次运行记录宿主 PID、前台 PID、修改前后模型、保存结果和源文件哈希，不记录访问令牌。
- 同目录的 `edited-copy.gp`、`edited.gp`、`restored.gp`：可在 Guitar Pro 中检查的输出。
- `artifacts/native-editing-*/verification.json`、`artifacts/native-tracks-*/verification.json`、`artifacts/native-measures-*/verification.json`、`artifacts/native-effects-*/verification.json`、`artifacts/native-selection-*/verification.json`、`artifacts/native-lifecycle-*/verification.json`、`artifacts/native-session-*/verification.json`、`artifacts/native-structure-*/verification.json`、`artifacts/native-clipboard-*/verification.json`、`artifacts/native-tuplets-*/verification.json`、`artifacts/native-connections-*/verification.json`：各原生功能检查的模型与保存证据；包括协议检查在内，十三组累计 2195 项通过。

早期 Python/原始 TCP 桥接的测试记录不能作为当前 C++ HTTP 服务器的验证证据。临时 RTTI 扫描只能帮助定位对象，不能直接用未经验证的扫描路径执行生产写入。
