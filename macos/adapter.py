"""Inject the optional native archive storage adapter into an unchanged upstream HTML."""
from __future__ import annotations

from pathlib import Path


def inject_native_adapter(html: str, adapter_source: str | None = None) -> str:
    """Fail closed when upstream storage seams change; do not patch parser/render/search."""
    substitutions = {
        "const arcAll=()=>arcTx('readonly',st=>st.getAll());":
            "const arcAll=()=>cvNativeCall('list');",
        "const arcGet=id=>arcTx('readonly',st=>st.get(id));":
            "const arcGet=id=>cvNativeCall('get',{id});",
        "const arcPut=rec=>arcTx('readwrite',st=>st.put(rec));":
            "const arcPut=rec=>cvSaveMetadata(rec);",
        "const arcDel=id=>arcTx('readwrite',st=>st.delete(id));":
            "const arcDel=id=>cvNativeCall('remove',{id});",
    }
    for before, after in substitutions.items():
        if html.count(before) != 1:
            raise ValueError('Upstream archive storage seam changed; inspect adapter compatibility: ' + before)
        html = html.replace(before, after, 1)
    if adapter_source is None:
        adapter_source = Path(__file__).with_name('archive-adapter.js').read_text(encoding='utf-8')
    closing = '\n})();\n</script>\n</body>'
    if html.count(closing) != 1:
        raise ValueError('Upstream application IIFE changed; cannot safely inject native adapter')
    return html.replace(closing, '\n// Optional Mac native storage adapter.\n' + adapter_source + closing, 1)
