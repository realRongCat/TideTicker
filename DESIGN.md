# TideTicker 设计

本文记录当前实现。领域术语与数据口径以 [CONTEXT.md](./CONTEXT.md) 为准；网络与主报价的重要取舍由 [ADR](./docs/adr/) 记录。

## 产品边界

TideTicker 是 macOS 菜单栏行情观察工具，不是交易终端。它不接收账户凭据、不下单、不管理资金，也不承诺交易级告警。当前支持 OKX、Binance、Bybit 的 USDT 现货、USDT 线性永续和 USD 币本位永续；用户一次只选择一个行情来源。

关注列表最多 20 个品种，菜单栏最多常驻两条。常驻行固定显示图标、币种和主报价；24 小时涨跌、资金费率、结算倒计时和溢折价只在展开菜单与主窗口显示。

## 模块

| 模块 | 职责 | 主要文件 |
| --- | --- | --- |
| 市场模型 | 完整合约身份、价格口径、数据时间和报价缓存 | `Market.swift`, `MainQuoteState.swift` |
| 来源适配 | 官方目录、REST 主报价、补充行情和结构化诊断 | `MarketDataClient.swift`, `ConnectionDiagnostics.swift` |
| 网络传输 | 系统 URLSession 与物理直连 curl / DoH | `SystemHTTPClient.swift`, `DirectOKXClient.swift` |
| 主报价会话 | WS 生命周期、逐品种健康、REST 兜底、过期、取消与 generation 隔离 | `MainQuoteSession.swift`, `OKXWebSocketClient.swift` |
| 提醒 | 五类条件、冷却、待确认事件和规则级重建基准 | `PriceAlerts.swift`, `PriceAlertSubmission.swift` |
| 偏好 | 来源 profile、关注、常驻、网络和提醒持久化与迁移 | `TidePreferences.swift` |
| 版本更新 | SemVer、GitHub Release 校验、ETag、退避、稍后提醒与跳过版本 | `ReleaseUpdates.swift`, `GitHubReleaseClient.swift` |
| App | 菜单、主窗口、通知、登录项和休眠恢复 | `MarkBarAppDelegate.swift`, `Tide*Page.swift` |

`MarkBarCore` 不依赖 AppKit。应用层通过主报价会话的单一更新接口消费状态，不直接管理 WebSocket 重连或 REST 退避。

## 主报价会话

`MainQuoteSession` 接收完整 `MainQuotePlan`，验证来源、品种数量、重复身份与时间参数，然后用 generation 隔离旧任务。切源、切网、休眠和停止都会取消旧 feed；迟到结果因 generation 不匹配而丢弃。

### 系统网络与 OKX

1. 建立 OKX 公共 WebSocket，现货订阅 `tickers`，永续订阅 `mark-price`。
2. 逐品种记录订阅确认、最近 WS 报价时间和健康状态。
3. 首个严格推进的 WS 报价将该品种标记为连续；重复时间戳可以证明连接活跃，但不能推进价格或数据时间。
4. 未收到健康 WS、订阅被拒或活性超时的品种单独进入 REST 兜底。
5. 带 `instId` 的订阅错误只影响对应品种；连接级错误才重连整条 stream。
6. 重连使用有界指数退避，恢复后逐品种退出 REST 兜底。

### REST 路径

物理直连、Binance 和 Bybit 使用 REST 采样。REST worker pool 固定最多 3 个并发请求，单个结果完成后立即发布；每轮轮换起始品种，并按单调时钟推进下一计划时间，避免在整轮耗时后再累加刷新间隔。

REST 样本始终标记为可能漏报。旧时间戳或重复样本不会改变报价、路由、连续性或 epoch。主报价更新流使用 64 项有界缓冲；消费者落后造成丢弃时，会显式推进 `consumerLag` 连续性缺口，穿越提醒重新建立基准。

## 报价状态

每个关注品种独立保存最近有效 `MarkQuote`、最近请求错误、新鲜度、传输路由、连续性状态和 epoch。

只有严格更新的 `dataTime` 能推进报价。`receivedAt` 只记录本机收到时间。报价过期不删除旧值；UI 将其显示为上次已知价格。

