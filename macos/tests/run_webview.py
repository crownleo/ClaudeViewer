#!/usr/bin/env python3
"""Real macOS WebKit integration with temporary, wholly synthetic export files."""
from pathlib import Path
import importlib.util
import json
import platform
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]

# This code is injected only into the temporary test HTML, inside its application
# IIFE. No runtime debug endpoint or test hooks are shipped in the Mac App.
BROWSER_TESTS = r"""
const cvTestPause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let cvTestChecks=Number(localStorage.getItem('test_check_count')||0);
function cvTestAssert(value,message){if(!value)throw new Error(message);cvTestChecks++;}
async function cvTestUntil(predicate,message){for(let i=0;i<120;i++){if(predicate())return;await cvTestPause(40);}throw new Error(message);}
async function cvTestDocument(label,email,count){
  cvTestAssert(appData.convs.length===count,'Wrong conversation count for '+label);
  cvTestAssert(filteredConvs.length===count,'Conversation sidebar count mismatch');
  cvTestAssert(appData.account.email_address===email,'Wrong active account');
  setTab('account');
  cvTestAssert(staticPanel.textContent.includes(email),'Account not rendered in real DOM');
  setTab('convs');openConv('shared-conversation');
  await cvTestUntil(()=>document.body.textContent.includes('Synthetic message '+label),'Chat message not rendered');
  cvTestAssert(detailTitle.textContent==='Synthetic '+label,'Wrong conversation title in DOM');
}
(async()=>{
  await cvTestPause(150);
  const records=await arcAll();
  const a=records.find(r=>r.name==='legacy-a'),b=records.find(r=>r.name==='modern-b'||r.name==='Renamed synthetic B');
  cvTestAssert(!!a&&!!b,'Expected synthetic archive records');
  cvTestAssert(document.querySelector('meta[http-equiv="Content-Security-Policy"]').content.includes('connect-src claude-archive:'),'Native CSP is not active');
  cvTestAssert(!document.querySelector('meta[http-equiv="Content-Security-Policy"]').content.includes("script-src 'unsafe-inline'"),'Unsafe inline script policy');
  if(window.__nativeTestPhase===1){
    await cvTestUntil(()=>activeArc&&activeArc.id===b.id,'Startup did not restore the last archive');
    await cvTestDocument('B','b@example.invalid',2);
    cvTestAssert(tags['shared-conversation'][0]==='B label'&&!favorites.has('shared-conversation'),'Restart lost B annotation isolation');
    cvTestAssert(localStorage.getItem('cv_active_archive')===null,'Legacy active ID was not migrated');
    await arcOpen(a);
    cvTestAssert(favorites.has('shared-conversation')&&tags['shared-conversation'][0]==='A label','Restart lost persisted A annotations');
    await cvTestDocument('A','a@example.invalid',1);
    await arcExportSet(b);
    await cvNativeCall('reveal',{id:b.id});
    window.webkit.messageHandlers.testReport.postMessage({passed:cvTestChecks});return;
  }
  $('arc-temp').click();await cvTestPause(30);
  cvTestAssert(cvNativeTemporary&&$('pick-label').textContent.includes('临时'),'Temporary entry did not switch the UI mode');
  $('reset-btn').click();await cvTestPause(30);
  cvTestAssert(!cvNativeTemporary&&$('pick-label').textContent.includes('旧版 ZIP'),'Reset did not restore persistent import mode');
  await arcOpen(a);await cvTestDocument('A','a@example.invalid',1);
  favorites.add('shared-conversation');tags['shared-conversation']=['A label'];annSave();
  await arcOpen(b);await cvTestDocument('B','b@example.invalid',2);
  cvTestAssert(!favorites.has('shared-conversation')&&!tags['shared-conversation'],'A annotations leaked into B');
  cvTestAssert(appData.projects.length===1&&appData.memories&&appData.reflections&&appData.loginHistory,'Category ZIP data was not parsed');
  tags['shared-conversation']=['B label'];annSave();
  await arcOpen(a);
  cvTestAssert(favorites.has('shared-conversation')&&tags['shared-conversation'][0]==='A label','Switching failed to restore A annotations');
  await arcOpen(b);
  const bad=records.find(r=>r.name==='corrupt');
  let rejected=false;try{await arcOpen(bad);}catch(e){rejected=/ZIP/.test(e.message);}
  cvTestAssert(rejected,'Corrupt ZIP was not rejected');
  cvTestAssert(activeArc.id===b.id&&appData.account.email_address==='b@example.invalid','Corrupt ZIP replaced visible archive');
  rejected=false;try{await cvNativeCall('import',{mode:'missing-fixture'});}catch(e){rejected=e.message.includes('缺少');}
  cvTestAssert(rejected,'Missing manifest part was not rejected by native import');
  cvTestAssert(activeArc.id===b.id&&appData.convs.length===2,'Incomplete import changed active archive');
  cvTestAssert((await arcAll()).length===3,'Failed import left an extra archive');
  await cvNativeCall('remove',{id:bad.id});
  cvTestAssert((await arcAll()).length===2,'Fixture removal bridge did not update archive store');
  const duplicated=await cvNativeCall('import',{mode:'files'});
  cvTestAssert(duplicated.length===1&&duplicated[0].id===a.id,'Original legacy ZIP was not deduplicated');
  await cvNativeCall('rename',{id:b.id,name:'Renamed synthetic B'});
  cvTestAssert((await arcGet(b.id)).name==='Renamed synthetic B','Native rename not persisted');
  // Recreate WKWebView using the same ephemeral WebKit store. This checks the
  // upstream automatic startup path and migration of the previous Mac ID key.
  localStorage.setItem('cv_active_archive',b.id);localStorage.removeItem('cv_active_arc');
  localStorage.setItem('test_check_count',String(cvTestChecks));
  window.webkit.messageHandlers.testReport.postMessage({reload:true});
})().catch(error=>window.webkit.messageHandlers.testReport.postMessage({failure:String(error.stack||error.message||error)}));
"""


