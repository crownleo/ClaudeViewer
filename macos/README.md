# ClaudeViewer 的可选 Mac 伴侣

这份 Mac 伴侣使用 crownleo/ClaudeViewer 发布的 v6.0 网页核心。仓库根目录的 `claude_viewer.html` 保持上游原样，仍可直接在浏览器中打开。Mac 构建只在生成的 App 中接入本机档案存储，复用上游的 ZIP 解析、消息显示、搜索和阅读导出功能。Mac 代码目前是独立的本地贡献方案，尚未被上游接收；它不承诺 Windows 支持。

## 一份档案就是一次导出

新版导出请把同一账号、同一次导出的 manifest JSON 和所有分类、分片 ZIP 放在同一个文件夹中，通过「添加导出文件夹」选择它。一次选择多个导出文件夹，会分别建立独立档案。旧版完整 ZIP 可以通过「添加旧版完整 ZIP」导入；选择多个旧 ZIP 时，每份分别建档。分类 ZIP 请通过完整导出文件夹导入，以免把不同账号的同名分片当成同一套。

档案之间不合并聊天，收藏和标签也分别保存。同一账号不同日期的备份可以并存。程序会检查清单缺片、重复文件与可辨识的账号冲突，但这不是自动账号识别系统；请始终按账号和导出日期组织源文件夹。没有 manifest 时，也无法确认导出中本来应该有多少个类别。

打开前先读取并校验整套文件，成功后才切换当前档案。缺失分片、损坏 ZIP 或可检测的混套会报错。验证失败不会删除原始文件；已复制进资料库的文件仍可以通过 Finder 取出或整理。旧版单 ZIP 档案记录继续可读，已有档案 ID、收藏和标签保持对应。

## 原件、资料目录和 App 各自独立

资料目录是 `~/Library/Application Support/ClaudeViewer/Archives`。通过 App 导入是复制，源文件不移动、不改写。新档案使用一个 UUID 子目录，`originals` 中保存原文件名、相对路径和原始字节，旁边的 `record.json` 保存名称、文件校验信息及收藏、标签。原件不放进 `.app` 安装包。

也可以直接把一份完整导出文件夹放到 `Archives` 顶层，再使用「刷新档案」。每个顶层导出文件夹各自识别，程序不会递归把整个资料库并成一个档案。手动放入的目录和旧版顶层 ZIP 留在原处，关联记录单独保存。不要手动修改程序管理的 UUID 目录内部结构。

「取出整套原件」把这一份档案的所有原文件复制到一个新的目录，保留文件名、相对路径和字节；也可以取出单个文件。取出不会删除档案，也不覆盖目的地已有文件。阅读界面的 Markdown、PDF 导出生成阅读副本，与原件备份是两种用途。

如果还要备份收藏和标签，请退出 App 后复制整个 `Archives` 目录。恢复时同样先退出，并保留现有资料的另一份备份，再恢复目录。普通删除 `ClaudeViewer.app` 不会删除资料目录；移除某份档案则会把其原件和整理记录一起送到 macOS 废纸篓。手动放入的资料目录位于 App 资料库内，也属于这个移除范围。

## 自己构建 App

构建需要 macOS 12 或更新版本、Python 3.9 或更新版本和 Apple 命令行开发工具。使用系统 AppKit、WebKit、CryptoKit，不安装 npm 包或第三方 Swift、Python 依赖。

从仓库根目录执行 `python3 macos/build.py`，生成 `_release/ClaudeViewer.app`。默认架构跟随构建所用的 Mac；Apple Silicon 可以显式使用 `--arch arm64`，Intel 可以使用 `--arch x86_64`。脚本不会覆盖已有 App，再次构建请指定新的 `--output` 路径。

例如，`python3 macos/build.py --arch arm64 --output _release/ClaudeViewer-arm64.app` 会生成一个可双击启动的 App。把它复制到「应用程序」后，也可以放进 Dock。首次使用通过「添加导出文件夹」加入档案，之后打开 App 会恢复上次选择。

`--bundle-id` 可以指定应用标识；升级现有安装时保持原标识，才能保留 WebKit 中的界面偏好和上次打开记录。档案原件的位置独立于此标识。构建产物为本地临时签名，不包含 Apple 开发者证书签名或公证；不需要修改 Gatekeeper、SIP 或其他系统设置。

构建脚本固定校验已经适配的 v6.0 源文件，并从其 `APP_VERSION` 生成 App 版本号。更新上游后，需要先核对适配接口、重新验证，再更新兼容性校验值。生成页面将上游 CSP 替换为唯一一条使用脚本 nonce 的规则，仅允许读取本机 `claude-archive:` 资源，不允许远程请求。

## 开发验证与发布内容

`python3 macos/tests/run.py` 验证原生文件存储、旧记录兼容和构建边界。`node --test macos/tests/adapter.test.cjs` 使用合成数据验证整套导出、隔离和错误处理。`python3 macos/tests/run_webview.py` 使用真实 WebKit 和临时资料库验证本机桥接。测试不需要私人聊天记录，也不写入实际用户资料库。

提交或提供给开发者的是源码、适配脚本、构建说明和合成测试；给普通用户的是构建好的 App。App 包含其对应的 GPL-3.0 源码和许可证，但不包含用户档案、缓存或测试资料。发布前应同时准备对应源码，保留上游作者和贡献者署名。

## English

This optional Mac companion targets the released crownleo/ClaudeViewer v6.0. The repository's standalone HTML remains identical to upstream. Only the generated App receives a native storage adapter; ZIP parsing, rendering, search, and reading exports reuse the upstream implementation. The Mac companion has not been accepted upstream and does not promise Windows support.

An archive represents one complete export. Put one account's manifest and all ZIP parts from one export in one directory, then add that directory. Selecting multiple export directories creates independent archives. Legacy complete ZIPs remain supported as separate archives. Category ZIPs should be imported through their export directory. Detectable account conflicts and incomplete manifests are rejected, but directory grouping is still the user's responsibility.

Original files are copied into `~/Library/Application Support/ClaudeViewer/Archives`, separately from the App. Managed archives store originals and a JSON sidecar in separate locations; existing legacy records retain their IDs and organization state. Export directories placed directly at the library root can also be discovered without moving their originals. Retrieving an archive copies its original files into a fresh directory, preserving names, relative paths, and bytes. To retain favorites and tags as well, quit the App and back up the entire library directory.

Build on macOS 12 or newer with Python 3.9 or newer and Apple's Command Line Tools using `python3 macos/build.py`. No third-party package installation is required. Use `--arch arm64` or `--arch x86_64` and a fresh `--output` path as needed. Retain your bundle ID across upgrades. The build is locally ad-hoc signed, not notarized, and never requires changes to unrelated system settings.

The build pins its verified upstream source and derives the App version from `APP_VERSION`. Revalidate the adapter before changing that pin. The generated App has one nonce-based CSP allowing only its local archive scheme. Run the native, Node, and real WebKit tests described above with synthetic data before publishing. Developer contributions contain source and tests; user releases contain the App and matching GPL source, never personal archives.
