// The upstream parser/render/search code remains unchanged. This companion layer
// supplies original files from the Mac archive directory and keeps each export isolated.
async function cvNativeCall(command,args={}){
  const reply=await window.webkit.messageHandlers.archives.postMessage({command,...args});
  if(!reply||reply.ok!==true)throw new Error(reply&&reply.error||'Mac 档案操作失败');
  return reply.result;
}
function cvArchiveError(message){return new Error(message+'。请将每个账号、每次导出分别放入一个文件夹后添加。');}
function cvManifestName(name){return /^manifest(?:-.*)?\.json$/i.test(String(name).split('/').pop());}
async function cvZipInput(blob){return typeof blob.arrayBuffer==='function'?await blob.arrayBuffer():blob;}

// Validate the complete export before handing any bytes to the upstream parser.
// No export_url is fetched: a manifest is only an inventory of local originals.
async function cvValidateArchive(files){
  let hasConversations=false;
  const manifests=[],zipNames=new Map(),accountIDs=new Set(),emails=new Set();
  const partFamilies=new Map();
  const account=(value,isUser=false)=>{
    if(!value||typeof value!=='object')return;
    const id=value.account_uuid||value.account_id||(isUser&&(value.uuid||value.id));
    if(id)accountIDs.add(String(id).toLowerCase());
    if(isUser&&(value.email_address||value.email))emails.add(String(value.email_address||value.email).toLowerCase());
  };
  function inspectJSON(name,data,fullPath){
    if(name==='conversations.json'){
      if(!Array.isArray(data)||data.some(c=>!c||typeof c!=='object'||Array.isArray(c)||(c.chat_messages!==undefined&&!Array.isArray(c.chat_messages))))
        throw cvArchiveError('conversations.json 的格式无效');
      for(const conversation of data){
        if(['name','summary'].some(k=>conversation[k]!=null&&typeof conversation[k]!=='string'))throw cvArchiveError('对话标题的格式无效');
        for(const message of conversation.chat_messages||[]){
          if(!message||typeof message!=='object'||(message.text!=null&&typeof message.text!=='string'))throw cvArchiveError('对话消息的格式无效');
          for(const key of ['content','attachments','files']){
            if(message[key]!=null&&(!Array.isArray(message[key])||message[key].some(value=>!value||typeof value!=='object')))
              throw cvArchiveError('对话消息 '+key+' 的格式无效');
          }
        }
      }
      hasConversations=true;
      data.forEach(c=>account(c));
    }
    if(name==='users.json'){
      if(!Array.isArray(data))throw cvArchiveError('users.json 的格式无效');
      data.forEach(u=>account(u,true));
    }
    if(name==='memories.json'&&Array.isArray(data))data.forEach(m=>account(m));
    if(/(^|\/)(memories|reflections)\//.test(fullPath))account(data);
    if(name==='login_history.json'&&data&&Array.isArray(data.login_events))data.login_events.forEach(e=>account(e));
    if(accountIDs.size>1||emails.size>1)throw cvArchiveError('检测到不同账号的数据，未将它们合成一个档案');
  }
  for(const file of files){
    const name=String(file.name).split('/').pop();
    if(cvManifestName(name)){
      let man;try{man=JSON.parse(await file.blob.text());}catch{throw cvArchiveError(name+' 清单无法解析');}
      if(!man||!Array.isArray(man.data_files)||!man.data_files.length)throw cvArchiveError(name+' 清单没有有效的 data_files');
      manifests.push(man);continue;
    }
    if(/\.zip$/i.test(name)){
      const key=name.toLowerCase();
      if(zipNames.has(key))throw cvArchiveError('发现同名 ZIP，无法确定它们属于哪一次导出：'+name);
      zipNames.set(key,name);
      const part=name.match(/^(conversations|projects|memories|feedback|light_metadata)-(\d+)(?: \(\d+\))?\.zip$/i);
      if(part){const family=part[1].toLowerCase();if(!partFamilies.has(family))partFamilies.set(family,[]);partFamilies.get(family).push(Number(part[2]));}
      let zip;
      try{zip=await JSZip.loadAsync(await cvZipInput(file.blob),{checkCRC32:true});}
      catch(e){throw new Error(name+'：ZIP 损坏或无法读取（'+(e.message||e)+'）。当前档案没有切换。');}
      for(const entry of Object.values(zip.files)){
        if(entry.dir||!entry.name.endsWith('.json'))continue;
        let data;try{data=JSON.parse(await entry.async('string'));}catch{throw cvArchiveError(name+' 内的 '+entry.name+' 不是有效 JSON');}
        inspectJSON(entry.name.split('/').pop(),data,entry.name);
      }
    }else if(/\.json$/i.test(name)){
      let data;try{data=JSON.parse(await file.blob.text());}catch{throw cvArchiveError(file.name+' 不是有效 JSON');}
      inspectJSON(name,data,file.name);
    }
  }
  if(manifests.length>1)throw cvArchiveError('发现多份 manifest，不能把多次导出作为一个档案打开');
  const manifest=manifests[0]||null;
  if(manifest){
    const wanted=new Set();
    for(const item of manifest.data_files){
      if(!item||typeof item.filename!=='string'||!item.filename||/[\\/]/.test(item.filename))throw cvArchiveError('manifest 中的文件名无效');
      const key=item.filename.toLowerCase();
      if(wanted.has(key))throw cvArchiveError('manifest 重复列出了 '+item.filename);
      wanted.add(key);
    }
    const local=new Map(files.map(f=>[String(f.name).split('/').pop().toLowerCase(),f.name]));
    const missing=[...wanted].filter(n=>!local.has(n));
    if(missing.length)throw cvArchiveError('这一套导出缺少清单中的文件：'+missing.join('、'));
    const extra=[...zipNames.keys()].filter(n=>!wanted.has(n));
    if(extra.length)throw cvArchiveError('清单之外还发现 ZIP，可能混入其他导出：'+extra.join('、'));
  }else{
    for(const [family,parts] of partFamilies){
      const sorted=parts.sort((a,b)=>a-b);
      if(sorted.some((n,i)=>n!==i))throw cvArchiveError(family+' 分片序号不连续或重复，可能缺少文件');
    }
    // A single legacy ZIP is an export. Two legacy ZIPs cannot be inferred to be
    // pieces of one export; callers should add them as separate archive records.
    if(zipNames.size>1&&[...zipNames.keys()].some(n=>!/^(conversations|projects|memories|feedback|light_metadata)-\d+(?: \(\d+\))?\.zip$/i.test(n)))
      throw cvArchiveError('多个旧版 ZIP 应各自作为独立档案添加');
  }
  if(!hasConversations)throw cvArchiveError('这一整套中没有 conversations.json 对话数据');
  return{manifest,accountID:[...accountIDs][0]||null};
}
async function cvHydrateArchive(rec){
  if(!rec||!rec.id||!Array.isArray(rec.files))throw new Error('档案记录无效');
  const files=[];
  for(let index=0;index<rec.files.length;index++){
    const file=rec.files[index];
    const expected='claude-archive://archive/'+rec.id+'/'+index;
    if(file.url!==expected)throw new Error('档案文件地址无效');
    const response=await fetch(file.url);
    if(!response.ok)throw new Error('无法读取原件：'+file.name);
    const blob=await response.blob();
    if(blob.size!==file.size)throw new Error('原件大小发生变化：'+file.name+'。请重新打开档案库。');
    files.push({...file,blob});
  }
  await cvValidateArchive(files);
  return{...rec,files};
}

// CV_NATIVE_UI_START: everything below runs within the original viewer IIFE.
let cvNativeTemporary=false;
const cvMetadataWrites=new Map();
// The App waits for this before closing the web view, then drains its disk queue.
window.claudeNativeFlush=async()=>{await Promise.all([...cvMetadataWrites.values()]);return true;};
function cvSaveMetadata(rec){
  // Send immediately (no 300 ms debounce), preserving per-archive ordering.
  const metadata=JSON.parse(JSON.stringify(rec.metadata||{favorites:[],tags:{}}));
  const previous=cvMetadataWrites.get(rec.id);
  const save=()=>cvNativeCall('metadata',{id:rec.id,metadata});
  const next=previous?previous.then(save):save();
  cvMetadataWrites.set(rec.id,next);
  next.finally(()=>{if(cvMetadataWrites.get(rec.id)===next)cvMetadataWrites.delete(rec.id);}).catch(()=>{});
  return next;
}
arcProbe=async()=>true;
annSave=function(){
  if(activeArc){
    activeArc.metadata={favorites:[...favorites],tags:JSON.parse(JSON.stringify(tags))};
    cvSaveMetadata(activeArc).catch(e=>{console.error(e);arcSetStatus('收藏和标签保存失败：'+e.message);alert('收藏和标签保存失败：'+e.message);});
  }else{
    localStorage.setItem('cv_favs',JSON.stringify([...favorites]));
    localStorage.setItem('cv_tags',JSON.stringify(tags));
  }
};
arcOpen=async function(rec){
  showLoad('读取并校验完整导出…');
  try{
    if(activeArc&&cvMetadataWrites.has(activeArc.id))await cvMetadataWrites.get(activeArc.id);
    const source=await cvHydrateArchive(await cvNativeCall('get',{id:rec.id}));
    const previousData=appData;
    let parsed;
    // Parsing uses the unmodified upstream functions in an isolated staging object.
    // The visible state and active archive only change after all files succeed.
    appData={convs:[],projects:[],memories:null,account:null,globalMemory:null,reflections:null,loginHistory:null};
    try{
      for(const file of source.files){
        const name=baseName(file.name);
        if(/\.zip$/i.test(name))await parseZip(file.blob);
        else if(/\.json$/i.test(name)&&!cvManifestName(name))classifyJson(name,JSON.parse(await file.blob.text()),file.name);
        else if(/\.(md|markdown)$/i.test(name))classifyMd(name,await file.blob.text());
      }
      parsed=appData;
    }finally{appData=previousData;}
    resetState();resetCC();appMode='export';appData=parsed;
    activeArc={...source,files:source.files.map(({blob,...file})=>file)};
    pendingImport=null;cvNativeTemporary=false;
    localStorage.setItem('cv_active_arc',activeArc.id);localStorage.removeItem('cv_active_archive');
    annLoad();isCached=false;finalizeData(true);arcHide();cvUpdateImportLabels();
  }finally{hideLoad();}
};
arcRestore=async function(){
  const id=localStorage.getItem('cv_active_arc')||localStorage.getItem('cv_active_archive');
  if(!id){const records=await cvNativeCall('list');const warnings=await cvNativeCall('warnings').catch(()=>[]);if((records&&records.length)||(Array.isArray(warnings)&&warnings.length)){arcShow();return;}return checkStartupCache();}
  try{
    const rec=await cvNativeCall('get',{id});
    if(!rec){localStorage.removeItem('cv_active_arc');localStorage.removeItem('cv_active_archive');return checkStartupCache();}
    await arcOpen(rec);
  }catch(e){arcShow();arcSetStatus('上次档案未能打开：'+e.message);}
};
arcExportSet=async rec=>{await cvNativeCall('export',{id:rec.id});};
arcExportOne=async(rec,file)=>{try{await cvNativeCall('export',{id:rec.id,index:rec.files.indexOf(file)});}catch(e){arcSetStatus(e.message);}};
arcRenderStorage=async function(){
  const box=$('arc-storage');if(!box)return;
  const used=arcRecords.reduce((n,r)=>n+(r.size||0),0);
  const warnings=await cvNativeCall('warnings').catch(()=>[]);
  const messages=Array.isArray(warnings)?warnings.filter(w=>typeof w==='string'):[];
  box.style.whiteSpace='pre-wrap';
  // Archive names come from local files. Use textContent even for warning text.
  box.textContent='档案库占用 '+formatBytes(used)+'（'+arcRecords.length+' 份）。原件保存在 ~/Library/Application Support/ClaudeViewer/Archives 的普通文件夹；删除 App 不会删除这些档案。可在 Finder 中查看，也可取出整套原件。'+
    (messages.length?'\n\n以下项目暂未显示为档案，请检查目录内容：\n'+messages.join('\n'):'');
};
arcRender=function(){
  const box=$('arc-list');box.innerHTML='';
  if(!arcRecords.length){box.textContent='还没有档案。每个账号、每次导出放入一个文件夹，再添加到这里。';return;}
  for(const rec of arcRecords){
    const row=document.createElement('div');row.className='arc-row'+(activeArc&&activeArc.id===rec.id?' on':'');
    const title=document.createElement('div');title.className='arc-name';title.textContent=rec.name+(activeArc&&activeArc.id===rec.id?' · 正在查看':'');row.appendChild(title);
    const meta=document.createElement('div');meta.className='arc-meta';meta.textContent=rec.files.length+' 个原始文件 · '+formatBytes(rec.size||0);row.appendChild(meta);
    const buttons=document.createElement('div');buttons.className='arc-btns';row.appendChild(buttons);
    const button=(label,fn,cls='')=>{const b=document.createElement('button');b.type='button';b.className='arc-btn '+cls;b.textContent=label;b.addEventListener('click',()=>arcRun(fn));buttons.appendChild(b);};
    button('打开',()=>arcOpen(rec));
    const name=document.createElement('input');name.value=rec.name;name.maxLength=80;name.className='arc-rename';name.setAttribute('aria-label','档案名称');buttons.appendChild(name);
    button('重命名',async()=>{const value=name.value.trim();if(!value)return;await cvNativeCall('rename',{id:rec.id,name:value});if(activeArc&&activeArc.id===rec.id){activeArc.name=value;updateCacheBar();}await arcRefresh();});
    button('取出整套原件',()=>arcExportSet(rec));
    button('在 Finder 中显示',()=>cvNativeCall('reveal',{id:rec.id}));
    button('移至废纸篓',async()=>{
      if(cvMetadataWrites.has(rec.id))await cvMetadataWrites.get(rec.id);
      const removed=await cvNativeCall('remove',{id:rec.id});
      if(!removed)return;
      if(activeArc&&activeArc.id===rec.id){arcLeave();localStorage.removeItem('cv_active_archive');resetState();resetCC();showUpload();}
      await arcRefresh();await arcRenderStorage();arcSetStatus('已移至废纸篓');
    },'danger');
    const originals=document.createElement('div');originals.className='arc-files';
    rec.files.forEach(file=>{const b=document.createElement('button');b.type='button';b.className='arc-file';b.textContent=file.name;b.addEventListener('click',()=>arcExportOne(rec,file));originals.appendChild(b);});
    row.appendChild(originals);box.appendChild(row);
  }
};
async function cvAcceptNativeRecords(records){
  await arcRefresh();await arcRenderStorage();
  if(Array.isArray(records)&&records.length===1){
    try{await arcOpen(records[0]);}
    catch(e){arcPanel.classList.add('show');arcSetStatus('原件已保留，但未切换当前档案：'+e.message);}
  }else{
    arcPanel.classList.add('show');
    arcSetStatus(Array.isArray(records)&&records.length?'已添加 '+records.length+' 份独立档案，请选择要查看的一份。':'档案库已刷新。');
  }
}
async function cvImportNative(mode){
  cvNativeTemporary=false;cvUpdateImportLabels();
  const records=await cvNativeCall('import',{mode});
  if(!records||!records.length)return;
  await cvAcceptNativeRecords(records);
}
const cvOriginalOpenExportDir=openExportDir;
openExportDir=function(){return cvNativeTemporary?cvOriginalOpenExportDir():arcRun(()=>cvImportNative('folder'));};
const cvOriginalShowSavePrompt=showSavePrompt;
showSavePrompt=function(){
  // Temporary files do not have native file URLs. Keep the upstream cache prompt,
  // but never claim these files were copied into the native archive directory.
  const pending=pendingImport;pendingImport=null;
  try{cvOriginalShowSavePrompt();}finally{pendingImport=pending;}
};
arcAdoptPending=async function(){throw new Error('请通过档案库的添加按钮选择原始文件，才能保存到 Mac 档案目录。');};
function cvUpdateImportLabels(){
  // The native drop handler must follow temporary mode too: otherwise dragging
  // onto a temporary view would still copy originals into the persistent library.
  cvNativeCall('mode',{temporary:cvNativeTemporary}).catch(error=>{
    const message='拖放模式未能更新，请通过按钮选择文件：'+error.message;
    arcSetStatus(message);
    const hint=dropZone.querySelector('.drop-hint');if(hint)hint.textContent=message;
  });
  $('pick-dir').textContent=cvNativeTemporary?'📁 临时打开导出文件夹':'📁 添加导出文件夹';
  $('pick-label').textContent=cvNativeTemporary?'临时选择文件':'添加旧版 ZIP';
  $('arc-add-zip').textContent='添加旧版 ZIP';
  const hint=dropZone.querySelector('.drop-hint');
  if(hint)hint.textContent=cvNativeTemporary?'仅本次查看：可选择完整导出文件夹、ZIP、JSON 或 Markdown，不复制到 Mac 档案库。':'新版导出：每个账号、每次导出的 manifest 和全部分类 ZIP 放在一个文件夹里添加。旧版完整 ZIP 可以多选，每个 ZIP 独立保存为一份档案。';
}
document.addEventListener('click',event=>{
  const target=event.target&&event.target.closest?event.target:null;if(!target)return;
  if(target.closest('#arc-temp')){cvNativeTemporary=true;cvUpdateImportLabels();return;}
  if(target.closest('#reset-btn')){cvNativeTemporary=false;cvUpdateImportLabels();}
  let mode=null;
  if(target.closest('#arc-add-dir'))mode='folder';
  else if(target.closest('#arc-add-zip'))mode='files';
  else if(!cvNativeTemporary&&target.closest('#pick-dir'))mode='folder';
  else if(!cvNativeTemporary&&target.closest('#pick-label, #file-input'))mode='files';
  if(mode){event.preventDefault();event.stopImmediatePropagation();arcRun(()=>cvImportNative(mode));}
},true);
// Native file drops are handled by the App shell; a browser-only fallback must
// not accidentally run the legacy merging import path for persistent archives.
dropZone.addEventListener('drop',event=>{
  if(cvNativeTemporary)return;
  event.preventDefault();event.stopImmediatePropagation();dropZone.classList.remove('over');
  arcSetStatus('请通过「添加导出文件夹」选择这次导出的原件。');arcShow();
},true);
window.addEventListener('claude-archives-changed',event=>{
  const records=Array.isArray(event.detail)?event.detail:event.detail&&event.detail.records;
  arcRun(()=>cvAcceptNativeRecords(records));
});
const cvDescription=arcPanel.querySelector('.arc-desc');
if(cvDescription)cvDescription.textContent='一份档案对应一个账号的一次完整导出：新版为 manifest + 全部分类 ZIP，旧版可直接添加单个 ZIP。多个账号或多次备份请分别放入不同文件夹；它们在档案库中独立保存，打开时仅载入所选档案，收藏和标签也分别保存。App 原样复制文件到自己的 Archives 目录，不上传、不改写原件。随时可以在 Finder 中找到原件，或取出整套后删除 App。';
const cvActions=arcPanel.querySelector('.arc-actions');
if(cvActions){const button=document.createElement('button');button.type='button';button.className='arc-btn';button.textContent='在 Finder 中打开档案目录';button.addEventListener('click',()=>arcRun(()=>cvNativeCall('reveal')));cvActions.appendChild(button);}
cvUpdateImportLabels();
