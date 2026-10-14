const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = __dirname;
const ASSET_DIR = path.join(ROOT, "assets", "icons");
const WIDTH = 1440;
const HEIGHT = 900;

const apps = [
  {
    name: "Xcode",
    category: "开发工具",
    confidence: 98,
    status: "AI 推荐",
    bundleCandidates: ["/Applications/Xcode.app"],
    fallback: { initials: "X", gradient: ["#4aa3ff", "#1976f3"] },
  },
  {
    name: "Cursor",
    category: "开发工具",
    confidence: 96,
    status: "最近常用",
    bundleCandidates: ["/Applications/Cursor.app"],
    fallback: { initials: "C", gradient: ["#111827", "#52525b"] },
  },
  {
    name: "Safari",
    category: "网络浏览",
    confidence: 94,
    status: "自然语言",
    bundleCandidates: ["/Applications/Safari.app", "/System/Applications/Safari.app"],
    fallback: { initials: "S", gradient: ["#38bdf8", "#2563eb"] },
  },
  {
    name: "WeChat",
    category: "沟通协作",
    confidence: 91,
    status: "AI 别名",
    bundleCandidates: ["/Applications/WeChat.app"],
    fallback: { initials: "W", gradient: ["#20d466", "#0f9f4f"] },
  },
  {
    name: "Notion",
    category: "办公效率",
    confidence: 93,
    status: "智能分类",
    bundleCandidates: ["/Applications/Notion.app"],
    fallback: { initials: "N", gradient: ["#ffffff", "#d4d4d8"], ink: "#18181b" },
  },
  {
    name: "Figma",
    category: "设计创作",
    confidence: 88,
    status: "推荐搭配",
    bundleCandidates: ["/Applications/Figma.app"],
    fallback: { initials: "F", gradient: ["#f97316", "#a855f7"] },
  },
  {
    name: "Docker",
    category: "开发工具",
    confidence: 95,
    status: "后台提示",
    bundleCandidates: ["/Applications/Docker.app"],
    fallback: { initials: "D", gradient: ["#38bdf8", "#0284c7"] },
  },
  {
    name: "Photos",
    category: "设计创作",
    confidence: 86,
    status: "系统应用",
    bundleCandidates: ["/System/Applications/Photos.app", "/Applications/Photos.app"],
    fallback: { initials: "P", gradient: ["#fb7185", "#facc15"] },
  },
  {
    name: "Music",
    category: "影音娱乐",
    confidence: 84,
    status: "媒体",
    bundleCandidates: ["/System/Applications/Music.app", "/Applications/Music.app"],
    fallback: { initials: "M", gradient: ["#fb7185", "#ef4444"] },
  },
  {
    name: "1Password",
    category: "安全隐私",
    confidence: 90,
    status: "隐私",
    bundleCandidates: ["/Applications/1Password.app"],
    fallback: { initials: "1P", gradient: ["#60a5fa", "#1d4ed8"] },
  },
  {
    name: "Terminal",
    category: "系统工具",
    confidence: 92,
    status: "终端",
    bundleCandidates: ["/System/Applications/Utilities/Terminal.app", "/Applications/Utilities/Terminal.app"],
    fallback: { initials: ">", gradient: ["#18181b", "#3f3f46"] },
  },
  {
    name: "Mail",
    category: "办公效率",
    confidence: 89,
    status: "邮件",
    bundleCandidates: ["/System/Applications/Mail.app", "/Applications/Mail.app"],
    fallback: { initials: "M", gradient: ["#60a5fa", "#2563eb"] },
  },
  {
    name: "Calendar",
    category: "办公效率",
    confidence: 87,
    status: "日程",
    bundleCandidates: ["/System/Applications/Calendar.app", "/Applications/Calendar.app"],
    fallback: { initials: "31", gradient: ["#f8fafc", "#e5e7eb"], ink: "#ef4444" },
  },
  {
    name: "Zoom",
    category: "沟通协作",
    confidence: 86,
    status: "会议",
    bundleCandidates: ["/Applications/zoom.us.app", "/Applications/Zoom.app"],
    fallback: { initials: "Z", gradient: ["#38bdf8", "#2563eb"] },
  },
  {
    name: "Raycast",
    category: "系统工具",
    confidence: 91,
    status: "启动器",
    bundleCandidates: ["/Applications/Raycast.app"],
    fallback: { initials: "R", gradient: ["#fb7185", "#ef4444"] },
  },
];

