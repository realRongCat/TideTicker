# TideTicker

<img src="./Resources/tide-logo-black-white-20261015.png" alt="TideTicker logo" width="144">

TideTicker 是原生 macOS 菜单栏加密货币行情工具，支持 USDT 现货、USDT 线性永续和 USD 币本位永续。现货主报价使用最新成交价，永续主报价使用标记价。应用无需交易账户或 API Key，不包含交易和下单能力。

当前公开版本为 **0.2.0**。当前只发布源码；项目尚无 Apple Developer ID，仓库不提供未经公证的正式二进制发行包。

## 功能

- 菜单栏最多常驻两条报价，固定显示币种图标、币种和主报价。
- 从 OKX、Binance、Bybit 官方目录选择最多 20 个关注品种；来源配置分别保存。
- OKX 在系统网络模式下使用 WebSocket 主报价，逐品种断线或订阅异常时使用同模式 REST 兜底；物理直连和其他来源使用 REST 采样。
- 统一的“显示补充行情”开关：现货显示 24 小时涨跌；永续显示资金费率、结算倒计时及同所同报价币现货溢折价。
- 五类本地价格提醒，并提供“涨到 / 跌到”简单入口。通知标题包含交易所、原生合约、价格口径和阈值。
- 提醒可要求确认：系统通知只发送一次，菜单和提醒页持续显示待确认状态，确认后只重新布防对应规则。
- 独立展示报价过期与行情可能漏报，不把 REST 新鲜样本描述为连续行情。
- 支持系统网络和物理直连两种网络模式，并提供结构化连接诊断。
- 自动检查 GitHub 稳定版 Release；发现新版本时显示非抢焦点浮层，并在菜单中保留入口。

TideTicker 的提醒只用于辅助观察。网络、代理、系统休眠、交易所异常和本机处理延迟都可能造成漏报，不能替代交易所风控或止损。

## 运行要求

- macOS 13 或以上
- 支持 Swift 6 的 Xcode 或 Command Line Tools

```sh
swift test
bash scripts/build-app.sh
open dist/TideTicker.app
```

`build-app.sh` 生成当前机器架构的 `dist/TideTicker.app`，并进行本地 ad-hoc 签名。它不会安装、启动、公证或上传应用。Universal 本地构建可运行：

```sh
bash scripts/build-app.sh --universal
```

开发时可对默认 OKX 品种执行真实公共接口探测：

```sh
swift run TideTickerProbe --rounds 3
swift run TideTickerProbe --rounds 1 --all-markets
```

这些命令会访问外部网络。提交代码前至少运行 `swift test`；跨模块、产品名或打包改动还应运行 `bash scripts/build-app.sh`。

隔离 UI 验收默认不执行真实自动更新请求。可用 `--update-fixture-version 0.2.0` 注入一个本地版本结果，或用 `--disable-update-checks` 明确禁用自动检查。

## 使用

点击菜单栏报价，选择“显示主窗口”（⌘1）。主窗口包含：

| 页面 | 用途 |
| --- | --- |
| 行情概览 | 查看主报价、数据时间、新鲜度、连续性和可选补充行情。 |
| 关注品种 | 搜索官方目录、筛选市场、调整关注顺序与两条常驻位置。 |
| 行情来源 | 选择交易所、网络模式、刷新间隔，运行连接诊断。 |
| 到价提醒 | 创建、编辑、确认或停用本地价格提醒。 |

全新配置默认使用 OKX、系统网络、BTC / ETH 双常驻和 5 秒 REST 兜底间隔，补充行情关闭。常驻位置与关注列表顺序独立，可以只显示一条，也可以全部取消。

## 版本与更新

“关于 TideTicker”显示当前版本和构建号。“检查更新…”立即查询 GitHub 最新稳定版；自动检查默认开启，启动后延迟执行，常驻期间约每 4 小时查询一次。发现新版本后，浮层提供查看发布页、24 小时后提醒和跳过当前版本，菜单入口会保留到用户处理。

