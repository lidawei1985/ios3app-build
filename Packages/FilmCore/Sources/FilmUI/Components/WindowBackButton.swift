import FilmCore
import UIKit
import os

/// 全局构建标记：随每次发包手动递增。
/// 播放器打开时闪现 + 设置页常驻，用于一眼确认手机上实际运行的包版本。
///
/// 序号对照（2026-09-22）：
///   35 = 自定义源/成人源合并
///   36 = 播放器层（去黑框·按钮放大·单击暂停·长按2x·画面比例·AirPlay·分享）
///   37 = 检索与体验批次1（拼音首字母检索·搜索联想·长按菜单·迷你播放条·外观跟随）
///   38 = 体验批次2（首屏骨架屏·榜单页·演员作品墙·分类排序·热度口径）
///   39 = 检索升级（拼音：演员/导演可搜·热度排序·ü 的 v/lu 双通道·结果标注命中人物）
///   40 = 索倪源三端分派（NavPolicy：三端导航大类合并 + 端隔离闸门 + 4K 同片升画质）
///        + 返回键对齐大牌（小白箭头无黑框·随控件层自动显隐·点返回不再卡住/丢失）
///   41 = 内置源可见性修复（墓碑按「线路/点播源」拆两套·恢复入口置顶常显·内置行加标签
///        ·心屋空线路说明化·线路行删除键移出激活按钮）+ 全局构建标记
///   42 = 分类归并落地（用户：「打开我的分类看到三个分类，应该都是属于伦理下面的，
///        像日本伦理、西方伦理」/「情色就是三级片，应该和港台三级、三级合并」
///        /「两性课堂不就是成人动漫吗」/「真动画片还在还占个分类」/「而且还不能翻页」）
///        —— 新增 NavCatalog 归并层（分类总览/首页导航/分类浏览三处统一走）；
///        三级组吃进情色·成人动漫组吃进两性课堂·成人端挡掉普通动画分类；
///        分类浏览页新增真页码翻页（上/下一页 + 页码 + 首页/末页）。
///   43 = 搜索穿透到源（用户：「别不三级蜜桃成熟时我搜索是不是得能看到找到」）
///        —— 原「电视剧网络源搜索」仅星幕可用 → 扩到三端：成人端搜索倪+成人源、
///        心屋搜共通源、星幕搜剧集源+共通源；结果过 NavPolicy 端隔离，多源合并去重。
///   44 = 直播「一直缓冲中」根修（用户：「直播一直卡着不动，一直缓冲中…我们的采集器不干活吗」）
///        —— 采集器只管片库元数据、不参与播放，卡顿是播放器侧三处硬伤：
///        ① 缓冲只给 2 秒（抖一下就停且不回头）→ 改 8 秒 + 出画后开「自动等待以最小化卡顿」；
///        ② 卡住只会找「同名备用线路」，单线路频道（索倪/星秀）直接 return → 永远缓冲
///           → 新增 `reconnectSameURL()` 原地重连；
///        ③ 恢复链改为「原地重连×2 → 同名备线×2 → 跳台」，计数只在真出画时归零（有上限、不无限重连）。
///   45 = 播放器「黑框」治理（用户：「暂停以后超大个黑框基本满屏了能不能不要呢」
///        +「那个框的闪动不正常一闪一闪的」）
///        —— 根因：① 顶栏/底栏的渐变挂在满屏 VStack（内含 Spacer）上 → 两条渐变各铺满整屏，
///        叠加后画面从上到下全暗；② 切线路提示 = LoadingView 撑满 + 满屏黑 0.6 → 每次切线路整屏黑一下。
///        修法：渐变各限高（顶 160 / 底 220）；切线路改小卡片（保留居中控钮「无底框」观感）。
///   61 = 直播「卡一会儿才播 / 换台卡」根治（用户：「还是会卡很久才会播 换台也是卡住在屏幕能看见内容
///        但是卡一会才能正常播放」「要先把返回键还给我」「返回键点不动」）
///        —— ① **源侧**：重算主源，按「分片时长→首包耗时→时间新鲜」排序（原表中位分片 7s、最大 20s，
///           必须下满一整片才出画 → 这是"卡一会儿"的直接原因）；同台备线隐藏、点 ⇄N 展开；
///        ② **播放器**：换台先彻底断旧流（pause + replaceCurrentItem(nil)，否则旧流抢带宽/抢解码器）；
///           起播低延迟三连（低码率变体 + 零缓冲目标 + 不等待）；出画后**不再**抬高缓冲门槛（旧逻辑 8s 是卡顿源）；
///        ③ **提速**：呼出列表/开播时预热邻近台 playlist（命中缓存省 DNS/TLS 一跳）；
///           起播 3s 无进展即换源（原 5s）；
///        ④ **返回键**：恢复**窗口级 UIKit 返回键**（物理免疫被全屏手势层吞掉 tap），
///           列表打开时关掉全屏点屏手势层（它正是吃掉返回键点击的元凶）。
///   22 = 直播页返回键两病根治（用户：「返回的那个按钮是一大一小叠加在一起的」
///        +「点不了 基本就是卡死的状态…如果出现这种情况想退出都不行」）
///        —— ① **一大一小叠加**：窗口级 UIKit 箭头与 topBar 里的 SwiftUI 箭头同显隐、同位置，
///           两个箭头错位叠画 → 现只要窗口级按钮**在位且未挂载失败**，topBar 只留 44pt 占位不画箭头，
///           视觉只有一个返回键，点击统一走窗口级（物理免疫 LC 吞 tap）；
///           ② **卡住退不出**：旧口径返回键显隐只看 `showList || controlsPeek`，控制层 3 秒收起后
///           窗口级按钮一起隐形，屏上唯一可见的「返回」是会被 LC 吞 tap 的 SwiftUI 按钮 → 现引入
///           唯一口径 `backVisible`（控制层可见 **或** 缓冲/起播换台/彻底失败），这些状态下返回键常驻；
///           ③ 窗口级按钮新增「挂载失败回调（onGiveUp）」，24×50ms 重试仍挂不上时把 SwiftUI 箭头
///           放回来兜底 —— 否则「有窗口级按钮就不画箭头」会退化成「一个返回键都没有」。
///   23 = 播放器两病（主人：「音量键不流畅且不同步 / 最小不显示静音」+「上次播放进度又不能了 又从头播放了」）
///        —— ① **音量条不同步**：KVO 拿到 `change.newValue` 却丢掉，回读 MPVolumeView 内置 UISlider.value，
///           而那个 slider **滞后于系统音量** → 每次读数停在上一格（端上＝按键跟不上手），
///           到最小也停在倒数第二格 → `v <= 0.001` 不成立 → **静音图标永不出现**。
///           改法：直接用 newValue（系统真值）。
///        ② **续播又从头播**：09-30 版「等 readyToPlay 再 seek」方向对，但容差给了 `.zero`
///           —— 远端 HLS 目标分片未就绪时该次 seek 返回 finished=false 且原地不动，旧实现不看回调
///           → 在慢源上「续播」一次都没生效。改法：±0.5s 容差 + 以完成回调为准 + 最多重试 3 次 + 确认后才清 pendingResume。
///   24 = 四事一并（主人：「锁屏横竖屏锁不住」「直播还是不好用 我要看上直播」「续播也没生效」「主视觉混进不清的海报」）
///        —— ① **方向锁真锁住**：`requestGeometryUpdate` 只是"请求"，被系统竖屏锁/宿主静默忽略；
///           改走 AppDelegate `supportedInterfaceOrientationsFor`（系统每次转屏必问的唯一口子）
///           + 全局 `OrientationLock` 单一真源 + `setNeedsUpdateOfSupportedInterfaceOrientations` 强制重问；
///           退出播放**先解锁**（旧写法 locked 时 setLandscape 直接 return，锁被带回主界面）。
///        ② **直播择优起播**：离线地表 `live_health.json`（三级真出流实测 318/619 条活线）——
///           热门台几乎只有 1 条活线且**不在第 1 位**（CCTV-1/湖南卫视＝第 3 条才活，广东卫视 6 条全死）；
///           起播前：当前线在地表活 → 直接播；不确定 → **并发探活本台全部线路**（2.2s 封顶，首个出流者用），
///           把"撞死线干等 8~40 秒"压到"两秒内"。只在本台内换线，绝不跳台、绝不改源。
///        ③ **续播补全**：KVO `options` 补 `.initial`（挂观察前已 readyToPlay 就永不回调 → 定点从没跑过）；
///           周期观察每 0.5s 兜底补定点；`handlePlaybackFailure`/`switchToLine` 在定点未落地时
///           **不许把点位冲成 0**；`play()` 显式清 pendingResume（防切集误用旧点位）；
///           DetailView 按历史 `lineIndex` 回填起始集（剧集续播不再回第 1 集）；决策全链写 `resume.traceLog` 可取证。
///        ⑤ **生效线路面板去灰**（主人：「生效线路选择面板还是灰色的」）：
///           `StatusPickerSheet`（标题就是「选择生效线路」）用的是默认档 `.regular = thinMaterial`，
///           而材质会把底下彩色底**去色** → 渲染成中性灰。已玻璃化的点播源格（SettingsView:227）
///           与源格子（SiteBrowseView:373）早已换 `.clear`，唯独这处漏改 → 补齐同一口径。
///        ⑥ **「点 1 得到 2」取证 + 主视觉确定化**：给 `DetailRouter.open` 加**点击痕迹**
///           （写 `taptrace.log`，可从手机容器拉回）——痕迹=片2 → 命中测试送错；痕迹=片1 → 弹层没换。
///           两种病修法不同，不许靠猜。主视觉点击从 `TabView` 内部提到外层 overlay：分页 TabView
///           会同时渲染相邻页、由 UIScrollView 接管触摸判定，换页期间 hit-test 会落到邻页按钮
///           → 看到第 1 张却开第 2 张。现以 `items[index]`（当前选中页）唯一决定落点。
///        ⑦ **直播保鲜防退化**（本机实测）：干跑一次 `live_build_fast.py`，2515 条候选只体检出
///           328 条活线 → 成表 311 台，而线上现表 597 台（CCTV-1~17 全在）；旧闸门只卡
///           「活表<300 不推」，328>300 会放行 → 一推就少掉一半台。闸门改为**与现表对比**（<90% 判退化不推）。
///   26 = 三事（主人：「点 1 得 2 三处都犯」「直播要能一直用、不用人维护」「下载 24 分钟太慢」）
///        ① **「点 1 得 2」三处结构性加固**（不再靠猜，按两类可能病因一起堵）：
///           · **身份串台**：`PosterRail`/`PosterGrid` 先按 `dedupId` 保序去重，且 `ForEach` 的 id
///             从 `dedupId` 改成**下标**（下标天然唯一）——同一部片来自不同源会产生重复身份，
///             SwiftUI diff 复用时"看到 A、点到 B"，这一整类病连根拔掉。
///           · **弹层不换内容**：`.id(item.dedupId)` 从 `DetailView` 提到 `NavigationStack` **最外层**，
///             换片必重建整棵树（原先只加在内层，外层壳子仍可能被复用、拿旧内容顶上来）。
///           · **轮播换页竞态**：主视觉 5 秒自动翻页、换页动画 0.45 秒；手指按在第 1 张、
///             翻页把第 2 张推到眼前再抬手 → 开错片。加**换页后 0.6 秒不吃点击**的上膛闸
///             （宁可这一下没反应，也绝不能开错片）。
///           · 取证补**展示痕迹** `taptrace.present`：tap=片1 & present=片2 → 弹层没换；
///             tap=片2 & present=片2 → 命中测试送错。两种病一次定案。
///        ② **直播保鲜改「合并提优」，不再「重建替换」**：旧流程探不到活线就**整台丢掉**，
///           一轮下来 597 台只剩 311 台 = 自己把表刷坏，所以闸门只能一直拦、保鲜实际是停摆的。
///           新流程：活线排前面当主源 → 原表这台剩下的线路排在后面当备线 →
///           本轮完全没探活的台**整台原样保留**。台数只增不减，才谈得上"不用人维护"。
///        ③ **产物下载提速 21 倍**：GitHub artifact 302 到 Azure Blob **按单条连接限速**
///           （实测单流 37 KB/s → 52MB 要 24.7 分钟）。新 `dl_art_fast.py` 并发分片 + 逐片重试
///           + 尺寸/CRC 双校验，实测 **53MB / 69 秒 = 784 KB/s**；失败自动退回旧的 `dl_art35_v2.py`。
///   27 = **搜索提速 8.8 倍**（主人：「搜索好慢 你自己试试搜索时的速度有点说不过去」）
///        实测 78 个内置源同搜一个词：中位 2.0s、但**最慢 38~50s**，≥22s 的有 6 个。
///        病灶不在带宽而在**结构**：旧实现 `batchSize=12` 分 7 批，而批内必须**等最慢那个源**
///        才回调 → 慢源被重复计 7 次，6 个真实词实测总耗时 **49.5~90.5s（平均 70.1s）**。
///        三刀：① **不再分批**，全量一次并发（各源之间毫无依赖，分批纯属自己拖自己）；
///        ② **边收边上屏**，`group.next()` 回一个就上屏一个 → 首屏 = 最快那个源（0.42s）；
///        ③ 搜索单独走 **8s 短会话**（分类/详情仍 30s），并有 6s 交互预算，到点 `cancelAll()`
///        不再为长尾源干等（被预算取消**不记熔断**，否则每轮都会把"还没轮到"的源误沉底）。
///        改后总耗时 **8.0s**，首屏 0.42s。
///   28 = **生效线路面板「透明看不清」三修**（主人：「生效线路选择面板透明了！看不清楚」）
///        上一刀（v25）只把面板自身改成 `.clear`（不挂材质 → 不去色、不发灰），
///        却漏了 **sheet 背后**仍是 `.presentationBackground(.clear)` = 全透，
///        而面板自身又是「只叠 0.06 白」的纯透明档 → **底下没有实底**，
///        设置页一级页的内容直接穿透上来，两层字叠一起就看不清了。
///        同坑 `SiteBrowseView` 10-01 已踩过并修好（当时报的是「变成纯透明的了」），
///        这次照搬同一口径：`presentationBackground` 垫 `TintBackgroundView`（自带不透明底
///        #0A0A0D，且与页面同取色源）→ 盖住穿透、面板照旧跟海报变色，不退回灰块/黑框。
///        教训：改"玻璃"不能只改面板自己那一层，**浮层的底在哪一层要一并看**。
///   29 = **继续观看「点 1 得 2」根修**（主人：「点海报还是点 1 打开 2」）
///        真机点击痕迹 + 可视化复现：.sheet(item:) 在 sheet 已展开时换片会复用同一
///        sheet 视图实例，DetailView 的 @State 停在旧条目，导致视觉上旧详情卡被顶上来。
///        `DetailRouter.open` 改为「先关再开」，强制 sheet 重新创建、@State 重新初始化；
///        同时 `PosterRail`/`PosterGrid` 的 ForEach id 从「下标」改回「dedupId」（经
///        `dedupKeepOrder` 去重后已天然唯一），杜绝 LazyHStack 视图复用时 Button action
///        闭包捕获旧 item 的隐患。
///   60 = **全局 UI 一致性批次**（主人钦定铁律：「能不要框的不要框；必须有框的一律玻璃化，
///        不许深灰实底；横竖屏一个面孔」· 13 项审计全改）：
///        A1 详情页顶栏按钮横竖统一纯图标+投影；A2 直播页竖屏并入横屏逻辑（纯图标+点屏呼出+
///        超时隐藏+缓冲提示 .dark 玻璃）；A3 频道列表两副面孔合一（黑板退役，竖屏复用悬浮玻璃卡）；
///        A4 悬浮卡/台名条玻璃化（透视频色相）；B1 详情页线路 chips/选集格、B3 分类页筛选 chips、
///        B4 设置页卡片、B5 我的页（标签统一形态+底部按钮）、B6 搜索框（含首页搜索入口）全部
///        换 `.clear`/`.dark` 玻璃档；B7 直播缓冲框 .dark 玻璃+圆角；C1 横屏搜索页「搜索」标题
///        压输入框根治（撤系统导航栏、标题自绘独立行，首页搜索入口改切 tab）；C2 热搜榜配色
///        复核（真机像素取证 Top3 已统一红，审计描述与截图不符，未改码）；C3 频道分类列定宽+
///        emoji 台标清洗（groupLabel）；C4 我的/设置页底部补 tabbar 高度安全区（横屏黑条切内容根治）。
public enum AppBuildInfo {
    public static let mark = "v76.5"
    // v76.5（2026-10-05）：★★ 装饰一次复用（真正的漏点）+ **回退 v76.4 的负收益改法**。
    //   v76.4 真机复测（黑匣子，同口径）：`首页·货架计算 2468ms` / `主线程·卡 2023ms`
    //   —— 比 v76.3 的 2149ms / 1729ms **反而慢 0.3s**。即 v76.4 那三刀里有一刀是错治：
    //     · `isAnime` 拼接法：**负收益**。首页自 v76.3 起 `allowsOnHome` 已改成「全量只过滤
    //       一次」，9 万条每条只调一次 `isAnime`；而绝大多数条目**不是动漫**（须查满全表才
    //       返回 false），拼接法对它**无条件**把 5 组名字拷进新串（多次 realloc）再搜更长的
    //       串 ⇒ 比「直接搜短串、命中即早退」更贵。（v76.4 沿用了 v76.3 之前「每排调用」的
    //       旧前提，事实已变。）**已回退**为无分配早退版。
    //     · `allowsOnHome` 黑名单快路径：中性偏正，**保留**。
    //   ① 真正的漏点：v76.3 只把 `allowsOnHome` 降为「全量一次」，但 `decorate`
    //      （现算 有效年份/热度/评分）**仍然每排各来一遍** ⇒ 8 排 × 8.7 万条 = 约 70 万次
    //      `year.prefix(4)` 字符串切片 + `Int()` 解析 + 结构体构造。这正是 v76.4 分段里
    //      「各排合计 831ms」的主成本。现在 `decorate` 只算一次、8 排共用（纯函数，可证等价）。
    //   ② `.genre` 排去掉每条的中间 `names` 数组（只查 4 组名 aggregate/original/normal/
    //      canonical，与旧实现完全一致 —— 旧实现本来就不含 `tags`，不得顺手加上）。
    //   ③ 分段计时新增「装饰=…ms」项，下一轮直接看剩余耗时落在哪一段。
    public static let markNote = "v76.5 装饰一次复用+回退isAnime拼接"
    // v76.4（2026-10-05，★ 其中 isAnime 拼接已被 v76.5 回退）：三刀 = isAnime 拼接 +
    //   黑名单快路径 + 分段计时。复测证明只有「黑名单快路径 + 分段计时」有效。
    //   保留此记录以警示：**优化前必须先确认真实调用次数**（旧注释的前提可能已失效）。
    // v76.3（2026-10-05）：★★「全量货架计算 9.5 秒 / 主线程冻 9 秒」根治（纯性能，零语义变更）。
    //   v76.2 复测铁证（黑匣子）：快照解码已修好（`快照·load ok … items=89817`、
    //   boot 累计 35773ms → 6729ms、syncAll 段 32122ms → 26ms），但**仍剩**：
    //   `首页·货架计算 9494ms items=89817` + `主线程·卡 9029ms（启动后 14.1s）`。
    //   三次启动的卡顿时长随目录条数**严格线性**：9945→973ms / 19998→2254ms / 89817→9029ms
    //   （≈0.1ms/条）⇒ 主线程不是自己在算，是被同一时间窗的后台重活拖住（纯 CPU + 百万级堆分配
    //   顶住内存分配器/内存带宽）。为此新增 `HeavyWork` 探针，看门狗日志改为
    //   「卡 Nms + 并发重活=… + 窗口动作=…」，下次能一眼对上责任重活。
    //   9.5s 的成本拆解（源码逐行为据）：
    //     ① `effectiveYear` 每次调用都走 `Calendar.current.component(.year:from:)`，
    //        而它在排序比较器里被调 O(n log n) 次 → 单次全量计算上百万次日历运算（≈5~6s，头号成本）；
    //     ② 首页 8~10 排每排都把**同一份全量目录**重扫一遍 `allowsOnHome`
    //        （含逐条 isAnime 数组分配 + URL(string:) 解析）→ 近 80 万次重复判定（≈2s）；
    //     ③ `isAnime` 每条都构造一次 names 数组（72 万次分配）。
    //   修法：年份进程内 30s 缓存 + 排序用「装饰结构体」预计算 year/votes/rating
    //   （比较判据、顺序、短路全部照抄原实现 ⇒ 比较结果序列不变 ⇒ 排序排列不变）；
    //   `usable` 池在 computeShelves 里只过滤一次，8 排共用；isAnime 改无分配早退判断。
    //   预期：9494ms → 约 1s 量级。
    // v76.2（2026-10-05）：★★ 冷启动卡顿/直播加载慢的**真根因修复**（一行键映射，零语义变更）。
    //   铁证（v76.1 黑匣子）：`快照·load 解析失败 152977723B ... err=DecodingError.keyNotFound:
    //   Key 'noPlayURLCount' not found ... Path: ledger` —— 146MB 磁盘快照 **100% 解码失败**。
    //   根因：FilmJSON 用 convertToSnakeCase 编码 / convertFromSnakeCase 解码，这对策略**不互逆**：
    //   `noPlayURLCount` 编码成 no_play_url_count，解码回来是 `noPlayUrlCount`（URL→Url）≠ 属性名。
    //   后果链（就是主人报的三个症状）：快照用不上 → 目录停在 2 万条内嵌档 →
    //   syncAll「本地已全量级」闸门不成立 → **每次冷启动重拉 180 片≈150MB**（实测本段 32s／v76 那轮 91s）
    //   → 重算 9 万条 + 重编码写回 146MB（enc=6578ms）→ 与货架计算抢核抢内存 → 主线程卡 9 秒
    //   （实测 主线程·卡 9044ms）→ 启动期 6 条并发连接吃满带宽 → 此时进直播「加载很慢」。
    //   修法：给 DataLedger 的 noPlayURLCount / duplicateIDCount 显式声明 CodingKeys
    //   （stringValue 写**策略转换后**形态 → 磁盘键名一字不变，旧 146MB 快照直接可读，向后兼容），
    //   与 FeedPlay.defaultURL（2026-09-22 同款审计）一致。另加 `DataLedger.selfCheckRoundTrip()`
    //   启动自检（微秒级）写黑匣子 —— 以后再有人加 URL/ID 连写字段，第一轮启动就报 FAIL。
    //   未改动（同病但与本症状无关，按「宁可不治不能错治」留待单独授权）：
    //   TVBoxConfig 的 ActiveState.activeURL/activeRepoURL/activeBuiltinRepoURL、
    //   TVBoxLiveGroup.m3uURLs、BackupPayload.activeURL/activeRepoURL —— 见交接卡待办。
    // v75（2026-10-05）：★远端保鲜从未成功真根因修复 —— Swift 字素簇陷阱。
    //   "\r\n" 在 Swift 是单个 Character（UAX#29），CRLF 文本中不存在独立 "\n" 字符，
    //   M3UParser 的 split(separator: "\n") 把 1469 行远端表整文件当一行、# 开头被跳过 → 恒 0 条。
    //   v74 黑匣子实锤（三基址 200+解密成功+解析0条）而包内 LF 快照正常、PC Python 复刻 688 条。
    //   修复：parse 入口行尾归一化（LF/CRLF/CR 通吃）+ flexibleURL 百分号编码兜底
    //   （云端表 ~45 条中文 query URL 此前被严格版 URL(string:) 静默丢台）。
    // v70（2026-10-05 00:4x）：★直播崩坏回滚 v65 秒播 —— automaticallyWaitsToMinimizeStalling
    //   恢复 true（两处：LiveView.startPlayback / LivePlayerScreen.start）。
    //   铁证：端上 livediag.txt 281 条错误全是「未出画 itemStatus=1 buffered=5.9s → 看门狗换线」
    //   +「CCTV-4 -11833 Cannot Decode」；数据在到、首帧不出 → 无限跳台 = 主人「原来还能看就是慢 现在看不了了」。
    //   v64（true）= 慢 3~8s 但能看；v65（false）= 秒播没成、直接不能看。回滚保能看。
    // v64（2026-10-04）：① 主视觉「先对后错」根治 —— Hero 层序由 heroHD 打头改为**真热门优先**
    //   （此前 heroHD 恰好 15 条 2026 冷门剧占满，`heroPool.count < 15` 判假 → ②③ 永不执行，
    //   710 部真热门被挡；内嵌快照时 heroHD 空又落回②露出《沙丘2》→ 层序翻转 = 主人所见"先对后错"）。
    //   ② HeatIndex 资源加载补 `subdirectory: "Resources"`（包内路径 FilmCore_FilmCore.bundle/Resources，
    //   原代码只查根 → 空表 → 回填静默失效）。③ 卡死根治：分类页 8.5 万条排序 / 榜单 8.5 万条
    //   bestPosterURL 过滤 两处主线程重活挪后台（主人「我看货架直接卡住划不动」）。
    // v63（2026-10-04）：主视觉左右箭头彻底去底座（主人「要透明或者没有那圈」）。
    // v62（2026-10-04）：漏网灰底清扫（主人点名主视觉左右箭头）+ 全仓扫描兜底。
    //   根因同一类：`.filmGlass()` 不传 weight 走默认档 `.regular`（thinMaterial+白渐变），
    //   材质把底色去色 → 灰块。全仓扫描「未显式指定 weight 的 filmGlass 调用」共 5 处：
    //   · HomeView 主视觉左右箭头 → `.dark`（海报大图=动态画面，压暗不洗灰，白箭头保读清）；
    //   · SettingsView siteChip / SiteBrowseView siteHeader / searchBar → `.clear`
    //     （静态取色底档，B4/B6 同款 tint 0.07）；
    //   · StateViews SyncBadge 未修（全仓无调用点 = 死代码，不浪费改动）。
    //   · 主视觉冷门片霸屏根修：中台 feed 全量无 rating/votes（实测 85842/85842 缺失）→
    //     「真热门」档全空 → Hero 只剩按年份兜底 = 2026 冷门采集剧霸屏。
    //     新增 HeatIndex（包内豆瓣票数/评分查询表，构建期从快照提取）+ buildCatalog 逐条
    //     兜底回填（只兜底不覆盖，查不到原样返回）；实测 714 部热门片 702 部命中真机目录，
    //     回填后 Hero = 沙丘2/死侍与金刚狼/某种物质/凶器/阿诺拉…（端到端 Python 复刻终验）。
    // v61（2026-10-04）：插播广告段自动跳过。
    //   · 新增 `AdBreakDetector`（FilmCore/Ads/）：拉取播放列表 → 按 #EXT-X-DISCONTINUITY 切段
    //     → 整组分片路径含 `adjump` 特征即判为广告段（实测＝澳门新葡京 063063.COM 26s 视频广告，
    //     9 分片一段，固定插在约 5min/40min/2h）；结构兜底仅在无特征命中时启用，条件从严。
    //   · `PlayerViewModel`：起播时异步识别（识别不到 = 空数组 = 一秒都不跳）；
    //     0.5s 周期观察发现播放头进入广告区间 → 直接 seek 越到段尾；续播点落在广告里也推到段尾。
    //   · 设置页「自动跳过插播广告」开关（默认开）。
    //   · 安全闸：广告段总时长 > 180s 或片长 < 600s → 整体放弃（绝不误伤正片）。
    /// 2026-09-30 根治「版本号假信号」：mark 此前停在 20260923-67 不随批次走（用户会看到旧号）。
    /// 展示值 = mark + CI 注入的构建指纹（`FeedSecret.buildStamp` = git 短 sha，每批必变）。
    /// 本地无 CI 注入时（占位符）只显示 mark。
    public static var displayMark: String {
        let s = FeedSecret.buildStamp
        if !s.isEmpty && !s.contains("__BUILD") { return mark + " · " + s }
        return mark
    }
}