function ensureDirs() {
  fs.mkdirSync(ASSET_DIR, { recursive: true });
}

function readPlist(appPath) {
  const plist = path.join(appPath, "Contents", "Info.plist");
  if (!fs.existsSync(plist)) return null;
  try {
    const raw = execFileSync("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function iconPathFor(appPath) {
  const plist = readPlist(appPath);
  const resources = path.join(appPath, "Contents", "Resources");
  const iconName = plist?.CFBundleIconFile || plist?.CFBundleIconName;
  const candidates = [];

  if (iconName) {
    candidates.push(path.join(resources, iconName));
    candidates.push(path.join(resources, `${iconName}.icns`));
    candidates.push(path.join(resources, `${iconName}.png`));
  }

  const appBase = path.basename(appPath, ".app");
  candidates.push(path.join(resources, `${appBase}.icns`));
  candidates.push(path.join(resources, "AppIcon.icns"));
  candidates.push(path.join(resources, "app.icns"));

  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function convertIcon(app) {
  const appPath = app.bundleCandidates.find((candidate) => fs.existsSync(candidate));
  if (!appPath) return null;

  const source = iconPathFor(appPath);
  if (!source) return null;

  const out = path.join(ASSET_DIR, `${app.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase()}.png`);
  try {
    execFileSync("/usr/bin/sips", ["-s", "format", "png", source, "--out", out], {
      stdio: ["ignore", "ignore", "ignore"],
    });
    execFileSync("/usr/bin/sips", ["-z", "256", "256", out, "--out", out], {
      stdio: ["ignore", "ignore", "ignore"],
    });
    return path.relative(ROOT, out);
  } catch {
    try {
      if (fs.existsSync(out)) fs.rmSync(out);
    } catch {}
    return null;
  }
}

function prepareAppIcons() {
  return apps.map((app) => ({
    ...app,
    icon: convertIcon(app),
  }));
}

function fallbackIcon(app) {
  const [start, end] = app.fallback.gradient;
  const ink = app.fallback.ink || "#ffffff";
  return `
    <div class="fallback-icon" style="--start:${start};--end:${end};--ink:${ink}">
      ${app.fallback.initials}
    </div>
  `;
}

function appIcon(app) {
  if (!app.icon) return fallbackIcon(app);
  return `<img class="app-icon" src="${app.icon}" alt="${app.name} icon" />`;
}

function appTile(app, index) {
  return `
    <button class="app-tile ${index < 3 ? "recommended" : ""}">
      <span class="ai-corner">AI</span>
      ${appIcon(app)}
      <span class="app-name">${app.name}</span>
      <span class="tag-row">
        <span class="ai-pill">${app.category}</span>
        <span class="confidence">${app.confidence}%</span>
      </span>
    </button>
  `;
}

function navRow(label, count, active = false) {
  return `
    <div class="nav-row ${active ? "active" : ""}">
      <span class="nav-dot"></span>
      <span>${label}</span>
      <span class="nav-count">${count}</span>
    </div>
  `;
}

function insight(title, body, metric, tone = "teal") {
  return `
    <div class="insight ${tone}">
      <div>
        <strong>${title}</strong>
      </div>
      <span>${metric}</span>
    </div>
  `;
}

function html(theme, appData) {
  const isDark = theme === "dark";
  const themeLabel = isDark ? "Dark" : "Light";
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>App Dock V2 ${themeLabel}</title>
<style>
  :root {
    color-scheme: ${isDark ? "dark" : "light"};
    --canvas: ${isDark ? "#111315" : "#edf1f5"};
    --desktop-a: ${isDark ? "#181a1d" : "#f7f9fb"};
    --desktop-b: ${isDark ? "#0e1012" : "#e8edf2"};
    --window: ${isDark ? "rgba(31, 34, 38, 0.96)" : "rgba(255, 255, 255, 0.94)"};
    --window-soft: ${isDark ? "rgba(255,255,255,0.055)" : "rgba(255,255,255,0.70)"};
    --sidebar: ${isDark ? "rgba(26, 28, 32, 0.86)" : "rgba(245, 247, 250, 0.88)"};
    --panel: ${isDark ? "rgba(255,255,255,0.065)" : "rgba(255,255,255,0.76)"};
    --panel-strong: ${isDark ? "rgba(255,255,255,0.10)" : "rgba(255,255,255,0.92)"};
    --hairline: ${isDark ? "rgba(255,255,255,0.12)" : "rgba(24, 33, 45, 0.10)"};
    --text: ${isDark ? "#f4f6f8" : "#18212f"};
    --muted: ${isDark ? "#a9b0ba" : "#667085"};
    --faint: ${isDark ? "#737b87" : "#8b95a3"};
    --blue: #3b82f6;
    --teal: #14b8a6;
    --green: #22c55e;
    --orange: #f59e0b;
    --pink: #ec4899;
    --purple: #8b5cf6;
    --shadow: ${isDark ? "0 28px 90px rgba(0,0,0,0.46)" : "0 28px 90px rgba(41, 55, 80, 0.18)"};
  }

  * { box-sizing: border-box; }
  html, body { margin: 0; width: ${WIDTH}px; height: ${HEIGHT}px; overflow: hidden; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", "PingFang SC", "Segoe UI", sans-serif;
    color: var(--text);
    background:
      linear-gradient(145deg, var(--desktop-a), var(--desktop-b));
  }

  .frame {
    width: ${WIDTH}px;
    height: ${HEIGHT}px;
    padding: 32px 38px;
  }

  .window {
    position: relative;
    width: 1364px;
    height: 836px;
    margin: 0 auto;
    display: grid;
    grid-template-columns: 190px 1fr 256px;
    background: var(--window);
    border: 1px solid var(--hairline);
    border-radius: 18px;
    overflow: hidden;
    box-shadow: var(--shadow);
  }

  .traffic {
    position: absolute;
    top: 18px;
    left: 18px;
    display: flex;
    gap: 8px;
    z-index: 5;
  }
  .traffic span {
    width: 12px;
    height: 12px;
    border-radius: 999px;
    display: block;
  }
  .traffic span:nth-child(1) { background: #ff5f57; }
  .traffic span:nth-child(2) { background: #febc2e; }
  .traffic span:nth-child(3) { background: #28c840; }

  aside {
    padding: 56px 12px 16px;
    background: var(--sidebar);
    border-right: 1px solid var(--hairline);
  }

  .brand {
    padding: 0 8px 14px;
  }
  .brand h1 {
    margin: 0;
    font-size: 22px;
    line-height: 1.15;
    font-weight: 720;
  }
  .brand p {
    margin: 6px 0 0;
    font-size: 11px;
    color: var(--muted);
  }

  .nav-section {
    margin-top: 12px;
  }
  .section-title {
    padding: 0 9px 7px;
    font-size: 11px;
    color: var(--faint);
    font-weight: 650;
  }
  .nav-row {
    height: 32px;
    border-radius: 8px;
    display: grid;
    grid-template-columns: 13px 1fr auto;
    align-items: center;
    gap: 8px;
    padding: 0 9px;
    margin: 2px 0;
    color: var(--muted);
    font-size: 12px;
    font-weight: 560;
  }
  .nav-row.active {
    color: var(--text);
    background: ${isDark ? "rgba(20, 184, 166, 0.18)" : "rgba(20, 184, 166, 0.14)"};
  }
  .nav-dot {
    width: 8px;
    height: 8px;
    border-radius: 99px;
    background: var(--hairline);
  }
  .nav-row.active .nav-dot { background: var(--teal); box-shadow: 0 0 0 4px rgba(20,184,166,0.15); }
  .nav-count {
    font-size: 11px;
    color: var(--faint);
  }

  .sidebar-card {
    margin: 14px 4px 0;
    border-radius: 8px;
    border: 1px solid var(--hairline);
    padding: 10px;
    background: var(--panel);
  }
  .sidebar-card strong {
    display: block;
    font-size: 13px;
    margin-bottom: 5px;
  }
  .sidebar-card p { display: none; }

  main {
    display: flex;
    flex-direction: column;
    min-width: 0;
  }

  header {
    height: 78px;
    padding: 14px 24px 12px;
    border-bottom: 1px solid var(--hairline);
    display: grid;
    grid-template-columns: 1fr 420px;
    gap: 16px;
    align-items: center;
    background: ${isDark ? "rgba(255,255,255,0.025)" : "rgba(255,255,255,0.48)"};
  }
  .headline h2 {
    margin: 0;
    font-size: 26px;
    line-height: 1.1;
    font-weight: 760;
  }
  .headline p {
    margin: 4px 0 0;
    color: var(--muted);
    font-size: 12px;
  }
  .search {
    height: 44px;
    border-radius: 8px;
    border: 1px solid var(--hairline);
    background: var(--panel-strong);
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 0 14px;
    color: var(--muted);
    font-size: 14px;
    box-shadow: ${isDark ? "none" : "0 8px 22px rgba(31, 41, 55, 0.06)"};
  }
  .search .spark {
    width: 24px;
    height: 24px;
    border-radius: 7px;
    display: grid;
    place-items: center;
    color: white;
    font-weight: 780;
    background: linear-gradient(135deg, var(--teal), var(--blue));
  }
  .search .key {
    margin-left: auto;
    color: var(--faint);
    font-size: 12px;
    border: 1px solid var(--hairline);
    border-radius: 6px;
    padding: 3px 7px;
  }

  .content {
    padding: 14px 24px 22px;
    min-height: 0;
    overflow: hidden;
  }
  .recommend-strip {
    display: grid;
    grid-template-columns: 1.2fr 1fr 1fr;
    gap: 10px;
    margin-bottom: 12px;
  }
  .recommend {
    height: 58px;
    border-radius: 8px;
    border: 1px solid var(--hairline);
    background: var(--panel);
    padding: 9px 10px;
    display: flex;
    align-items: center;
    gap: 9px;
  }
  .recommend strong {
    display: block;
    font-size: 13px;
    margin-bottom: 0;
  }
  .recommend p {
    display: none;
  }
  .mini-icon {
    width: 36px;
    height: 36px;
    border-radius: 9px;
    display: grid;
    place-items: center;
    color: white;
    font-weight: 800;
    background: linear-gradient(135deg, var(--teal), var(--green));
    flex: 0 0 auto;
  }

  .grid-head {
    height: 30px;
    display: flex;
    align-items: center;
    margin-bottom: 10px;
  }
  .grid-head h3 {
    margin: 0;
    font-size: 16px;
    font-weight: 720;
  }
  .grid-head span {
    margin-left: 8px;
    font-size: 11px;
    color: var(--muted);
  }
  .segmented {
    margin-left: auto;
    display: flex;
    padding: 3px;
    border-radius: 8px;
    background: ${isDark ? "rgba(255,255,255,0.07)" : "rgba(24,33,45,0.06)"};
  }
  .segmented span {
    margin: 0;
    border-radius: 6px;
    padding: 5px 10px;
    font-size: 12px;
    color: var(--muted);
  }
  .segmented span:first-child {
    background: var(--panel-strong);
    color: var(--text);
  }

  .app-grid {
    display: grid;
    grid-template-columns: repeat(5, 1fr);
    gap: 18px 16px;
  }
  .app-tile {
    position: relative;
    height: 164px;
    border: 1px solid transparent;
    border-radius: 14px;
    background: transparent;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    padding: 16px 8px 12px;
    font: inherit;
    color: var(--text);
    box-shadow: none;
  }
  .app-tile.recommended {
    background: ${isDark ? "rgba(20,184,166,0.105)" : "rgba(20,184,166,0.075)"};
    border-color: ${isDark ? "rgba(45,212,191,0.22)" : "rgba(20,184,166,0.18)"};
  }
  .ai-corner {
    position: absolute;
    top: 12px;
    right: 12px;
    height: 20px;
    min-width: 24px;
    display: grid;
    place-items: center;
    border-radius: 999px;
    color: ${isDark ? "#99f6e4" : "#0f766e"};
    background: ${isDark ? "rgba(20,184,166,0.18)" : "rgba(20,184,166,0.13)"};
    font-size: 10px;
    font-weight: 760;
  }
  .app-icon,
  .fallback-icon {
    width: 76px;
    height: 76px;
    border-radius: 18px;
    object-fit: contain;
    margin-bottom: 10px;
    filter: drop-shadow(0 10px 18px rgba(0, 0, 0, ${isDark ? "0.30" : "0.12"}));
  }
  .fallback-icon {
    display: grid;
    place-items: center;
    color: var(--ink);
    background: linear-gradient(135deg, var(--start), var(--end));
    font-weight: 820;
    font-size: 27px;
    box-shadow: inset 0 0 0 1px rgba(255,255,255,0.18);
  }
  .app-name {
    font-size: 15px;
    font-weight: 680;
    line-height: 20px;
  }
  .tag-row {
    margin-top: 8px;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  .ai-pill {
    font-size: 10px;
    font-weight: 680;
    color: ${isDark ? "#99f6e4" : "#0f766e"};
    background: ${isDark ? "rgba(20,184,166,0.16)" : "rgba(20,184,166,0.12)"};
    border: 1px solid ${isDark ? "rgba(45,212,191,0.20)" : "rgba(20,184,166,0.18)"};
    border-radius: 999px;
    padding: 3px 7px;
  }
  .confidence {
    color: var(--faint);
    font-size: 10px;
  }

  .assistant {
    padding: 56px 16px 16px;
    background: ${isDark ? "rgba(22,24,28,0.92)" : "rgba(248,250,252,0.82)"};
    border-left: 1px solid var(--hairline);
    display: flex;
    flex-direction: column;
  }
  .assistant h3 {
    margin: 0;
    font-size: 18px;
    font-weight: 740;
  }
  .assistant .sub { display: none; }
  .ai-status {
    height: 68px;
    border-radius: 8px;
    padding: 11px;
    background: linear-gradient(135deg, rgba(20,184,166,0.18), rgba(59,130,246,0.12));
    border: 1px solid ${isDark ? "rgba(45,212,191,0.28)" : "rgba(20,184,166,0.25)"};
    display: grid;
    grid-template-columns: 38px 1fr;
    align-items: center;
    gap: 10px;
    margin: 12px 0 12px;
  }
  .ai-mark {
    width: 38px;
    height: 38px;
    border-radius: 9px;
    display: grid;
    place-items: center;
    color: white;
    font-weight: 850;
    background: linear-gradient(135deg, var(--teal), var(--blue));
  }
  .ai-status strong {
    display: block;
    font-size: 13px;
    margin-bottom: 2px;
  }
  .ai-status p {
    margin: 0;
    font-size: 11px;
    color: var(--muted);
    line-height: 1.35;
  }

  .insights {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .insight {
    border-top: 1px solid var(--hairline);
    padding: 10px 0 1px;
    display: grid;
    grid-template-columns: 1fr auto;
    gap: 12px;
    align-items: start;
  }
  .insight strong {
    font-size: 13px;
  }
  .insight > span {
    font-size: 12px;
    font-weight: 760;
    border-radius: 999px;
    padding: 4px 8px;
  }
  .insight.teal > span { color: #0f766e; background: rgba(20,184,166,0.14); }
  .insight.blue > span { color: #2563eb; background: rgba(59,130,246,0.14); }
  .insight.orange > span { color: #b45309; background: rgba(245,158,11,0.15); }
  .insight.pink > span { color: #be185d; background: rgba(236,72,153,0.14); }

  .workflow {
    margin-top: 14px;
    border-radius: 8px;
    border: 1px solid var(--hairline);
    background: var(--panel);
    padding: 10px;
  }
  .workflow strong {
    display: block;
    font-size: 13px;
    margin-bottom: 9px;
  }
  .flow-line {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 7px;
  }
  .flow-line span {
    min-width: 0;
    text-align: center;
    border-radius: 7px;
    padding: 8px 4px;
    font-size: 11px;
    color: var(--text);
    background: ${isDark ? "rgba(255,255,255,0.07)" : "rgba(24,33,45,0.055)"};
  }
  .safe-note {
    margin-top: auto;
    border-top: 1px solid var(--hairline);
    padding-top: 12px;
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--muted);
    font-size: 11px;
  }
  .safe-dot {
    width: 9px;
    height: 9px;
    border-radius: 99px;
    background: var(--green);
    box-shadow: 0 0 0 4px rgba(34,197,94,0.14);
  }
</style>
</head>
<body>
  <div class="frame">
    <section class="window">
      <div class="traffic"><span></span><span></span><span></span></div>

      <aside>
        <div class="brand">
          <h1>App Dock</h1>
          <p>AI 原生的 macOS 应用启动器</p>
        </div>

        <div class="nav-section">
          <div class="section-title">智能入口</div>
          ${navRow("AI 推荐", "12", true)}
          ${navRow("最近使用", "8")}
          ${navRow("自动整理新应用", "3")}
        </div>

        <div class="nav-section">
          <div class="section-title">AI 分类</div>
          ${navRow("开发工具", "24")}
          ${navRow("设计创作", "11")}
          ${navRow("沟通协作", "9")}
          ${navRow("办公效率", "18")}
          ${navRow("全部应用", "128")}
        </div>

        <div class="sidebar-card">
          <strong>自然语言搜索</strong>
          <p>试试 “打开写代码的工具” 或 “最近用过的设计软件”。</p>
        </div>
      </aside>

      <main>
        <header>
          <div class="headline">
            <h2>App Dock</h2>
            <p>一键打开应用，AI 帮你智能分类、自然语言搜索和推荐打开。</p>
          </div>
          <div class="search">
            <span class="spark">AI</span>
            <span>AI 搜索应用、类别或任务</span>
            <span class="key">⌘ K</span>
          </div>
        </header>

        <div class="content">
          <div class="recommend-strip">
            <div class="recommend">
              <div class="mini-icon">AI</div>
              <div>
                <strong>推荐打开 Cursor</strong>
                <p>你通常在上午先打开开发工具，接着使用 Safari 查资料。</p>
              </div>
            </div>
            <div class="recommend">
              <div class="mini-icon" style="background:linear-gradient(135deg,var(--purple),var(--pink))">7</div>
              <div>
                <strong>7 个应用已自动归类</strong>
                <p>新安装应用已加入开发工具和设计创作分组。</p>
              </div>
            </div>
            <div class="recommend">
              <div class="mini-icon" style="background:linear-gradient(135deg,var(--orange),var(--green))">2</div>
              <div>
                <strong>2 个轻量安全提示</strong>
                <p>仅在详情中展示，不影响启动器主流程。</p>
              </div>
            </div>
          </div>

          <div class="grid-head">
            <h3>AI 推荐应用</h3>
            <span>按最近使用、任务语义和分类置信度排序</span>
            <div class="segmented"><span>图标</span><span>列表</span></div>
          </div>
          <div class="app-grid">
            ${appData.map(appTile).join("")}
          </div>
        </div>
      </main>

      <section class="assistant">
        <h3>AI 助手</h3>
        <p class="sub">持续学习你的应用打开习惯，自动把本机应用整理成可搜索、可启动的智能 Dock。</p>
        <div class="ai-status">
          <div class="ai-mark">✦</div>
          <div>
            <strong>智能整理完成</strong>
            <p>128 个应用已分类，42 个应用带有 AI 标签。</p>
          </div>
        </div>

        <div class="insights">
          ${insight("推荐打开", "Cursor、Xcode、Safari 构成你的开发启动组。", "96%", "teal")}
          ${insight("新安装应用已分类", "Docker 已识别为开发工具，并标记后台提示。", "3 新", "blue")}
          ${insight("高频工作流", "开发工具 → 浏览器 → 沟通协作，是你最常见的路径。", "上午", "orange")}
          ${insight("自然语言命中", "“写代码”“会议”“看视频” 会映射到对应应用。", "AI", "pink")}
        </div>

        <div class="workflow">
          <strong>今日建议分组</strong>
          <div class="flow-line">
            <span>开发</span>
            <span>设计</span>
            <span>沟通</span>
          </div>
        </div>

        <div class="safe-note">
          <span class="safe-dot"></span>
          <span>安全详情已收起为轻量提示，首页保持启动器体验。</span>
        </div>
      </section>
    </section>
  </div>
</body>
</html>`;
}

async function render(theme, appData) {
  const htmlPath = path.join(ROOT, `app-dock-v2-${theme}.html`);
  const pngPath = path.join(ROOT, `app-dock-v2-${theme}.png`);
  fs.writeFileSync(htmlPath, html(theme, appData), "utf8");

  const python = `
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

html_path = Path(sys.argv[1]).resolve()
png_path = Path(sys.argv[2]).resolve()
width = int(sys.argv[3])
height = int(sys.argv[4])
browser_candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
]
executable_path = next((candidate for candidate in browser_candidates if Path(candidate).exists()), None)

with sync_playwright() as p:
    launch_options = {"headless": True}
    if executable_path:
        launch_options["executable_path"] = executable_path
    browser = p.chromium.launch(**launch_options)
    page = browser.new_page(viewport={"width": width, "height": height}, device_scale_factor=1)
    page.goto(html_path.as_uri())
    page.screenshot(path=str(png_path), full_page=False, animations="disabled")
    browser.close()
`;

  execFileSync("python3", ["-c", python, htmlPath, pngPath, String(WIDTH), String(HEIGHT)], {
    stdio: "inherit",
  });
}

async function main() {
  ensureDirs();
  const appData = prepareAppIcons();
  await render("light", appData);
  await render("dark", appData);
  console.log("Generated:");
  console.log(path.join(ROOT, "app-dock-v2-light.png"));
  console.log(path.join(ROOT, "app-dock-v2-dark.png"));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
