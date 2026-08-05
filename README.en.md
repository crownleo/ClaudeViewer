# 🗂️ Claude Data Viewer v5.5

[简体中文](README.md) · **English**

> Runs locally · Zero install · Your data never leaves your device

A single-file HTML tool for viewing and analyzing your personal data exported from Claude.ai. Double-click to use — no server, no network, no account required. **Since v5.2, all dependencies are inlined into the single file, so it works fully offline with zero external requests.**

🔗 **Live demo**: <https://claudeviewersite.crownleo.cn/>
📥 **Download**: [latest release](https://github.com/crownleo/ClaudeViewer/releases/latest)　·　🗺️ [Roadmap](docs/ROADMAP.md)

<p align="center"><img src="assets/main.png" alt="Claude Data Viewer" width="640"></p>

> The live demo also runs entirely in your browser and uploads nothing. For long-term use, [download the single file](https://github.com/crownleo/ClaudeViewer/releases/latest) and keep it offline.

---

## ✨ Features

### Data Import
| Method | Notes |
|---|---|
| Drop `.zip` | Auto-parses all JSON inside the archive in one step |
| Drop / pick `.json` | Multiple files at once supported |
| Drop / pick `.md` | Import custom global-memory files |
| Auto-filter empty chats | Conversations with no message content are hidden |
| Local persistent cache | Optionally save to the browser to skip re-importing next time |

### Conversation Viewing
| Feature | Notes |
|---|---|
| Human / Assistant bubbles | Human right-aligned (sand color), Claude left-aligned (white, bordered) |
| Full timestamps | Every message shows YYYY-MM-DD HH:MM |
| Markdown rendering | Headings, code blocks, tables, quotes, etc. fully supported |
| LaTeX rendering | Inline `$...$` and block `$$...$$` formulas (KaTeX) |
| One-click code copy | Copy button on each code block, shown on hover |
| Thinking blocks | Collapsed by default, click to expand; light italic style |
| Attachment display | Filename badge + collapsible txt/py/md content |
| Jump to top/bottom | Floating buttons in the message area for long chats |
| Hybrid rendering | ≤500 messages render all at once (smooth + Ctrl+F); longer chats auto virtual-scroll |

### Search
| Feature | Notes |
|---|---|
| In-conversation search | Keyword highlight, ↑↓ occurrence-level navigation, match count |
| Search-result sidebar | See all hits at a glance, click to jump |
| Global search | Full-text search across all conversations, click to locate the exact message |
| Title filter | Live filtering at the top of the conversation list |

### Data Management
| Feature | Notes |
|---|---|
| ⭐ Favorites | Star conversations, filter by "favorites only" |
| 🏷 Tags | Custom tag classification, multi-tag filtering, persisted |
| 📋 One-click copy | Copy message / thinking / attachment content |
| 🫥 Collapse all-empty chats | Conversations whose messages are all empty in the export are collapsed by default; the filter bar shows the count and expands them in one click (preference persisted) |

### Statistics & Analysis
| Feature | Notes |
|---|---|
| Overview | Conversation / message / thinking-block / attachment / project counts |
| Monthly bar chart | Distribution of conversation creation time |
| Activity heatmap | Per-day heatmap, hover to inspect, click to filter that day's chats |
| Message ranking | Top 10 conversations by message count, click to open |
| 🩺 Data health check | Detects messages that are empty in the export itself (count/share, worst-affected conversations, monthly distribution) with one-click report copy — tells "the platform generated nothing" apart from "the viewer didn't display it" |

### Multi-type Data
| Tab | Source | Content |
|---|---|---|
| 💬 Conversations | `conversations.json` | Messages, thinking, attachments |
| 🔍 Global Search | All conversations | Cross-conversation full-text search |
| 📊 Statistics | All conversations | Analysis & visualization |
| 📁 Projects | `projects/*.json` | System prompt, docs, **project memory** |
| 🧠 Memory | `.md` import | **Global memory** (manual export/import) |
| 👤 Account | `users.json` | Basic info & stats |

### Export
| Feature | Action | Output |
|---|---|---|
| Export current chat as Markdown | Detail page "↓ MD" | `.md` file with thinking blocks and attachments |
| Export current chat as PDF | Detail page "↓ PDF" | New window → print → save as PDF (with formulas) |
| Batch export all chats | List page "↓ Export All" | `.zip`, one MD file per conversation |
| Export memory file | Memory tab "↓ Export" | `.md` file |

### Interface
| Feature | Notes |
|---|---|
| 🌙 Dark mode | One-click toggle, Claude warm dark theme, state persisted |
| 📱 Mobile support | Single-column master-detail on phones; full-width list/detail with back-to-list |
| Top nav bar | Current conversation name + back button |

---

## 📸 Screenshots

| Conversation view · navigator | Global search |
|---|---|
| ![Conversation view](assets/nav.png) | ![Global search](assets/search.png) |
| **Statistics** | **Projects** |
| ![Statistics](assets/stats.png) | ![Projects](assets/projects.png) |
| **Memory** | **Tool calls** |
| ![Memory](assets/mem.png) | ![Tool calls](assets/tool.png) |
| **LaTeX rendering** | **Dark mode** |
| ![LaTeX rendering](assets/latex.png) | ![Dark mode](assets/dark.png) |

---

## 🚀 Quick Start

### Step 1: Get your Claude export
1. Open [claude.ai](https://claude.ai) and sign in
2. Avatar → **Settings** → **Privacy** → **Export data**
3. Click **Export** and wait for the email (usually within minutes)
4. Download the `.zip` from the email

### Step 2: Open the viewer
Double-click `claude_viewer.html` to open it in your browser.

> **Recommended browsers**: Chrome / Edge
> Safari can view conversations fine, but PDF export is limited.

### Step 3: Import your data
**Drag the `.zip` directly** onto the page to parse everything automatically. After a successful import you can choose whether to save it locally.

---

## 🧮 About LaTeX Rendering

ClaudeViewer renders the **LaTeX text Claude writes in the message body**:

| Form | Rendered? |
|---|---|
| Inline `$...$`, `\(...\)` | ✅ Rendered |
| Block `$$...$$`, `\[...\]` | ✅ Rendered |
| ` ```latex ` code blocks | ⚪ Shown as source (code blocks aren't rendered, as expected) |
| Special widget/visualization blocks | ❌ No source in export, shows a friendly notice |

> To ensure formulas display in your export, you can ask Claude to "write formulas as body LaTeX, not as code blocks or visualization widgets."

---

## ⌨️ Keyboard Shortcuts

| Action | Shortcut |
|---|---|
| Run in-conversation search | `Enter` |
| Jump to next result | `Enter` (when results exist) |
| Run global search | `Enter` (in the global search box) |
| Confirm adding a tag | `Enter` |
| Cancel adding a tag | `Escape` |

---

## 🔒 Privacy

- **Fully local**: all data is processed only in your browser, never sent to any server
- **Zero external requests**: since v5.2, marked.js, JSZip, KaTeX and its fonts are all inlined into the single file — opening the page makes no request to any CDN or third party, and it works fully offline
- **No persistence by default**: unless you explicitly choose "save locally"
- **IndexedDB cache**: if you save, data lives in this device's browser, readable only locally, clearable anytime
- **localStorage**: favorites, tags, dark mode, cache preference (no conversation content)

---

## 📦 Tech Stack

- Vanilla HTML / CSS / JavaScript, no framework
- [marked.js 9.1.6](https://marked.js.org/) — Markdown rendering (inlined)
- [JSZip 3.10.1](https://stuk.github.io/jszip/) — ZIP parsing & generation (inlined)
- [KaTeX 0.16.9](https://katex.org/) — LaTeX rendering, fonts included (inlined)
- Dependency inlining: third-party libs and KaTeX fonts are inlined into the single file via [`build/build.py`](build/build.py), zero CDN, fully offline; re-run the script to upgrade a dependency
- Hybrid rendering: full render ≤500 / virtual scroll for long chats (absolute positioning + requestAnimationFrame)
- Charts / heatmap: inline SVG + DOM, no third-party chart library
- Local persistence: IndexedDB
- Dark mode: CSS variables + `data-theme` toggle

---

## 🌐 Browser Compatibility

| Browser | Viewing | PDF Export | Local Cache | Recommended |
|---|---|---|---|---|
| Chrome 90+ | ✅ | ✅ | ✅ | ⭐ Best |
| Edge 90+ | ✅ | ✅ | ✅ | ✅ |
| Firefox 88+ | ✅ | ✅ | ✅ | ✅ |
| Safari (Mac) | ✅ | ⚠️ Limited | ✅ | — |

> **Safari note**: Safari sometimes auto-unzips downloaded ZIPs. If so, right-click the extracted folder → Compress, or disable "Open safe files after downloading" in Safari settings.
> **Local cache note**: When opened from local `file://`, Chrome/Edge treat all local files as one origin, sharing a single IndexedDB (moving/renaming the file keeps data, but isolation between local HTML files is weak). Firefox differs. For long-term storage, back up with "↓ Export All".

---

## 📁 Export Package Files

| File | Content |
|---|---|
| `conversations.json` | All conversations (messages, timestamps, thinking, attachments) |
| `users.json` | Basic account info |
| `memories.json` | Project memory data (view under the corresponding project in the "Projects" tab) |
| `projects/{uuid}.json` | Project metadata (name, system prompt, docs) |

> Personal (global) memory is what Claude remembers about you across conversations. It lives in the export's `memories.json` and shows in the "Memory" tab automatically after importing the ZIP. You can also import your own extra `.md` memory files.

---

## ❓ FAQ: Why does my conversation "lose half of itself"?

Some users report that a conversation starts as a normal back-and-forth but **the second half shows only their own messages**, and suspect the viewer dropped data.

**Conclusion: in the vast majority of cases those replies were already empty on claude.ai — the viewer did not lose them.**

When Claude fails to generate or gets interrupted, it leaves an **empty message** in the conversation — at the time, the web page showed a blank bubble. The export faithfully records it as a message shell with `"content": [], "text": ""` (uuid and timestamps present, just no content).

v5.6 and earlier **silently filtered these out**, so "Claude produced no output" was displayed as "the message never existed" — which looks exactly like the second half of a conversation losing one side.

**Fixed in v5.7**: empty messages now render as a grey placeholder, conversation cards carry a `⚠ N` badge, and all-empty conversations no longer vanish from the list.

### How to check your own export

Open the **Statistics** tab and scroll to **🩺 Data Health Check** at the bottom. It reports:

- how many empty messages the export contains, and what share of the total
- which conversations are worst affected (empty count, longest empty run)
- the monthly distribution of empty messages — a spike in specific months indicates a platform-side outage, not a problem with your data or this tool
- a one-click "copy report" button for reporting issues

You can also verify by hand: unzip the export, open `conversations.json` in a text editor, and find the affected conversation. A run of `assistant` messages with `"content": [], "text": ""` means the original conversation was empty — no viewer can recover it, and claude.ai showed blank bubbles at the time too.

### Other causes of "incomplete history"

| Symptom | Cause | Fix |
|---|---|---|
| Whole stretches of history missing | The `batch-0000` in the export filename means it is sharded; large accounts also get `batch-0001`, `batch-0002`, … | Import every shard ZIP |
| Multiple answers to the same question | You edited a prompt or hit "regenerate"; the export contains all branches | Expected, not data loss |
| Attachment contents unavailable | The export only carries attachment uuid references, not the files themselves | Platform limitation, unrecoverable |

---

## 📋 Version History

**v5.7** — **Fixes the "conversation loses half of itself" display bug + data health check.** ① **Empty messages are no longer silently dropped** — messages left empty by a failed generation now render as a grey placeholder; previously the second half of a conversation appeared to lose one side entirely and was mistaken for viewer data loss; ② **Attachment-only messages** (a file uploaded with no text typed) are no longer judged empty and discarded, which previously took the attachment down with them; ③ **All-empty conversations no longer disappear** from the list — collapsed by default to keep the list clean, but the filter bar permanently shows a "🫥 N all-empty conversations hidden" chip that expands them in one click, instead of them silently vanishing; ④ conversation cards gain a `⚠ N` badge showing the empty-message count; ⑤ the Statistics tab gains **🩺 Data Health Check** — empty-message count/share, worst-affected conversations, monthly distribution, and a one-click copy of the report, so anyone can self-diagnose without Python or a command line; ⑥ Markdown / PDF export emit the same placeholder note instead of leaving a bare heading.

**v5.6** — **Claude Code local sessions.** The upload screen gains "📂 Open Claude Code local conversations": pick your `.claude` directory to browse `projects/**/*.jsonl` sessions read-only — ① grouped by project with turn count / tokens / size / time, marking active ● and Agent sessions; ② cross-project full-text search; ③ a normalization adapter reuses the main viewer's thinking/tool collapsing, navigator rail, in-conversation search and MD export (tool calls/results now included in MD export); ④ dual read backends — File System Access API with lazy loading in secure contexts, automatic fallback to a folder picker on `file://`; ⑤ an independent mode alongside Claude.ai exports, switchable from the sidebar without clearing either. Strictly read-only; local files are never modified.

**v5.5** — **Markdown export fixes + stats charts polish.** ① Export filenames now start with the conversation's creation time (e.g. `2026-05-26_1430_Title.md`) for natural archive sorting; ② Normalized heading hierarchy — message headers are now h2 and headings inside Claude's replies are demoted, so the document outline is no longer scrambled; ③ Attachment code fences grow dynamically so content containing triple backticks no longer breaks the formatting, and truncation is now labelled; ④ The document header gains created/updated time and message-count metadata; ⑤ On the stats page, the monthly bar chart no longer stretches (capped bar width, shrink-only scaling, minimum bar height, hover tooltips), and the activity heatmap gets bigger cells plus month/weekday labels.

**v5.4** — **Mobile support.** On phones the app switches to a single-column master-detail layout: the conversation list is full-width, and opening a conversation / stats / project / memory shows the detail full-width and readable, with a back button to return to the list. Fixes the previous issue where the right detail pane was squeezed into an unreadable sliver on mobile. Desktop's two-column layout is unchanged.

**v5.3** — Three features: ① **Personal memory** — the global personal memory in the export's `memories.json` now shows directly in the "Memory" tab (previously ignored); ② **Tool-call rendering** — `tool_use`/`tool_result` (web search, code analysis, MCP, …) render as collapsible blocks, fixing missing content in tool-using conversations; ③ **Conversation navigator** — a right-edge rail keyed by your questions, hover to expand, click to jump (ChatGPT-style).

**v5.2** — **Dropped CDN, all dependencies inlined.** marked.js, JSZip, KaTeX and its fonts are bundled into the single file: zero external requests on load, fully offline, and it fixes the slow/failed CDN loads some networks experienced. The project is now licensed under **GPL-3.0**, with author attribution and a copyright notice added to the cover and the running UI.

**v5.1** — Added **one-click copy** (message / thinking / attachment) and **spacing improvements** (no overlapping messages, full thinking display), keeping v5.0's occurrence-level search and local persistence.

**v5.0** — Stable consolidation release. On top of all v4 features, includes LaTeX rendering, hybrid rendering, occurrence-level search, and friendly notices for unsupported blocks, as a major milestone.

Core capabilities:
- Viewing: ZIP/JSON/MD import, conversations/projects/memory/account, hybrid rendering, thinking, attachments, code copy, LaTeX
- Search: in-conversation occurrence-level search + result sidebar + global search
- Statistics: overview cards, monthly bar chart, daily activity heatmap (click to filter), message ranking
- Management: favorites, tags, dark mode, IndexedDB persistence
- Export: single Markdown/PDF (with formulas), batch ZIP of all conversations

> Evolution: v1 conversation viewing & virtual scroll → v2 ZIP import & multi-type data → v3 global search & statistics → v4 search sidebar, heatmap, local persistence, LaTeX, hybrid rendering → v5 stable consolidation → v5.1 one-click copy & spacing → v5.2 drop CDN, inline dependencies → v5.3 personal memory, tool calls, conversation navigator → v5.4 mobile support → v5.5 MD export fixes & stats charts polish → v5.6 Claude Code local sessions → v5.7 empty-message placeholders & data health check.

---

## 🗺️ Roadmap

Curious about where the project is headed? See the [**Roadmap**](docs/ROADMAP.md), and feel free to share ideas in [Issues](https://github.com/crownleo/ClaudeViewer/issues).

---

## ⭐ Star

If this tool helps you, a Star would mean a lot ⭐

[![GitHub stars](https://img.shields.io/github/stars/crownleo/ClaudeViewer?style=for-the-badge&logo=github&label=Star&color=f5c518)](https://github.com/crownleo/ClaudeViewer/stargazers)

---

## 📄 License & Attribution

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

This project is open source under the [GNU GPL-3.0](LICENSE). You are free to use, study, modify, and redistribute it, but **you must keep the copyright notice and author attribution**, and derivative works must also be licensed under GPL-3.0.

- Author: **crownleo**　·　Xiaohongshu: **kingguan4**
- GitHub: <https://github.com/crownleo/> (reach out via [Issues](https://github.com/crownleo/ClaudeViewer/issues))

© 2026 crownleo · Released under GPL-3.0

---

*Claude Data Viewer v5.5 · Your data, under your control*
