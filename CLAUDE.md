# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目性质

ClaudeViewer 是一个**单文件**浏览器应用：`claude_viewer.html`（约 940 KB，含内联依赖）。没有构建系统、没有依赖管理器、没有测试框架。改代码 = 直接编辑这一个文件，改完在浏览器里刷新即可验证。

产品底线（来自 `docs/ROADMAP.md`，任何新功能都必须遵守，违背者不做）：

1. **本地优先** — 数据只在浏览器内处理，绝不上传，不引入后端。
2. **单文件优先** — 核心查看器永远是一个可双击打开的 HTML；重型能力只能做成可选伴侣。
3. **零外部请求** — 不得新增 CDN 链接、外部字体、fetch 到第三方；不得埋点追踪。
4. `file://` 直接打开必须可用（因此不能依赖 fetch 本地文件、module script、Service Worker 等受 origin 限制的能力）。

`claude_viewer.html` 头部有 GPL-3.0 版权声明与作者署名注释（第 5–17 行）以及页面内的署名区块（`.u-credit` / `.sb-credit`），**任何修改都必须保留**。

## 常用命令

```bash
# 运行：直接用浏览器打开（推荐 Chrome/Edge）
start claude_viewer.html                    # Windows
python -m http.server 8000                  # 需要测试 File System Access API 时用 localhost

# 演示数据（内联的 DEMO_DATA，无需导入文件）
# 打开 claude_viewer.html?demo=1

# 仅在新增/升级三方库时才需要跑（会重写 claude_viewer.html 的 vendor 区块）
python build/build.py
```

没有 lint / test 命令。验证靠手动：导入 ZIP → 看对话（含 thinking / 工具调用 / LaTeX / 附件）→ 对话内搜索 → 全局搜索 → 统计页 → 导出 MD/PDF → 深色模式 → 移动端窄屏 → Claude Code 模式。

## 文件内部结构（按行区间）

`claude_viewer.html` 共约 2600 行，但第 21–46 行是压缩后的单行巨型内容——**不要整文件读取，也不要用 grep 不带行号范围地扫**：

| 行区间 | 内容 |
|---|---|
| 1–20 | `<head>` + GPL 版权注释 |
| 21–46 | `<!-- vendor:start … vendor:end -->` **由 `build/build.py` 生成，禁止手改**：JSZip 3.10.1、marked 9.1.6、KaTeX 0.16.9（JS/CSS/base64 字体）、auto-render |
| 47–578 | 全部 CSS。主题靠 `:root` / `[data-theme="dark"]` 的 CSS 变量，深色模式只切 `data-theme` |
| 580–702 | HTML 骨架：`#upload-screen`、`#main-screen`（`#sidebar` + `#content-area`）、`#modal-overlay`、`#loading`、`#print-area` |
| 703–2623 | 全部 JS，单个 `(function(){'use strict'; … })()` IIFE |

JS 内部顺序：常量与 `DEMO_DATA` → STATE → IndexedDB → DOM 引用 → 导入解析 → Tab/侧栏渲染 → 统计 → 对话渲染 → 搜索 → 导出 → Claude Code 模式 → 工具函数 → 事件绑定。

## 架构要点

### 两种数据模式，一套查看器

`appMode` 为 `'export'`（Claude.ai 导出包）或 `'cc'`（Claude Code 本地会话），侧栏 ⇄ 按钮切换，互不清空（`applyMode()`）。

- **export 模式**：`loadFiles()` → `parseZip()` / `classifyJson()` / `classifyMd()` 按文件名把数据塞进 `appData{convs,projects,memories,account,globalMemory}` → `finalizeData()` 过滤空对话、按 uuid 去重项目、生成 `filteredConvs` 列表摘要。
- **cc 模式**：`CCStore` 是文件访问抽象，两套后端——安全上下文用 File System Access API（`showDirectoryPicker`，懒加载单个文件），`file://` 降级为 `<input webkitdirectory>`（`ccPickWebkitDir` + `ccIndexWebFiles` 一次性索引）。**全程只读，绝不写用户的 `.claude` 目录。**

