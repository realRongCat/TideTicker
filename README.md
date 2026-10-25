# TideTicker

<img src="./Resources/tide-logo-black-white-20261015.png" alt="TideTicker logo" width="128">

原生 macOS 菜单栏加密货币行情工具。无需交易账户或 API Key，只观察行情，不提供交易或下单能力。

[下载最新版本](https://github.com/realRongCat/TideTicker/releases/latest) · [更新记录](./CHANGELOG.md) · [MIT License](./LICENSE)

![TideTicker 行情概览](./docs/images/tideticker-overview.png)

## 功能

- 在菜单栏常驻最多两条报价，固定显示币种图标、币种和价格。
- 从 OKX、Binance、Bybit 的官方目录中选择最多 20 个关注品种。
- 支持 USDT 现货、USDT 线性永续和 USD 币本位永续；现货显示最新成交价，永续显示标记价。
- 可选显示补充行情：现货显示 24 小时涨跌，永续显示资金费率、距结算倒计时和同所现货溢折价。
- 提供本地价格提醒。通知会写明交易所、原生合约、价格口径和阈值，也可要求确认后再重新布防。
- 分别标记报价是否过期、行情是否可能漏报，帮助识别断线、REST 采样和休眠恢复带来的观察空档。
- 自动检查 GitHub 稳定版 Release，发现新版本后显示非抢焦点提示，并保留菜单入口。

## 安装

当前公开版本为 **0.2.0**，需要 macOS 13 或以上。从 [GitHub Releases](https://github.com/realRongCat/TideTicker/releases/latest) 下载 `TideTicker-0.2.0-universal.dmg`，打开后将 TideTicker 拖入“应用程序”。

安装包同时包含 Apple Silicon 和 Intel 版本。项目目前没有 Apple Developer ID，应用使用 ad-hoc 签名且未经 Apple 公证；首次打开可能需要前往“系统设置”→“隐私与安全性”，在确认下载来源可信后选择“仍要打开”。Intel Mac 的实际运行仍待真机验收。

也可以使用支持 Swift 6 的 Xcode 或 Command Line Tools 从源码构建：

```sh
git clone https://github.com/realRongCat/TideTicker.git
cd TideTicker
bash scripts/build-app.sh
open dist/TideTicker.app
```

源码构建、测试和 Universal 构建说明见 [CONTRIBUTING.md](./CONTRIBUTING.md)。

## 开始使用

1. 点击菜单栏报价，选择“显示主窗口”（⌘1）。
2. 在“关注品种”中选择行情，在“行情来源”中选择交易所和网络模式；关注顺序与两条菜单栏常驻位置可以分别设置。
3. 在“到价提醒”中创建规则。需要系统通知时，请在 macOS 通知设置中允许 TideTicker 发送通知。

全新配置默认使用 OKX 和系统网络，并将 BTC、ETH 的 USDT 永续标记价常驻菜单栏。“显示补充行情”默认关闭；开启后会在行情卡中展示当前市场可用的全部补充信息，不改变菜单栏的图标、币种和价格布局。

## 行情口径

| 市场 | 主报价 | 报价与结算 |
| --- | --- | --- |
| USDT 现货 | 最新成交价 | USDT 报价 |
| USDT 线性永续 | 标记价 | USDT 报价、USDT 结算 |
| USD 币本位永续 | 标记价 | USD 报价、标的币结算 |

永续溢折价只使用同一交易所、同一币种和同一报价币的现货价格。当前 USD 币本位永续没有同报价币参考现货，因此不显示溢折价。

系统网络是默认模式，沿用 macOS 的代理、DNS 和路由。OKX 在该模式下使用 WebSocket 接收主报价，并在连接异常时以 REST 兜底；Binance、Bybit 和物理直连模式使用定时采样。应用不会自动切换交易所、网络模式或地区端点。

## 提醒边界

TideTicker 的提醒只用于辅助观察。网络、代理、系统休眠、交易所异常和本机处理延迟都可能造成漏报，不能替代交易所风控或止损。

报价过期和行情连续性会分别显示：刚收到的 REST 报价可以是新鲜的，但两次采样之间仍可能错过短暂触价。WebSocket 断线、休眠恢复或切换来源后，穿越类提醒会先用首个有效样本重建基准，不补发空档期间无法确认的穿越。

## 版本与隐私

“关于 TideTicker”显示当前版本和构建号。“检查更新…”会查询 GitHub 最新稳定版；自动检查默认开启，发现新版本后可以打开发布页、延后提醒或跳过该版本。应用不会自行下载或替换程序。

关注列表、提醒和偏好只保存在本机。应用仅访问所选交易所的公共行情接口；更新检查访问 `api.github.com`，不上传关注列表、提醒阈值或本地诊断信息。完整说明见 [PRIVACY.md](./PRIVACY.md)。

## 开发与贡献

构建、测试、项目结构和 Pull Request 约定见 [CONTRIBUTING.md](./CONTRIBUTING.md)。领域语义见 [CONTEXT.md](./CONTEXT.md)，现役架构见 [DESIGN.md](./DESIGN.md)，重要网络与传输决策记录在 [docs/adr](./docs/adr)。发布维护者另见 [Release checklist](./docs/RELEASE_CHECKLIST.md)。

源代码使用 [MIT License](./LICENSE)。币种图标、交易所标识和品牌资产的来源及权利边界见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。安全问题请参阅 [SECURITY.md](./SECURITY.md)。

Made by [@rongcat](https://x.com/rongcat).
