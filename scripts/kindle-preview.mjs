import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(scriptDirectory, "..");
const dashboardPath = path.join(projectRoot, "Sources/MarkBarApp/Resources/Kindle/index.html");
const companionPath = path.join(projectRoot, "KindleCompanion/waf/index.html");
const outputDirectory = path.join(projectRoot, "outputs/kindle-preview");
const viewport = { width: 600, height: 800 };
const legacyViewport = { width: 1072, height: 1448 };
const paperwhiteScale = 1072 / viewport.width;

function optionValue(name, fallback) {
  const prefix = `--${name}=`;
  const item = process.argv.find((argument) => argument.startsWith(prefix));
  return item ? item.slice(prefix.length) : fallback;
}

function chromeExecutable() {
  const candidates = [
    process.env.CHROME_PATH,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium"
  ].filter(Boolean);
  const executable = candidates.find((candidate) => fs.existsSync(candidate));
  if (!executable) {
    throw new Error("Google Chrome or Chromium was not found. Set CHROME_PATH to its executable.");
  }
  return executable;
}

function quote(index) {
  const fixtures = [
    ["BTC-USDT-SWAP", "BTC/USDT", "80,769.50", "+0.7583%", "0.0053%", "06:51:01", "-0.0123%"],
    ["ETH-USDT-SWAP", "ETH/USDT", "2,354.37", "+1.6201%", "0.0028%", "06:51:01", "+0.1034%"],
    ["XAU-USDT-SWAP", "XAU/USDT", "4,005.00", "+0.3256%", "0.0100%", "06:51:01", "-0.8456%"]
  ];
  const values = fixtures[index % fixtures.length];
  return {
    contractID: `preview-${index}`,
    instrumentID: values[0],
    title: values[1],
    marketKind: "USDT 永续",
    priceKind: "标记价",
    quoteCurrency: "USDT",
    price: values[2],
    dataTime: "2026-10-25T17:08:58Z",
    isStale: false,
    possiblyMissed: false,
    hasError: false,
    continuity: "WebSocket",
    supplement: {
      change24h: values[3],
      fundingRate: values[4],
      fundingCountdown: values[5],
      premium: values[6],
      isStale: false
    }
  };
}

function snapshot(cardCount, stressed = false) {
  const quotes = Array.from({ length: cardCount }, (_, index) => quote(index));
  if (stressed && quotes.length) {
    quotes[0].possiblyMissed = true;
    quotes[0].continuity = "网络中断后重新建基准";
  }
  return {
    exchange: "OKX",
    sessionPhase: "WebSocket 连续行情",
    generatedAt: "2026-10-25T17:08:58Z",
    supplementalEnabled: true,
    pendingAlert: stressed ? {
      title: "OKX · BTC-USDT-SWAP · 标记价 上穿 80000",
      condition: "等待确认后重新布防",
      latestPrice: "80,769.50"
    } : null,
    quotes
  };
}

function createServer(html, companion, getSnapshot) {
  return http.createServer((request, response) => {
    if (request.url?.startsWith("/api/v1/snapshot")) {
      response.writeHead(200, { "Content-Type": "application/json; charset=utf-8", ETag: '"preview"' });
      response.end(JSON.stringify(getSnapshot()));
      return;
    }
    if (request.url?.startsWith("/companion-harness")) {
      response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
      response.end(companion);
      return;
    }
    if (request.url?.startsWith("/settings.js")) {
      const baseURL = `http://${request.headers.host}/`;
      response.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8", "Cache-Control": "no-store" });
      response.end(`var TIDE_TICKER_URL = '${baseURL}';\nvar TIDE_TICKER_UI_REVISION = 'preview';\n`);
      return;
    }
    if (request.url?.startsWith("/var/local/mesquite/shared/javascripts/Kindle.js")) {
      response.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8" });
      response.end(`
window.kindle = { net: { setWirelessState: function () {} }, messaging: { sendMessage: function () {} } };
window.Kindle = { use: function (callback) { callback({ applicationManager: { addEventListener: function (name, handler) {
  if (name === "go") window.setTimeout(handler, 0);
} } }); } };
`);
      return;
    }
    if (request.url?.startsWith("/var/local/mesquite/shared/javascripts/")) {
      response.writeHead(200, { "Content-Type": "application/javascript; charset=utf-8" });
      response.end("");
      return;
    }
    response.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
    response.end(html);
  });
}

async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  return server.address().port;
}

