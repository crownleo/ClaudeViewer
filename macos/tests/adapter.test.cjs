// Uses the JSZip already embedded in upstream HTML; no npm dependency or private data.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {test}=require('node:test');
const root=path.resolve(__dirname,'../..');
const html=fs.readFileSync(path.join(root,'claude_viewer.html'),'utf8');
const adapter=fs.readFileSync(path.join(root,'macos/archive-adapter.js'),'utf8');
const scripts=[...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(m=>m[1]);
const zipScript=scripts.find(s=>s.includes('JSZip - A Javascript class'))||scripts.find(s=>s.includes('Corrupted zip : CRC32 mismatch'));
assert.ok(zipScript,'Bundled upstream JSZip must be available');
const zipContext={module:{exports:{}},exports:{},setTimeout,clearTimeout,setImmediate,Uint8Array,Uint16Array,Uint32Array,ArrayBuffer,Buffer,Promise};
vm.runInNewContext(zipScript,zipContext);
const Zip=zipContext.module.exports;
assert.equal(typeof Zip.loadAsync,'function');
function jsonFile(name,value){return{name,blob:new Blob([JSON.stringify(value)],{type:'application/json'})};}
async function zipFile(name,objects){const zip=new Zip();for(const [file,data] of Object.entries(objects))zip.file(file,typeof data==='string'?data:JSON.stringify(data));return{name,blob:new Blob([await zip.generateAsync({type:'uint8array',compression:'STORE'})])};}
function context(){
  const elements=new Map();
  const element=()=>({textContent:'',innerHTML:'',value:'',style:{},classList:{add(){},remove(){},contains(){return false},toggle(){}},addEventListener(){},setAttribute(){},appendChild(){},querySelector(){return null},querySelectorAll(){return []}});
  const records=new Map(),payloads=new Map(),writes=[],warnings=[],modes=[];const values=new Map();
  const c={console,Blob,Uint8Array,ArrayBuffer,Promise,Set,Map,JSON,setTimeout,clearTimeout,fetch:async url=>{const b=payloads.get(url);return{ok:!!b,blob:async()=>b};},
    window:{webkit:{messageHandlers:{archives:{postMessage:async message=>{
      if(message.command==='get')return{ok:true,result:records.get(message.id)};
      if(message.command==='list')return{ok:true,result:[...records.values()]};
      if(message.command==='warnings')return{ok:true,result:warnings};
      if(message.command==='mode'){modes.push(message.temporary);return{ok:true,result:true};}
      if(message.command==='metadata'){writes.push(message);const rec=records.get(message.id);rec.metadata=message.metadata;return{ok:true,result:rec};}
      throw Error('Unexpected command '+message.command);
    }}}},addEventListener(){}},
    document:{addEventListener(){},createElement:element},
    localStorage:{getItem:k=>values.get(k)||null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)},
    $:id=>{if(!elements.has(id))elements.set(id,element());return elements.get(id)},
    showLoad(){},hideLoad(){},finalizeData(){},arcHide(){},arcShow(){},arcSetStatus(){},cvUpdateImportLabels(){},
    arcProbe(){},annSave(){},arcOpen(){},arcRestore(){},arcExportSet(){},arcExportOne(){},arcRenderStorage(){},arcRender(){},arcAdoptPending(){},
    openExportDir(){},showSavePrompt(){},checkStartupCache(){},arcRun:fn=>fn(),arcLeave(){},updateCacheBar(){},formatBytes:String,
    baseName:p=>String(p||'').split('/').pop(),
    resetState(){c.appData={convs:[],projects:[],memories:null,account:null,globalMemory:null,reflections:null,loginHistory:null};},resetCC(){},
    annLoad(){c.favorites=new Set(c.activeArc.metadata&&c.activeArc.metadata.favorites||[]);c.tags=structuredClone(c.activeArc.metadata&&c.activeArc.metadata.tags||{});},
    activeArc:null,appData:{convs:[],projects:[],memories:null,account:null,globalMemory:null,reflections:null,loginHistory:null},favorites:new Set(),tags:{},appMode:'export',pendingImport:null,isCached:false,arcRecords:[],loadingMsg:element(),arcPanel:element(),dropZone:element(),alert(){},
    JSZip:{loadAsync:async(input,options)=>Zip.loadAsync(input instanceof Blob?await input.arrayBuffer():input,options)}};
  vm.createContext(c);
  const start=html.indexOf('async function parseZip(file){');
  const end=html.indexOf('function finalizeData(fromCache){',start);
  assert.ok(start>0&&end>start);
  vm.runInContext(html.slice(start,end),c);
  vm.runInContext(adapter,c);
  function register(id,files,metadata={favorites:[],tags:{}}){const rec={id,name:id,metadata,files:files.map((f,i)=>{const url='claude-archive://archive/'+id+'/'+i;payloads.set(url,f.blob);return{name:f.name,size:f.blob.size,url};})};records.set(id,rec);return rec;}
  return{c,records,writes,register,payloads,values,warnings,modes};
}
async function fullExport(account='account-a'){
  const files=[
    await zipFile('conversations-000.zip',{'conversations.json':[{uuid:'same-id',name:'Part zero',chat_messages:[]}]}),
    await zipFile('conversations-001.zip',{'conversations.json':[{uuid:'part-one',name:'Part one',chat_messages:[]}]}),
    await zipFile('projects-000.zip',{'projects/0123-abcd.json':{uuid:'0123-abcd',name:'Project',prompt_template:'Prompt'}}),
    await zipFile('memories-000.zip',{['memories/'+account+'.json']:{account_uuid:account,conversations_memory:'Remember this',project_memories:{}}}),
    await zipFile('feedback-000.zip',{['reflections/'+account+'.json']:{account_uuid:account,reflections:[]}}),
    await zipFile('light_metadata-000.zip',{'users.json':[{uuid:account,email_address:account+'@example.invalid'}],'login_history.json':{login_events:[{account_uuid:account}]}}),
  ];
  return[jsonFile('manifest-example.json',{data_files:files.map(f=>({filename:f.name})),created_at:'2026-09-08T00:00:00Z'}),...files];
}
test('complete manifest and two conversation parts use the upstream parser as one isolated export',async()=>{
  const {c,register}=context();const files=await fullExport();const rec=register('a',files);
  await c.arcOpen(rec);
  assert.equal(c.appData.convs.length,2);assert.equal(c.appData.projects.length,1);
  assert.equal(c.appData.account.uuid,'account-a');assert.equal(c.appData.memories.conversations_memory,'Remember this');
  assert.equal(c.appData.reflections.reflections.length,0);assert.equal(c.appData.loginHistory.length,1);
  assert.equal(c.activeArc.files.length,7);assert.ok(c.activeArc.files.every(f=>!f.blob),'Active records retain native source references, not parsed Blob copies');
});
test('legacy ZIP still loads unchanged',async()=>{
  const {c,register}=context();const file=await zipFile('legacy.zip',{'conversations.json':[],'users.json':[{uuid:'legacy'}]});
  await c.arcOpen(register('old',[file]));assert.equal(c.appData.account.uuid,'legacy');
});
test('switching archives isolates conversations, account, favorites and tags; writes use the correct archive',async()=>{
  const {c,register,writes}=context();
  const a=register('a',await fullExport('account-a'),{favorites:['same-id'],tags:{'same-id':['A']}});
  const b=register('b',[await zipFile('b.zip',{'conversations.json':[{uuid:'same-id',name:'B',chat_messages:[]}],'users.json':[{uuid:'account-b'}]})],{favorites:[],tags:{}});
  await c.arcOpen(a);assert.deepEqual([...c.favorites],['same-id']);c.tags['same-id']=['updated'];c.annSave();
  await c.arcOpen(b);assert.equal(c.appData.convs.length,1);assert.equal(c.appData.account.uuid,'account-b');assert.equal(c.favorites.size,0);assert.deepEqual(Object.keys(c.tags),[]);
  assert.equal(writes.length,1);assert.equal(writes[0].id,'a');assert.equal(writes[0].metadata.tags['same-id'][0],'updated');
  await c.arcOpen(a);assert.equal(c.tags['same-id'][0],'updated');
});
test('a missing manifest part refuses opening and retains the previous data and active ID',async()=>{
  const {c,register,values}=context();const good=register('good',await fullExport());await c.arcOpen(good);
  const previous=c.appData;const broken=register('missing',(await fullExport()).filter(f=>f.name!=='conversations-001.zip'));
  await assert.rejects(c.arcOpen(broken),/缺少清单中的文件/);
  assert.equal(c.appData,previous);assert.equal(c.activeArc.id,'good');assert.equal(values.get('cv_active_arc'),'good');
});
test('multiple manifests and mixed account identities are rejected',async()=>{
  const {c}=context();const files=await fullExport();
  await assert.rejects(c.cvValidateArchive([...files,jsonFile('manifest-second.json',{data_files:[{filename:'conversations-000.zip'}]})]),/多份 manifest/);
  const mixed=[...files];mixed[mixed.length-1]=await zipFile('light_metadata-000.zip',{'users.json':[{uuid:'another-account'}]});
  await assert.rejects(c.cvValidateArchive(mixed),/不同账号/);
});
test('invalid JSON and corrupted ZIP are rejected without replacing the current archive',async()=>{
  const {c,register}=context();await c.arcOpen(register('good',await fullExport()));const old=c.appData;
  await assert.rejects(c.arcOpen(register('badjson',[await zipFile('legacy.zip',{'conversations.json':'{invalid'})])),/有效 JSON/);
  await assert.rejects(c.arcOpen(register('badzip',[{name:'broken.zip',blob:new Blob(['not a zip'])}])),/ZIP 损坏/);
  const valid=await zipFile('crc.zip',{'conversations.json':[{uuid:'crc-message',chat_messages:[]}]});
  const corrupted=Buffer.from(await valid.blob.arrayBuffer());
  const payload=corrupted.indexOf(Buffer.from('crc-message'));assert.ok(payload>0);corrupted[payload]^=1;
  await assert.rejects(c.arcOpen(register('badcrc',[{name:'crc.zip',blob:new Blob([corrupted])}])),/CRC32/);
  await assert.rejects(c.arcOpen(register('badshape',[await zipFile('badshape.zip',{'conversations.json':[{uuid:'bad',chat_messages:[null]}]})])),/消息的格式无效/);
  assert.equal(c.appData,old);assert.equal(c.activeArc.id,'good');
});
test('category ZIPs are checked as a set, without requiring conversations.json in every ZIP',async()=>{
  const {c}=context();const files=(await fullExport()).filter(f=>!c.cvManifestName(f.name));
  await c.cvValidateArchive(files);
  await assert.rejects(c.cvValidateArchive(files.filter(f=>f.name!=='conversations-000.zip')),/分片序号不连续/);
  await assert.rejects(c.cvValidateArchive([await zipFile('one.zip',{'conversations.json':[]}),await zipFile('two.zip',{'conversations.json':[]})]),/多个旧版 ZIP/);
});
test('old active-archive key restores and migrates to upstream v6 key',async()=>{
  const {c,register,values}=context();register('legacy',[await zipFile('legacy.zip',{'conversations.json':[]})]);values.set('cv_active_archive','legacy');
  await c.arcRestore();assert.equal(c.activeArc.id,'legacy');assert.equal(values.get('cv_active_arc'),'legacy');assert.equal(values.has('cv_active_archive'),false);
});

test('unrecognized or incomplete folder warnings are visible as plain text, including when no archive exists',async()=>{
  const {c,warnings}=context();warnings.push('Missing conversations-001.zip in <img src=x onerror=alert(1)>');
  await c.arcRenderStorage();
  assert.match(c.$('arc-storage').textContent,/Missing conversations-001/);
  assert.match(c.$('arc-storage').textContent,/<img src=x onerror=alert\(1\)>/);
  assert.equal(c.$('arc-storage').innerHTML,'');
  let shown=false;c.arcShow=()=>{shown=true;};await c.arcRestore();assert.equal(shown,true);
});

test('temporary import labels synchronize native file-drop capture mode',async()=>{
  const {c,modes}=context();assert.deepEqual(modes,[false]);
  vm.runInContext('cvNativeTemporary=true;cvUpdateImportLabels();',c);
  assert.deepEqual(modes,[false,true]);
  vm.runInContext('cvNativeTemporary=false;cvUpdateImportLabels();',c);
  assert.deepEqual(modes,[false,true,false]);
});
