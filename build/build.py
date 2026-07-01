#!/usr/bin/env python3
"""把 CDN 库本地内联进 claude_viewer.html —— 离线可用、零外部请求。

只有在**新增/升级依赖库**时才需要跑这个脚本；日常改 app 代码不用跑。
用法：python3 build/build.py

它做的事：
1. 从 cdnjs 下载 JSZip / marked / KaTeX(JS+CSS) / auto-render（缓存到 build/vendor/）
2. 解析 KaTeX CSS 里的 woff2 字体，逐个下载并转成 base64 内嵌进 CSS
3. 把这些内容注入 claude_viewer.html 的 <!-- vendor:start --> ... <!-- vendor:end --> 区块
   （首次运行会替换掉原来的 4 个 cdnjs <script>/<link> 标签）
"""
import os, re, base64, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VENDOR = os.path.join(HERE, 'vendor')
FONTS = os.path.join(VENDOR, 'fonts')
HTML = os.path.join(ROOT, 'claude_viewer.html')
os.makedirs(FONTS, exist_ok=True)

CDN = 'https://cdnjs.cloudflare.com/ajax/libs'
LIBS = {
    'jszip':       f'{CDN}/jszip/3.10.1/jszip.min.js',
    'marked':      f'{CDN}/marked/9.1.6/marked.min.js',
    'katex-css':   f'{CDN}/KaTeX/0.16.9/katex.min.css',
    'katex-js':    f'{CDN}/KaTeX/0.16.9/katex.min.js',
    'auto-render': f'{CDN}/KaTeX/0.16.9/contrib/auto-render.min.js',
}
FONT_BASE = f'{CDN}/KaTeX/0.16.9/fonts'


def fetch(url):
    print('  ↓', url)
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0 (build script)'})
    return urllib.request.urlopen(req, timeout=90).read()


def cached(fname, url, subdir=''):
    path = os.path.join(VENDOR, subdir, fname)
    if os.path.exists(path):
        return open(path, 'rb').read()
    data = fetch(url)
    open(path, 'wb').write(data)
    return data


def safe_js(src):
    """避免 HTML 解析器在库里的字符串遇到 </script> 提前闭合。"""
    return src.replace('</script>', '<\\/script>')


print('[1/3] 下载库文件…')
raw = {k: cached(url.split('/')[-1], url) for k, url in LIBS.items()}

print('[2/3] 内联 KaTeX 字体（woff2 → base64）…')
css = raw['katex-css'].decode('utf-8')

def inline_font(m):
    fname = m.group(1)  # e.g. KaTeX_Main-Regular.woff2
    data = cached(fname, f'{FONT_BASE}/{fname}', subdir='fonts')
    b64 = base64.b64encode(data).decode('ascii')
    return f'url(data:font/woff2;base64,{b64}) format("woff2")'

# 只保留 woff2（现代浏览器全支持），丢弃同一 @font-face 里的 woff / ttf 回退
css = re.sub(
    r'url\(fonts/([\w.-]+\.woff2)\) format\("woff2"\)'
    r'(?:,url\(fonts/[\w.-]+\.woff\) format\("woff"\))?'
    r'(?:,url\(fonts/[\w.-]+\.ttf\) format\("truetype"\))?',
    inline_font, css)

print('[3/3] 注入 claude_viewer.html…')
block = '\n'.join([
    '<!-- vendor:start — 本地内联依赖，零 CDN、离线可用（由 build/build.py 生成，勿手改此区块）-->',
    f'<script>/* JSZip 3.10.1 */{safe_js(raw["jszip"].decode("utf-8"))}</script>',
    f'<script>/* marked 9.1.6 */{safe_js(raw["marked"].decode("utf-8"))}</script>',
    f'<style id="katex-css">/* KaTeX 0.16.9 */{css}</style>',
    f'<script>/* KaTeX 0.16.9 */{safe_js(raw["katex-js"].decode("utf-8"))}</script>',
    f'<script>/* KaTeX auto-render 0.16.9 */{safe_js(raw["auto-render"].decode("utf-8"))}</script>',
    '<!-- vendor:end -->',
])

html = open(HTML, encoding='utf-8').read()
if '<!-- vendor:start' in html:
    html = re.sub(r'<!-- vendor:start.*?<!-- vendor:end -->', lambda _: block, html, flags=re.S)
else:
    pat = re.compile(
        r'<script src="https://cdnjs[^"]*jszip[^"]*"></script>\s*'
        r'<script src="https://cdnjs[^"]*marked[^"]*"></script>\s*'
        r'<link rel="stylesheet" href="https://cdnjs[^"]*katex\.min\.css">\s*'
        r'<script src="https://cdnjs[^"]*katex\.min\.js"></script>', re.I)
    html, n = pat.subn(lambda _: block, html, count=1)
    if n == 0:
        raise SystemExit('❌ 没找到可替换的 CDN 标签或 vendor 区块，请检查 claude_viewer.html')
open(HTML, 'w', encoding='utf-8').write(html)
print(f'✅ 完成，claude_viewer.html 现为 {os.path.getsize(HTML)/1024:.0f} KB')