function assertLegacySurface(html) {
  const unsupported = [
    [/(?:display\s*:\s*)(?:flex|grid)/i, "flex/grid layout"],
    [/\b(?:let|const)\s+[A-Za-z_$]/, "ES2015 variable declarations"],
    [/=>/, "arrow functions"],
    [/\bfetch\s*\(/, "Fetch API"],
    [/\bvar\s*\(/, "CSS custom properties"]
  ];
  const failures = unsupported.filter(([pattern]) => pattern.test(html)).map(([, label]) => label);
  if (failures.length) throw new Error(`Kindle page uses unsupported features: ${failures.join(", ")}`);
}

async function inspect(page) {
  return page.evaluate(() => {
    function rectangle(element) {
      const value = element.getBoundingClientRect();
      return { top: value.top, right: value.right, bottom: value.bottom, left: value.left };
    }
    function intersects(first, second) {
      return first.left < second.right - 0.5 && second.left < first.right - 0.5 &&
        first.top < second.bottom - 0.5 && second.top < first.bottom - 0.5;
    }
    function textRectangle(element) {
      const range = document.createRange();
      range.selectNodeContents(element);
      const value = range.getBoundingClientRect();
      return { top: value.top, right: value.right, bottom: value.bottom, left: value.left };
    }
    const selectors = [".quote-head", ".instrument", ".price-row", ".meta", ".metrics"];
    const cards = Array.from(document.querySelectorAll(".quote"));
    const overlaps = [];
    const outside = [];
    const verticalImbalance = [];
    cards.forEach((card, cardIndex) => {
      const cardRect = rectangle(card);
      const children = selectors.map((selector) => card.querySelector(selector)).filter((element) => {
        return element && window.getComputedStyle(element).display !== "none";
      });
      children.forEach((child) => {
        const childRect = rectangle(child);
        if (childRect.left < cardRect.left - 0.5 || childRect.right > cardRect.right + 0.5 ||
            childRect.top < cardRect.top - 0.5 || childRect.bottom > cardRect.bottom + 0.5) {
          outside.push(`card ${cardIndex + 1}: ${child.className}`);
        }
      });
      if (card.className.indexOf("medium") >= 0 && children.length) {
        const firstRect = rectangle(children[0]);
        const lastRect = rectangle(children[children.length - 1]);
        const topGap = firstRect.top - cardRect.top;
        const bottomGap = cardRect.bottom - lastRect.bottom;
        verticalImbalance.push(Math.abs(topGap - bottomGap));
      }
      for (let first = 0; first < children.length; first += 1) {
        for (let second = first + 1; second < children.length; second += 1) {
          if (intersects(rectangle(children[first]), rectangle(children[second]))) {
            overlaps.push(`card ${cardIndex + 1}: ${children[first].className} / ${children[second].className}`);
          }
        }
      }
    });
    const textOutside = Array.from(document.querySelectorAll(
      ".quote-name,.instrument,.price,.basis,.meta,.metric-label,.metric-value,.footer-left,.footer-right"
    )).filter((element) => {
      const boundary = element.closest(".quote") || element.closest(".footer");
      const textRect = textRectangle(element);
      const boundaryRect = rectangle(boundary);
      return textRect.left < boundaryRect.left - 0.5 || textRect.right > boundaryRect.right + 0.5 ||
        textRect.top < boundaryRect.top - 0.5 || textRect.bottom > boundaryRect.bottom + 0.5;
    }).map((element) => element.textContent);
    const heights = cards.map((card) => card.getBoundingClientRect().height);
    return {
      horizontalOverflow: document.documentElement.scrollWidth - window.innerWidth,
      verticalOverflow: document.documentElement.scrollHeight - window.innerHeight,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight,
      footerBottom: document.querySelector(".footer").getBoundingClientRect().bottom,
      heights,
      overlaps,
      outside,
      verticalImbalance,
      textOutside,
      webSocketCount: (document.body.innerText.match(/WebSocket/g) || []).length,
      beijingCount: (document.body.innerText.match(/北京时间/g) || []).length,
      fullscreenVisible: window.getComputedStyle(document.querySelector("#fullscreen")).display !== "none"
    };
  });
}

function validate(name, report, maximumLayoutHeight = report.viewportHeight) {
  const failures = [];
  if (report.horizontalOverflow > 0) failures.push(`horizontal overflow ${report.horizontalOverflow}px`);
  if (report.verticalOverflow > 0) failures.push(`vertical overflow ${report.verticalOverflow}px`);
  if (report.footerBottom > maximumLayoutHeight) failures.push(`footer bottom ${report.footerBottom}px`);
  if (maximumLayoutHeight === viewport.height && report.footerBottom > viewport.height - 12) {
    failures.push(`footer safety margin is only ${viewport.height - report.footerBottom}px`);
  }
  if (Math.max(...report.heights) - Math.min(...report.heights) > 1) failures.push("quote cards have unequal heights");
  if (report.overlaps.length) failures.push(`overlap: ${report.overlaps.join(", ")}`);
  if (report.outside.length) failures.push(`outside card: ${report.outside.join(", ")}`);
  if (report.verticalImbalance.some((value) => value > 12)) failures.push(`card content is not vertically centered: ${report.verticalImbalance.join(", ")}px`);
  if (report.textOutside.length) failures.push(`text outside container: ${report.textOutside.join(", ")}`);
  if (report.webSocketCount !== 0) failures.push(`WebSocket appears ${report.webSocketCount} times`);
  if (report.beijingCount !== 1) failures.push(`北京时间 appears ${report.beijingCount} times`);
  if (report.fullscreenVisible) failures.push("fullscreen button is visible in Companion mode");
  if (failures.length) throw new Error(`${name}: ${failures.join("; ")}`);
}

async function runChecks(html, companion, executablePath) {
  fs.mkdirSync(outputDirectory, { recursive: true });
  let activeSnapshot = snapshot(3);
  const server = createServer(html, companion, () => activeSnapshot);
  const port = await listen(server);
  const browser = await chromium.launch({ headless: true, executablePath });
  const scenarios = [
    ["one-card", snapshot(1)],
    ["two-cards", snapshot(2)],
    ["three-cards", snapshot(3)],
    ["three-cards-alert", snapshot(3, true)]
  ];
  try {
    for (const [name, data] of scenarios) {
      activeSnapshot = data;
      const cssContext = await browser.newContext({ viewport, deviceScaleFactor: paperwhiteScale });
      const cssPage = await cssContext.newPage();
      await cssPage.goto(`http://127.0.0.1:${port}/dashboard.html?companion=1`, { waitUntil: "networkidle" });
      const cssReport = await inspect(cssPage);
      await cssPage.screenshot({ path: path.join(outputDirectory, `${name}-css-viewport.png`) });
      validate(`${name} / 600 CSS px`, cssReport);
      const expectedMaximumHeight = data.pendingAlert ? 220 : (data.quotes.length === 3 ? 184 : null);
      if (expectedMaximumHeight && Math.max(...cssReport.heights) > expectedMaximumHeight + 1) {
        throw new Error(`${name}: quote card exceeded ${expectedMaximumHeight}px height cap`);
      }
      await cssContext.close();

      const tallContext = await browser.newContext({ viewport: { width: 600, height: 1448 }, deviceScaleFactor: 1 });
      const tallPage = await tallContext.newPage();
      await tallPage.goto(`http://127.0.0.1:${port}/dashboard.html?companion=1`, { waitUntil: "networkidle" });
      const tallReport = await inspect(tallPage);
      validate(`${name} / ignored iframe height`, tallReport, viewport.height);
      if (Math.max(...tallReport.heights.map((height, index) => Math.abs(height - cssReport.heights[index]))) > 1) {
        throw new Error(`${name}: ignored iframe height changed quote card heights`);
      }
      await tallPage.screenshot({ path: path.join(outputDirectory, `${name}-ignored-iframe-height.png`),
                                  clip: { x: 0, y: 0, width: 600, height: 800 } });
      await tallContext.close();

      const legacyContext = await browser.newContext({ viewport: legacyViewport, deviceScaleFactor: 1 });
      const legacyPage = await legacyContext.newPage();
      await legacyPage.goto(`http://127.0.0.1:${port}/companion-harness`, { waitUntil: "networkidle" });
      const frame = legacyPage.frames().find((candidate) => candidate.url().includes("dashboard.html"));
      if (!frame) throw new Error(`${name}: Companion dashboard iframe did not load`);
      const legacyReport = await inspect(frame);
      const frameMetrics = await legacyPage.locator("#dashboard").evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return { innerWidth: element.contentWindow.innerWidth, visualWidth: rect.width, visualHeight: rect.height };
      });
      if (Math.abs(frameMetrics.innerWidth - 600) > 1 || Math.abs(frameMetrics.visualWidth - legacyViewport.width) > 1 ||
          frameMetrics.visualHeight < legacyViewport.height - 1) {
        throw new Error(`${name}: Companion viewport normalization failed: ${JSON.stringify(frameMetrics)}`);
      }
      await legacyPage.screenshot({ path: path.join(outputDirectory, `${name}-legacy-webkit.png`) });
      validate(`${name} / 1072 CSS px`, legacyReport);
      await legacyContext.close();
      process.stdout.write(`PASS ${name} (600px viewport + 1072px legacy width + ignored iframe height)\n`);
    }
  } finally {
    await browser.close();
    server.close();
  }
  process.stdout.write(`Screenshots: ${outputDirectory}\n`);
}

