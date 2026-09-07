# ZIP 档案库与可选 macOS App

[English](#english) · [返回 README](../README.md)

## 档案库保存什么

档案库把导入的 ZIP 原件作为数据源。导入时保存 ZIP 的原始字节；打开档案时，仍由同一套 ZIP 解析与聊天显示逻辑读取内容。解析并不要求用户手动解压，也不会改写保存的 ZIP。

每份不同内容的 ZIP 是一份独立档案；同一文件即使改名后重复导入，也会按完整文件内容识别并复用已有档案。可以给档案起一个容易识别的名字，然后在档案库中选择它。查看器一次打开一份档案，对话、账户信息、项目、记忆、收藏和标签随之切换。搜索和统计也仅针对当前档案。不同档案可以包含相同的对话 UUID，收藏和标签不会因此互相串用。重命名只更改档案的显示名称，不会改动 ZIP 内的内容。

档案库不跨档案合并对话，也不提供云同步。同一账号多次导出的 ZIP 可以分别保留，供用户选择查看。如果一次导出被分成多个 `batch-*.zip`，目前可在原有临时查看模式中一起导入这些分片；档案库仍将每个 ZIP 分别保存和查看。

## 导入、切换与取出

在上传页点击「打开 ZIP 档案库」，或在侧栏点击「档案库」，再用「添加 ZIP 档案」添加一份或多份档案。导入是复制，不会移动或删除你选择的源文件。点击档案的「打开」即可阅读，下一次打开查看器时会恢复上次选择的档案。文件损坏或内容无法解析时会提示错误，当前已打开的档案仍保留。收藏和标签保存在 ZIP 之外，随对应档案保存。

「取出原始 ZIP」提供的文件与导入时的 ZIP 逐字节一致。已有的「↓ MD」「↓ PDF」和「↓ 全部导出」仍然用于生成阅读或分享用的副本；其中「↓ 全部导出」生成的是多个 Markdown 文件组成的新 ZIP，不能替代原始 Claude 导出包。

如果 Safari 已经自动解压了下载文件，可以把解压后的文件夹重新压缩，再导入。这样能够保留文件夹中的数据，但新压缩包不是官方 ZIP 的逐字节副本。需要原封不动保留官方压缩包时，请保存并导入实际下载的 ZIP。

## 网页版与现有缓存

网页版仍然是单文件 HTML，不需要构建或安装。档案库使用独立的 IndexedDB 保存 ZIP 原件和档案状态；只有主动使用档案导入，才会把文件保存到档案库。浏览器清除网站数据、存储回收、无痕会话结束或更换浏览器可能使这些档案不可用。重要档案应保留自己的 ZIP 副本，不要只依赖浏览器存储。

原有的拖放 ZIP、JSON 或 MD 文件进行临时查看的流程仍然可用。临时查看可以继续合并导入多个文件，并选择是否缓存解析结果。档案库与这份旧缓存分开保存；加入档案功能不会把已有缓存自动变成 ZIP，也不会要求先删除旧缓存。

旧缓存只有解析后的数据，无法重新生成与当初下载文件逐字节相同的 ZIP。若希望把旧数据改为档案管理，请重新选择手头保存的原始 ZIP。也可以通过档案库中的「临时查看 / 旧缓存」继续阅读旧缓存。

网页版取出原始 ZIP 不包含后来添加的收藏和标签。从网页版移除档案会删除浏览器里的该份档案及整理状态，因此移除前应另存需要保留的 ZIP。它也没有直接读写 Finder 目录的能力；如果需要可直接复制整个文件夹的资料库，可以选择下述 macOS App。

<a id="macos-app"></a>
## 可选 macOS App

macOS App 是同一份 `claude_viewer.html` 的本机外壳，提供原生文件选择、ZIP 保存与取出、打开资料目录等功能。网页版本不依赖它。App 要求 macOS 12 或更新版本。构建需要 Mac 上的 Python 3 和 Apple 的命令行开发工具，不需要 npm、第三方 Python 包或第三方 Swift 依赖。App 使用系统自带的 AppKit 和 WebKit。

在仓库根目录运行：

```sh
python3 macos/build.py
```

默认生成 `_release/ClaudeViewer.app`，架构与构建所用 Mac 一致。双击生成的 App 即可运行；也可以在 Finder 中将它复制到「应用程序」文件夹。将 ZIP 拖进 App 窗口即可加入档案库；也可以用「文件 → 打开导出文件…」或 `⌘O` 导入，`⌘R` 刷新档案，或在 Finder 中对 ZIP 选择「打开方式 → ClaudeViewer」。

脚本不会覆盖已有 App。再次构建时，可以用 `--output` 指定新的路径。`--arch arm64` 面向 Apple Silicon，`--arch x86_64` 面向 Intel；一次构建生成其中一种架构。例如：

```sh
python3 macos/build.py --arch arm64 --output _release/ClaudeViewer-arm64.app
```

默认 App 标识符为 `cn.crownleo.ClaudeViewer`，可用 `--bundle-id` 修改。升级时保持这个标识符不变，可继续使用原有 WebKit 界面偏好。档案目录始终使用下述固定位置，不随标识符改变。

构建和运行只处理项目产物与 App 自己的数据目录，不要求关闭 Gatekeeper、SIP 或更改无关系统设置。首次准备开发工具时，macOS 可能提示安装 Apple 的命令行开发工具。脚本会为本机构建执行临时签名（ad-hoc codesign）并验证签名。它不是开发者证书签名，也不提供 Apple 公证。

### 原件存放位置

App 的档案库位于：

```text
~/Library/Application Support/ClaudeViewer/Archives
```

通过 App 导入的每份档案位于独立的 UUID 子目录中，保存原文件名的 ZIP 和 `record.json`。记录文件保存档案名称及收藏、标签等整理信息。使用「打开档案文件夹」可以在 Finder 中查看这些文件，也可以直接从中复制 ZIP。

App 导入的 ZIP 会复制到这个目录。也可以把 ZIP 放到 `Archives` 目录顶层，再在档案库中刷新以发现它们。这些 ZIP 保持在顶层，关联的 `record.json` 另存于 UUID 子目录。正常使用时建议通过 App 导入，避免自行修改 UUID 子目录中的文件名或记录文件。

### 备份、移除与卸载

只需要原始聊天导出时，使用「取出原始 ZIP」，或从档案目录中复制对应 ZIP。若要同时保留所有档案、显示名称、收藏和标签，请先退出 App，再复制整个 `Archives` 文件夹。这样可以保留原件与档案记录之间的对应关系。恢复时同样先退出 App，再把备份放回该位置；替换前应另存现有资料，以免覆盖新档案。

App 中移除档案会将该档案移到 macOS 废纸篓，而不是直接永久删除。需要恢复时，可在 Finder 的废纸篓中放回相应档案，再刷新档案库。对于手动放在顶层的 ZIP，恢复时应同时放回 ZIP 和对应的 UUID 记录目录，以恢复收藏与标签。不要把档案移除与「取出原始 ZIP」混淆：取出只是复制，原档案仍保留在 App 中。

`ClaudeViewer.app` 与资料目录彼此分开。普通删除 `.app` 不会删除 `Application Support/ClaudeViewer/Archives` 中的档案；卸载工具可能另有清理规则。停止使用前，可以先验证取出的 ZIP 或完整资料库备份能正常读取，然后删除 App。无需把个人档案放进 App 安装包中，也无需依赖 App 才能拿回 ZIP。

### 本地运行与源码边界

App 从安装包读取查看器，使用本机接口处理档案和文件导出。它不提供网络服务，不把导入内容上传到服务器，并限制内嵌页面发起远程请求。构建产物不包含任何用户 ZIP 或浏览器缓存。

档案管理负责原件与档案状态，查看器继续负责 ZIP 解析、消息渲染、搜索和现有导出格式。浏览器存储与 macOS 文件存储通过同一套档案操作连接到界面。这样可以单独使用网页，也可以按需构建 App，而不必维护两套聊天查看器。

### 开发验证

档案库回归检查使用合成数据，覆盖 ZIP 原始字节、重复文件、损坏导入、档案状态隔离、重新打开和旧缓存保留。在具备 Node.js 的开发环境中，可从仓库根目录运行：

```sh
npm install --prefix _local --no-save fake-indexeddb@6.2.4
node --test tests/archive-library.test.cjs
# macOS only / 仅 macOS：
python3 macos/tests/run.py
```

`fake-indexeddb` 只用于开发验证，安装在版本控制忽略的 `_local` 中，不会加入发布的 HTML 或 macOS App。正常使用查看器无需运行这些命令。

---

<a id="english"></a>
# ZIP archives and the optional macOS App

[中文](#zip-档案库与可选-macos-app) · [Back to README](../README.en.md)

## What an archive contains

The archive library uses the imported ZIP as its source of truth. Importing saves the original bytes. Opening an archive feeds that ZIP into the same parser and conversation viewer. Parsing requires no manual extraction and does not modify the stored ZIP.

Each ZIP with different contents is an independent archive with a name you can change. Reimporting an identical file, even under a different filename, reuses the existing archive based on its complete file contents. The viewer opens one archive at a time; conversations, account details, projects, memories, favorites, and tags switch together. Search and statistics apply to the selected archive. Archives may contain the same conversation UUID without sharing favorites or tags. Renaming an archive changes its display name, not the contents of the ZIP.

There is no cross-archive conversation merge or cloud sync. Repeated exports from the same account can be kept as separate archives. If an export consists of multiple `batch-*.zip` shards, the original temporary viewing mode can import them together; the archive library currently stores and opens each ZIP separately.

## Importing and retrieving ZIPs

Choose “Open ZIP archive library” (「打开 ZIP 档案库」) on the upload screen or “Archives” (「档案库」) in the sidebar, then use “Add ZIP archives” (「添加 ZIP 档案」) to add one or more files. Importing copies the file and leaves your source file in place. Choose “Open” (「打开」) on an archive to read it; the viewer restores the last selected archive on reopening. A damaged or unreadable archive shows an error while keeping the currently opened archive available. Favorites and tags are stored alongside the archive information without changing the ZIP.

“Retrieve original ZIP” (「取出原始 ZIP」) returns exactly the imported bytes. The existing Markdown, PDF, and “Export All” actions still create copies for reading or sharing. “Export All” creates a new ZIP containing Markdown files; it is not a backup of the original Claude export package.

If Safari has already extracted a download, you can compress the extracted folder and import that ZIP. This preserves the files in the folder, but the new ZIP is not byte-identical to the official download. To retain the official archive unchanged, save and import the downloaded ZIP itself.

## Browser storage and the existing cache

The browser edition remains a standalone HTML file with no build or installation required. Its archive library saves original ZIPs and archive state in a separate IndexedDB database when you explicitly import into the library. Clearing site data, storage eviction, ending a private-browsing session, or changing browsers may make this data unavailable. Keep separate ZIP backups of important archives.

The original temporary workflow still accepts ZIP, JSON, and MD files, supports importing additional files together, and optionally caches parsed data. The new library is separate from that cache. Adding archives does not automatically convert old cached data into a ZIP or require you to clear it.

A parsed cache cannot recreate the exact bytes of the originally downloaded ZIP. To manage that data as an archive, import the original ZIP you have retained. The old cache remains available through “Temporary view / old cache” (「临时查看 / 旧缓存」) in the archive library.

Retrieving the original ZIP from the browser does not include favorites and tags added later. Removing an archive from the browser deletes its stored archive and organization state, so save any ZIP you want to retain first. The browser edition also cannot directly manage a Finder directory. For a library that can be backed up by copying a folder, use the optional macOS App.

<a id="macos-app-english"></a>
## Optional macOS App

The App wraps the same `claude_viewer.html` with native file selection, archive storage, original-ZIP retrieval, and access to the data folder. It is optional; the browser edition works independently. The App requires macOS 12 or later. Building requires Python 3 and Apple's command-line developer tools on a Mac, with no npm, third-party Python packages, or third-party Swift dependencies. It uses the system AppKit and WebKit frameworks.

From the repository root, run:

```sh
python3 macos/build.py
```

The default output is `_release/ClaudeViewer.app`, built for the current Mac's architecture. Double-click the App to run it, or copy it to Applications in Finder. Dropping ZIPs into the App window adds them to the archive library. You can also use File → Open export file (「文件 → 打开导出文件…」) or `⌘O` to import ZIPs, and `⌘R` to refresh archives. Finder's Open With → ClaudeViewer also opens ZIPs in the App.

The script refuses to overwrite an existing App. Use `--output` to choose a new location when rebuilding. `--arch arm64` targets Apple Silicon and `--arch x86_64` targets Intel; each build produces one architecture. For example:

```sh
python3 macos/build.py --arch arm64 --output _release/ClaudeViewer-arm64.app
```

The default bundle identifier is `cn.crownleo.ClaudeViewer`; `--bundle-id` can change it. Keep the identifier when upgrading to retain WebKit interface preferences. The archive directory always uses the fixed location below, independent of the bundle identifier.

Building and running operate on project output and the App's own data directory. They do not require disabling Gatekeeper or SIP or changing unrelated system settings. macOS may offer to install Apple's command-line developer tools if they are not yet available. The script ad-hoc signs the local App and verifies its signature. This is not developer-certificate signing, and it does not provide Apple notarization.

### Storage location

The App stores its archive library at:

```text
~/Library/Application Support/ClaudeViewer/Archives
```

Each archive imported through the App has a UUID subdirectory containing its ZIP under the original filename and `record.json`. The record stores the archive name and organization state, including favorites and tags. Use “Open archive folder” (「打开档案文件夹」) to browse the folder in Finder and copy ZIPs directly.

Importing through the App copies files into this library. You may also place ZIPs at the top level of `Archives` and refresh the archive library to discover them. These ZIPs remain at the top level, with their associated `record.json` in a UUID subdirectory. App import is the usual workflow; avoid renaming files or editing records inside managed UUID directories by hand.

### Backup, removal, and uninstalling

To keep just the original export, retrieve its original ZIP or copy that ZIP from its archive folder. To keep every archive together with names, favorites, and tags, quit the App and copy the entire `Archives` directory. This preserves the relationship between original files and their records. To restore a backup, quit the App and put the directory back at the same location. Keep a separate copy of any existing library before replacing it to avoid overwriting newer archives.

Removing an archive in the App moves it to the macOS Trash instead of permanently deleting it. To recover it, use Finder to put the archive back, then refresh the library. For a manually placed top-level ZIP, restore both the ZIP and its UUID record directory to retain favorites and tags. Retrieving a ZIP only copies it out; it does not remove the archive from the App.

`ClaudeViewer.app` and its data directory are separate. Ordinary deletion of the `.app` does not delete archives in `Application Support/ClaudeViewer/Archives`; uninstaller utilities may apply their own cleanup rules. Before leaving the App, verify that your retrieved ZIPs or full library backup can be read, then delete the App. Personal archives are not embedded in the application bundle, and retrieving the ZIPs does not depend on continuing to use the App.

### Local operation and architecture

The App loads the bundled viewer and uses local interfaces for archives and file export. It runs no network server, uploads no imported data, and restricts remote requests from its embedded page. Build output includes no personal archives or browser caches.

Archive management handles original files and archive state; the existing viewer continues to parse ZIPs, render messages, search, and produce its existing export formats. Browser storage and macOS file storage connect to the same archive operations. The result supports the standalone HTML file and an optional App without maintaining two conversation viewers.

### Developer checks

Archive regression checks use synthetic data to cover original ZIP bytes, duplicate files, corrupt imports, archive state isolation, reopening, and legacy cache preservation. With Node.js 20 or newer available, run from the repository root:

```sh
npm install --prefix _local --no-save fake-indexeddb@6.2.4
node --test tests/archive-library.test.cjs
# macOS only / 仅 macOS：
python3 macos/tests/run.py
```

`fake-indexeddb` is a development-only dependency installed under the ignored `_local` directory. It is not included in the distributed HTML or macOS App, and normal viewer use requires neither command.