更新检查固定使用 macOS 系统网络访问 `api.github.com`，与交易所来源和物理直连模式无关。请求不包含关注列表、提醒阈值或本地诊断信息。当前仍是源码发布阶段，应用只打开经过校验的 GitHub Release 页面，不会自行下载或替换应用。自动检查可以在“显示与启动”菜单中关闭，手动检查仍然可用。

## 行情语义

| 市场 | 主报价 | 报价与结算 |
| --- | --- | --- |
| USDT 现货 | 最新成交价 | USDT 报价 |
| USDT 线性永续 | 标记价 | USDT 报价、USDT 结算 |
| USD 币本位永续 | 标记价 | USD 报价、标的币结算 |

完整 `Contract.id` 区分交易所、市场、报价币、结算币、价格口径和原生合约。`1000…` 等单位前缀不会被剥离。价格和提醒阈值内部使用 `Decimal`，只在展示层舍入。

报价超过 `max(20 秒, REST 间隔 × 3)` 没有推进数据时间时视为过期。过期和连续性是两个维度：REST 采样可能刚刚更新价格，但采样间隔内仍可能漏过短暂穿越。WebSocket 断线、休眠、切源、切换网络以及消费端积压都会清除穿越基准；恢复后的首个有效样本只建立新基准。

补充行情约每 60 秒更新。永续溢折价只使用同一交易所、同一币种和同一报价币的现货；任一价格缺失或过期时不计算。当前 USD 币本位永续没有同报价币参考现货，因此显示不可用。

详细领域定义见 [CONTEXT.md](./CONTEXT.md)，现役调度与模块设计见 [DESIGN.md](./DESIGN.md)。

## 网络模式

| 模式 | 行为 |
| --- | --- |
| 系统网络 | 默认。URLSession 沿用 macOS 的代理、DNS 和路由；OKX 主报价使用 WebSocket。 |
| 物理直连 | 高级选项。curl 禁用代理并绑定物理 IPv4 网卡，通过 Cloudflare DoH 解析官方主机；主报价使用 REST 采样。 |

两种模式都保留官方主机名与 TLS 校验。应用不会自动切换来源、网络模式或地区端点，也不会绕过 HTTP 403 / 451。切换网络或来源时保留上次报价并按原数据时间判断过期，迟到任务不能写入新会话。

设计依据见 [ADR 0001](./docs/adr/0001-direct-physical-interface.md)、[ADR 0002](./docs/adr/0002-system-network-mode.md)和 [ADR 0003](./docs/adr/0003-main-quote-session.md)。

## 仓库结构

```text
Sources/MarkBarCore/       领域模型、来源适配、传输、主报价会话和提醒
Sources/MarkBarApp/        菜单栏、主窗口、通知与生命周期
Sources/MarkBarProbe/      公共行情命令行探针
Tests/MarkBarCoreTests/    行为、解析、迁移和并发回归测试
Resources/                 Info.plist、应用 Logo 与作者资料
scripts/                   本地 App、图标和发行包构建脚本
docs/adr/                  当前架构决定
```

构建产物、个人偏好、原始验收证据、研究输出和临时快照不进入公开 Git 历史。发布前检查项见 [Release checklist](./docs/RELEASE_CHECKLIST.md)。

## 隐私、资产与许可

偏好和提醒只保存在本机。应用访问所选交易所的公共行情接口；物理直连模式还会访问 Cloudflare DoH。完整说明见 [PRIVACY.md](./PRIVACY.md)。

源代码使用 [MIT License](./LICENSE)。币种图标、交易所标识和品牌资产的来源与权利边界见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。贡献方式见 [CONTRIBUTING.md](./CONTRIBUTING.md)，安全问题见 [SECURITY.md](./SECURITY.md)。

Made by [@rongcat](https://x.com/rongcat).