let filmLog = Logger(subsystem: "filmthree", category: "player")

/// 窗口级返回按钮（2026-09-20 核弹级返回修复）：
/// 直接挂在 keyWindow 上的 UIKit UIButton，凌驾于全部 SwiftUI 图层之上，
/// 不会被视频层/手势层/容器环境（LiveContainer）吞掉 hit-testing。
/// 此前 SwiftUI 返回按钮在 LC 里点不到（六轮未闭上的根因），本组件物理免疫该问题。
final class WindowBackButton {

    private var button: UIButton?
    private let action: () -> Void
    /// 挂载**彻底失败**（24×50ms 重试全用尽）时的回调（2026-10-01）。
    /// 起因：UI 层要「有窗口级按钮就不再画 SwiftUI 箭头」来治「一大一小叠加」，
    /// 但那样一旦窗口级按钮挂不上，就会变成**一个返回键都没有**。有了本回调，
    /// 调用方可在挂载失败时把 SwiftUI 箭头放回来兜底，两头都不落空。
    private let onGiveUp: (() -> Void)?
    private var didGiveUp = false
    /// 期望可见性（安装是异步的：调用方可能在按钮进窗口前就调 setVisible，
    /// 先记下意图，`attach` 成功后立即对齐，否则会「明明设了可见却一直不出现」）。
    private var desiredVisible: Bool = true