def write_zip(path, entries):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, value in entries.items():
            archive.writestr(name, json.dumps(value, ensure_ascii=False))


def conversation(account, key="shared-conversation"):
    return {"uuid": key, "name": f"Synthetic {account}", "account_uuid": f"account-{account.lower()}",
            "created_at": "2026-09-08T00:00:00Z", "updated_at": "2026-09-08T00:00:00Z",
            "chat_messages": [{"uuid": f"message-{account}", "sender": "human", "text": f"Synthetic message {account}",
                               "created_at": "2026-09-08T00:00:00Z", "content": [{"type": "text", "text": f"Synthetic message {account}"}]}]}


def user(account):
    return {"uuid": f"account-{account.lower()}", "full_name": f"Synthetic {account}", "email_address": f"{account.lower()}@example.invalid"}


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This integration test requires macOS and Apple's Command Line Tools.")
    spec = importlib.util.spec_from_file_location("cv_build", ROOT / "macos/build.py")
    build = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(build)
    with tempfile.TemporaryDirectory(prefix="ClaudeViewer-WebKit-") as temporary:
        work = Path(temporary)
        write_zip(work / "legacy-a.zip", {"conversations.json": [conversation("A")], "users.json": [user("A")]})
        modern = work / "modern-b"
        modern.mkdir()
        categories = {
            "conversations-000.zip": {"conversations.json": [conversation("B")]},
            "conversations-001.zip": {"conversations.json": [conversation("B", "second-conversation")]},
            "projects-000.zip": {"projects/12345678-1234-1234-1234-123456789abc.json": {"uuid": "12345678-1234-1234-1234-123456789abc", "name": "Synthetic project", "prompt_template": "Synthetic prompt"}},
            "memories-000.zip": {"memories/account-b.json": {"account_uuid": "account-b", "conversations_memory": "Synthetic memory", "project_memories": {}}},
            "feedback-000.zip": {"reflections/account-b.json": {"account_uuid": "account-b", "reflections": []}},
            "light_metadata-000.zip": {"users.json": [user("B")], "login_history.json": {"login_events": []}},
        }
        for name, contents in categories.items():
            write_zip(modern / name, contents)
        manifest = {"created_at": "2026-09-08T00:00:00Z", "version": "1.0", "data_files": [
            {"filename": name, "category": name.rsplit("-", 1)[0], "part": int(name.rsplit("-", 1)[1].split(".")[0]),
             "export_url": "https://example.invalid/never-fetch"} for name in categories]}
        (modern / "manifest-synthetic.json").write_text(json.dumps(manifest), encoding="utf-8")
        shutil.copytree(modern, work / "missing-b")
        (work / "missing-b/conversations-001.zip").unlink()
        (work / "corrupt.zip").write_bytes(b"PK\x03\x04intentionally incomplete synthetic ZIP")
        original = (ROOT / "claude_viewer.html").read_text(encoding="utf-8")
        closing = "\n})();\n</script>\n</body>"
        if original.count(closing) != 1:
            raise AssertionError("Upstream IIFE changed; inspect test injection point")
        # Inject after the native adapter so all storage overrides are installed.
        bundled = build.bundled_html(original)
        bundled = bundled.replace(closing, "\n// Synthetic WebKit integration test only.\n" + BROWSER_TESTS + closing, 1)
        (work / "viewer.html").write_text(bundled, encoding="utf-8")
        executable = work / "WebViewTests"
        subprocess.run(["xcrun", "swiftc", str(ROOT / "macos/ArchiveStore.swift"), str(ROOT / "macos/tests/WebViewTests.swift"),
                        "-framework", "AppKit", "-framework", "WebKit", "-framework", "CryptoKit", "-o", str(executable)], check=True)
        subprocess.run([str(executable), str(work)], check=True, timeout=65)


if __name__ == "__main__":
    main()