关键设计：`ccToConv()` 是**归一化适配器**，把 `projects/**/*.jsonl` 逐行记录转成与导出包同构的 conv 对象（`{uuid,name,created_at,chat_messages[{sender,content[]}],_cc:{…}}`），塞进 `ccConvCache`。因此 `openConv()`、渲染、导航条、对话内搜索、MD 导出全部零改动复用。**新增数据来源时照此模式做适配器，不要在渲染层加分支。**

消息内容统一是 `content[]` 块数组，块类型：`text` / `thinking` / `tool_use` / `tool_result`，分别由 `buildMsg` 里的 `buildThinking` / `buildToolBlock` / `buildAttachment` 渲染。

### 渲染：全渲染 / 虚拟滚动双模式

`initVS()` 按 `FULL_RENDER_THRESHOLD`(=500) 选择：

- `initFullRender()` — 消息全部进普通文档流（流畅 + 浏览器 Ctrl+F 可用）。
- `initVirtualScroll()` — 绝对定位 + `heights/offsets` 估高，滚动时 `renderVisible()` 在 rAF 里补渲染并回填真实高度。

**改任何会影响消息高度的东西（折叠块展开、图片、KaTeX 渲染完成）时，虚拟滚动模式下必须调用 `reflowMsgHeight(wrap)` 回填高度**，否则后续消息位置全错。跨两种模式取消息位置一律走 `msgTop(idx)`，别直接读 `offsets`。

### 搜索

- 对话内：`doSearch()` 收集命中 → `applyHL()`/`hlEl()` 注入 `<mark>`，`removeHL()` 还原；`nextHit()` 逐次跳转，`renderSrchSidebar()` 是结果面板。高亮是对已渲染 DOM 做的，虚拟滚动模式下每次 `renderVisible()` 后会重新 `applyHL()`。
- 跨对话：`doGlobalSearch()`（export 模式，扫 `appData.convs`）与 `doCCSearch()` → `CCStore.searchAll()`（cc 模式，逐文件读文本）。

### 导出

- MD：`convToMd()` + `shiftMdHeadings()`（把正文标题整体降 2 级，围栏内不动）+ `mdFence()`（围栏长度 = 内容中最长反引号串 +1，防击穿）。文件名以对话创建时间开头。
- PDF：`renderMdForExport()` 在父窗口用已内联的 marked + KaTeX **预渲染**，把 HTML 烘焙进弹窗——弹窗里没有任何脚本，才能离线打印。
- 批量：`exportAllZip()` 用 JSZip 打包。

### 持久化

- IndexedDB `claude_viewer_v4` / objectStore `store`：完整 `appData`（仅当用户选择「保存到本地」）。
- localStorage：`cv_favs`（收藏）、`cv_tags`（标签）、`cv_dark`、`cv_cachemode`（`always`/`never`/空）。不存对话内容。

## 编码约定

- 版本号只有一处：JS 顶部的 `APP_VERSION`，运行时覆盖 `document.title` 和 `#ver-badge`。`<head>` 里的静态 `<title>` 自 v5.7 起**不带版本号**（此前长期停留在 v5.5，在 JS 执行前/GitHub 浏览源码时会显示过时版本，造成误解），不要再往里加版本号。
- 全部用原生 API，不引框架、不引 npm。新库只能通过 `build/build.py` 内联，且要先确认体积与「零外部请求」是否值得。
- DOM 用 `$(id)` 取，常用节点在 703 行后统一声明为 const；风格是紧凑单行 + 中文注释标注版本来源（如 `// v5.6: …`），跟随周围写法。
- 任何插入用户/对话文本的地方走 `esc()`（`innerHTML` 场景）或 `textContent`。
- 其他工具函数：`fmtDate`/`fmtFull`/`fmtFileTime`/`fmtTok`/`formatBytes`/`download`。

## 发布

- 发版快照放 `_release/claude_viewer_v{X.Y}.html`；`.gitignore` 忽略 `_*/`，不入库。
- 同步更新：`APP_VERSION`、`README.md` + `README.en.md`（功能表 + 版本历史，双语必须同时改）、必要时 `docs/ROADMAP.md`。
- `vercel.json` 把 `/` rewrite 到 `/claude_viewer.html`，在线体验站即由此部署。