    /// 创建并安装到 keyWindow（锚点视图所在窗口优先）。自动重试等待进窗口层级。
    init(anchor: UIView? = nil, action: @escaping () -> Void, onGiveUp: (() -> Void)? = nil) {
        self.action = action
        self.onGiveUp = onGiveUp
        self.attachWithRetry(anchor: anchor, attempts: 24)
    }

    /// 安装到 keyWindow（锚点视图所在窗口优先）。自动重试等待进窗口层级。
    @discardableResult
    static func install(anchor: UIView? = nil,
                        onGiveUp: (() -> Void)? = nil,
                        action: @escaping () -> Void) -> WindowBackButton {
        WindowBackButton(anchor: anchor, action: action, onGiveUp: onGiveUp)
    }

    /// 重试安装：24 × 50ms（≈1.2s 窗口就绪窗口期）。
    /// 用户反馈「有的时候不在」—— 初版 8 次全是同一 runloop 内连发，Play 转场未完成时
    /// 连续失败就永久放弃；加 50ms 间隔后覆盖转场全过程。
    private func attachWithRetry(anchor: UIView?, attempts: Int) {
        guard attempts > 0 else {
            filmLog.error("back-button: no window to attach")
            // 只在主线程回调一次（本函数除首次同步调用外，递归全在 main 队列上）。
            if !didGiveUp {
                didGiveUp = true
                onGiveUp?()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if self.attach(anchor: anchor) { return }
            self.attachWithRetry(anchor: anchor, attempts: attempts - 1)
        }
    }

    private func attach(anchor: UIView?) -> Bool {
        guard button == nil else { return true }
        let window: UIWindow?
        if let w = anchor?.window {
            window = w
        } else {
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
            window = scene?.keyWindow ?? scene?.windows.first
        }
        guard let window else { return false }

        let b = UIButton(type: .system)
        // 2026-09-22 用户反馈「黑框、白色，大牌不这样」——真身是**箭头过大（30pt）+ 投影过重**
        // （opacity 0.8 / radius 10），在浅色画面上糊成一圈黑影，看着就是个「黑框白箭头」。
        // 大牌（爱奇艺/腾讯/Netflix/YouTube）播放器返回键＝**干净的白色小箭头、无底无框、投影极轻**。
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        b.setImage(UIImage(systemName: "chevron.left", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = .clear
        b.imageView?.contentMode = .scaleAspectFit
        b.imageView?.layer.shadowColor = UIColor.black.cgColor
        b.imageView?.layer.shadowOpacity = 0.35     // 只保证浅色画面可见，不做「黑框」
        b.imageView?.layer.shadowRadius = 3
        b.imageView?.layer.shadowOffset = CGSize(width: 0, height: 1)
        b.accessibilityLabel = "返回"
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addAction(UIAction { [weak self] _ in
            filmLog.info("back-button: WINDOW TAP FIRED")
            self?.action()
        }, for: .touchUpInside)
        window.addSubview(b)
        NSLayoutConstraint.activate([
            b.leadingAnchor.constraint(equalTo: window.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            b.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 6),
            b.widthAnchor.constraint(equalToConstant: 44),
            b.heightAnchor.constraint(equalToConstant: 44),
        ])
        button = b
        applyVisibility(animated: false)   // 安装即对齐调用方先前设定的显隐意图
        filmLog.info("back-button: installed on window \(String(describing: window))")
        return true
    }

    /// 显隐控制（2026-09-22 用户反馈「播放时该隐藏的没隐藏」「想返回时它又不见了」）：
    /// 对齐大牌行为 —— 返回键**属于播放器控件层**，跟底部进度条/标题一起
    /// 播放 3.4s 后淡出、点画面一起淡入；暂停时保持可见；锁定态隐藏。
    func setVisible(_ visible: Bool, animated: Bool = true) {
        desiredVisible = visible
        applyVisibility(animated: animated)
    }

    private func applyVisibility(animated: Bool) {
        guard let b = button else { return }     // 还没进窗口 → 意图已记录，attach 后对齐
        let visible = desiredVisible
        let target: CGFloat = visible ? 1 : 0
        guard b.alpha != target else { return }
        let apply = {
            b.alpha = target
            b.isUserInteractionEnabled = visible
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }

    func remove() {
        button?.removeFromSuperview()
        button = nil
    }

    deinit {
        let b = button
        DispatchQueue.main.async {
            b?.removeFromSuperview()
        }
    }
}