async function runPreview(html, companion, executablePath) {
  const cardCount = Math.max(1, Math.min(3, Number(optionValue("cards", "3")) || 3));
  const stressed = process.argv.includes("--alert");
  const server = createServer(html, companion, () => snapshot(cardCount, stressed));
  const port = await listen(server);
  const browser = await chromium.launch({ headless: false, executablePath });
  const model = optionValue("model", "paperwhite");
  const previewViewport = model === "css" ? viewport : legacyViewport;
  const context = await browser.newContext({ viewport: previewViewport });
  const page = await context.newPage();
  const previewPath = model === "css" ? "/dashboard.html?companion=1" : "/companion-harness";
  await page.goto(`http://127.0.0.1:${port}${previewPath}`);
  process.stdout.write(`Kindle preview: ${cardCount} cards using ${model} model at ${previewViewport.width}x${previewViewport.height}\n`);
  process.stdout.write("Close the preview window to stop the server.\n");
  await new Promise((resolve) => browser.once("disconnected", resolve));
  server.close();
}

const html = fs.readFileSync(dashboardPath, "utf8");
const companion = fs.readFileSync(companionPath, "utf8");
const executablePath = chromeExecutable();
if (process.argv.includes("--check")) {
  assertLegacySurface(`${html}\n${companion}`);
  await runChecks(html, companion, executablePath);
} else {
  await runPreview(html, companion, executablePath);
}