## 提醒

`PriceAlertEngine` 以规则 ID 保存判定状态，以完整合约 ID 保存最新数据时间。

- 穿越、上穿、下穿需要连续基准；首个有效样本只建基准。
- 大于、小于判断当前新鲜状态，可以在首样本触发。
- 冷却内发生的穿越不排队补发。
- 通知未授权时不消耗规则。
- 要求确认的规则只保留一个持久化待确认事件；再次命中更新价格和时间，不重复发系统通知。
- 确认只重置对应规则，不清除同品种其他规则或其他品种的基准。

通知标题使用 `交易所 · 原生合约 · 价格口径 条件 阈值`，避免现货与永续混淆。

## 补充行情

单一开关控制全部补充行情。关闭时取消请求并清空补充缓存；开启后约每 60 秒更新：

- 现货：24 小时成交价涨跌。
- 永续：24 小时涨跌、资金费率、下次结算倒计时、同所同报价币现货溢折价。

参考现货不加入关注、常驻或提醒。溢折价计算要求标记价和参考现货都未过期；不同交易所或不同报价币不能拼接。补充行情失败不使主报价失效。

## 偏好与来源切换

每个交易所分别保存关注列表、顺序、常驻位置和提醒。网络模式是全局偏好，恢复来源 profile 时不能覆盖当前网络选择。

切换来源前必须完成官方目录校验和代表报价探测。提交后清空旧来源报价与补充行情；失败时保留原来源。已有但下架的品种可以随 profile 恢复，以便用户移除。

新配置默认系统网络。旧 JSON 缺少 `networkMode` 时迁移为物理直连，以保持旧版本行为。内部 bundle ID、偏好键和 `MarkBar*` 类型名承担兼容职责，不随公开版本号重置。

## 生命周期

- 休眠：取消网络任务、暂停主报价会话、保留旧报价并标记连续性中断。
- 唤醒：清理网络缓存，使用当前模式重建会话，重新获取补充行情。
- 手动刷新：主报价会话只刷新当前需要 REST 的品种；补充行情立即重新调度。
- 退出：停止计时器、报价消费、登录项观察和 AppKit 状态项。

通知授权在启动、应用重新激活、用户请求授权和唤醒时刷新并缓存，高频报价路径不查询系统设置。

## 版本更新

`ReleaseUpdateMonitor` 独立于行情模块，按严格稳定版 SemVer 比较 Bundle 版本和 GitHub Release 标签。GitHub 客户端只访问 `api.github.com/repos/realRongCat/TideTicker/releases/latest`，限制响应大小，并校验发布页仍属于 TideTicker 官方仓库。ETag、检查时间、失败退避、稍后提醒和跳过版本保存在独立更新状态中，不进入交易所 profile。

自动检查默认开启：启动后延迟 20 至 60 秒，随后由低频调度器驱动；监视模块保证正常间隔约 4 小时，失败后按 30 分钟、1 小时、4 小时退避。唤醒和应用激活只触发到期检查。所有更新请求使用系统 URLSession，不沿用行情物理直连模式，失败不改变报价、连续性或提醒状态。

App 层的 `TideUpdateController` 串行化检查并驱动菜单与非激活浮层。浮层自动收起等同 24 小时后提醒；菜单中的新版本入口持续存在。当前源码发布阶段仅打开校验后的 GitHub Release 页面，不下载或替换应用。具备 Developer ID、公证和签名更新源后，再单独评估 Sparkle 自动安装。

## 验证边界

单元测试覆盖模型、解析、偏好迁移、提醒语义、逐品种 WS/REST 切换、并发调度、消费者背压和风险计算。构建脚本生成 ad-hoc 签名应用，仅用于本机验收。

公开二进制还需要 Developer ID、hardened runtime、公证、staple 和 Gatekeeper 验证。真实休眠、重新登录、8 小时常驻以及多网络/三来源矩阵必须按 [Release checklist](./docs/RELEASE_CHECKLIST.md) 单独执行，不能用离线测试替代。
