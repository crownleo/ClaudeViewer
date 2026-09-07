'use strict';

// Development-only dependency; the distributed viewer still has no dependencies.
// npm install --prefix _local --no-save fake-indexeddb@6.2.4
// node --test tests/archive-library.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { webcrypto, createHash } = require('node:crypto');
const { test } = require('node:test');
let IDBFactory;
try {
  ({ IDBFactory } = require('fake-indexeddb'));
} catch {
  ({ IDBFactory } = require('../_local/node_modules/fake-indexeddb'));
}

const html = fs.readFileSync(path.join(__dirname, '..', 'claude_viewer.html'), 'utf8');
const zipScript = [...html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)]
  .map(match => match[1]).find(script => script.startsWith('/* JSZip '));
const libraryScript = html.match(/\/\* archive-library:start \*\/([\s\S]*?)\/\* archive-library:end \*\//)?.[1];
assert.ok(zipScript, 'The shipped viewer must include its offline ZIP parser.');
assert.ok(libraryScript, 'The shipped viewer must include its archive library.');

// JSZip uses FileReader for browser Blobs; Node supplies Blob but no FileReader.
class BlobReader {
  readAsArrayBuffer(blob) {
    blob.arrayBuffer().then(result => {
      this.result = result;
      this.onload?.({ target: this });
    }, error => {
      this.error = error;
      this.onerror?.({ target: this });
    });
  }
}

function makeRuntime(indexedDB = new IDBFactory()) {
  const context = vm.createContext({
    indexedDB, crypto: webcrypto, Blob, File, Buffer, ArrayBuffer, Uint8Array,
    TextEncoder, TextDecoder, structuredClone, setTimeout, clearTimeout,
    setImmediate, clearImmediate, FileReader: BlobReader, console,
  });
  context.window = context;
  context.self = context;
  vm.runInContext(zipScript, context, { filename: 'bundled-jszip.js' });
  vm.runInContext(libraryScript, context, { filename: 'archive-library.js' });
  return { context, indexedDB, store: new context.ClaudeArchiveLibrary.BrowserStore() };
}

async function makeExport(context, account, filename = 'claude-export.zip', options = {}) {
  const zip = new context.JSZip();
  const prefix = options.nested ? 'claude-export/' : '';
  // Deliberately reuse a conversation UUID between accounts to exercise isolation.
  zip.file(prefix + 'conversations.json', JSON.stringify([{
    uuid: 'same-conversation-uuid', name: `Conversation ${account}`,
    account: { uuid: `account-${account}` }, created_at: '2026-01-01T00:00:00Z',
    chat_messages: [{ uuid: `message-${account}`, sender: 'human', text: `Hello ${account}` }],
  }]));
  zip.file(prefix + 'users.json', JSON.stringify([{ uuid: `account-${account}`, full_name: `Account ${account}` }]));
  zip.file(prefix + 'memories.json', JSON.stringify([{ conversations_memory: `Memory ${account}` }]));
  zip.file(prefix + 'projects/abcdef.json', JSON.stringify({ uuid: 'same-project-uuid', name: `Project ${account}`, prompt_template: `Prompt ${account}` }));
  // An unrelated binary member must survive without being decoded or re-compressed.
  zip.file(prefix + 'attachments/sample.bin', Uint8Array.from([0, 255, 17, 128, 42]));
  if (options.entries) {
    for (const [name, value] of Object.entries(options.entries)) zip.file(prefix + name, value);
  }
  const bytes = await zip.generateAsync({ type: 'uint8array', compression: 'DEFLATE' });
  return new File([bytes], filename, { type: 'application/zip' });
}

async function digest(blob) {
  return createHash('sha256').update(Buffer.from(await blob.arrayBuffer())).digest('hex');
}

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

async function seedLegacyCache(indexedDB) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open('claude_viewer_v4', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('store', { keyPath: 'key' });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  const sentinel = { key: 'appData', data: { convs: [{ uuid: 'legacy-keep-me' }] }, savedAt: '2026-01-01T00:00:00Z' };
  await new Promise((resolve, reject) => {
    const tx = db.transaction('store', 'readwrite');
    tx.objectStore('store').put(sentinel);
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  return {
    sentinel,
    read: () => new Promise((resolve, reject) => {
      const request = db.transaction('store').objectStore('store').get('appData');
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    }),
  };
}

function makeViewerController(context) {
  // Exercise the actual controller and existing finalizer without a GUI. The DOM
  // stand-ins only absorb drawing; all source/annotation/switch logic is shipped code.
  const elements = new Map();
  const element = () => ({
    textContent: '', innerHTML: '', value: '', hidden: false, inert: false, style: {}, attributes: {},
    classList: { add() {}, remove() {}, toggle() {} },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    appendChild() {}, replaceChildren() {}, addEventListener() {}, focus() {},
  });
  const getElement = id => {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  };
  const localValues = new Map([
    ['cv_favs', '["legacy-favorite"]'],
    ['cv_tags', '{"legacy-favorite":["legacy tag"]}'],
  ]);
  context.$ = getElement;
  context.document = { createElement: element, querySelectorAll: () => [] };
  context.localStorage = {
    getItem: key => localValues.get(key) ?? null,
    setItem: (key, value) => localValues.set(key, String(value)),
    removeItem: key => localValues.delete(key),
  };
  for (const name of ['srchSidebar', 'vc', 'detailTitle', 'staticPanel', 'sbSearch', 'modalOverlay', 'shSub', 'loadingMsg', 'mainScreen', 'uploadScreen']) {
    context[name] = getElement(name);
  }
  const section = (start, end) => {
    const a = html.indexOf(start), b = html.indexOf(end, a);
    assert.ok(a >= 0 && b > a, `Expected viewer section: ${start}`);
    return html.slice(a, b);
  };
  vm.runInContext(`
    let appData={convs:[],projects:[],memories:null,account:null,globalMemory:null};
    let filteredConvs=[],listDisplay=[],curConv=null,curMsgs=[],filterFav=false,filterTag='';
    let dayFilter='',gsResults=[],curMemSection='',curTab='convs',srchSidebarOpen=false;
    let heights=[],offsets=[],totalH=0,rendered=new Map(),appMode='export',isCached=false;
    let exportSubText='',cacheMode='never';
    let favorites=new Set(JSON.parse(localStorage.getItem('cv_favs'))),tags=JSON.parse(localStorage.getItem('cv_tags'));
    function clearSearch(){} function showLoad(){} function hideLoad(){}
    function showMain(){} function showUpload(){} function showDetail(){}
    function updateCacheBar(){} function setTab(id){curTab=id;}
    function applyMode(){setAnnotationContext();}
    function formatBytes(value){return String(value);} function fmtDate(value){return String(value);}
    ${section('function resetState(){', '// 载入内置演示数据')}
    ${section('function hasContent(c)', 'let _openCallback=')}
    ${section('async function parseZip(', '\nfunction classifyMd(')}
    ${section('function finalizeData(', '\nfunction showSavePrompt(')}
    ${section('let activeArchive=null,', '// ── INDEXEDDB')}
    globalThis.viewerController={
      selectArchive, refreshArchives, showArchivePanel, closeArchivePanel,
      annotate(value){favorites=new Set(value.favorites);tags=value.tags;persistAnnotations();return archiveMetadataWrites;},
      mode(value){appMode=value;setAnnotationContext();},
      transient(){dayFilter='2020-01-01';gsResults=['old account search'];curMemSection='old';curMsgs=[{text:'old'}];},
      corruptReads(){archiveStore.read=async()=>new File(['invalid bytes'],'broken.zip');},
      failOneMetadataWrite(){
        const original=archiveStore.setMetadata.bind(archiveStore);let fail=true;
        archiveStore.setMetadata=(...args)=>{if(fail){fail=false;return Promise.reject(new Error('Simulated disk failure'));}return original(...args);};
      },
      state(){return {active:activeArchive?.id,appData,favorites:[...favorites],tags,dayFilter,gsResults,curMsgs,appMode};}
    };
  `, context, { filename: 'viewer-controller-under-test.js' });
  return { controller: context.viewerController, localValues, elements };
}

test('original ZIP bytes survive import, rename, metadata updates, and reopening', async () => {
  const { context, store, indexedDB } = makeRuntime();
  const source = await makeExport(context, 'A', '原始导出.zip', { nested: true });
  const record = await store.importFile(source);
  assert.equal(record.filename, '原始导出.zip');
  assert.equal(record.size, source.size);
  assert.equal(record.sha256, await digest(source));
  await store.rename(record.id, 'My account A');
  await store.setMetadata(record.id, { favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['A only'] } });
  const reopened = makeRuntime(indexedDB).store;
  const [saved] = await reopened.list();
  assert.equal(saved.name, 'My account A');
  assert.equal(saved.filename, source.name);
  assert.equal(await digest(await reopened.read(saved)), await digest(source));
  assert.deepEqual(plain(saved.metadata), { favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['A only'] } });
});

test('same-named ZIPs stay separate, byte-identical duplicates keep existing metadata', async () => {
  const { context, store } = makeRuntime();
  const sourceA = await makeExport(context, 'A');
  const sourceB = await makeExport(context, 'B');
  const recordA = await store.importFile(sourceA);
  const recordB = await store.importFile(sourceB);
  assert.notEqual(recordA.id, recordB.id);
  assert.notEqual(recordA.sha256, recordB.sha256);
  await store.rename(recordA.id, 'A renamed');
  await store.setMetadata(recordA.id, { favorites: ['same-conversation-uuid'], tags: {} });
  const duplicate = await store.importFile(new File([sourceA], 'a-different-name.zip', { type: sourceA.type }));
  assert.equal(duplicate.id, recordA.id);
  assert.equal(duplicate.name, 'A renamed');
  assert.deepEqual(plain(duplicate.metadata.favorites), ['same-conversation-uuid']);
  assert.equal((await store.list()).length, 2);
});

test('two accounts with equal conversation UUIDs have independent favorites and tags', async () => {
  const { context, store, indexedDB } = makeRuntime();
  const recordA = await store.importFile(await makeExport(context, 'A'));
  const recordB = await store.importFile(await makeExport(context, 'B'));
  const metadataA = { favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['Account A only'] } };
  const metadataB = { favorites: [], tags: { 'same-conversation-uuid': ['Account B only'] } };
  await store.setMetadata(recordA.id, metadataA);
  await store.setMetadata(recordB.id, metadataB);
  // Mutating caller-owned data after save must not affect the committed record.
  metadataA.tags['same-conversation-uuid'].push('unsaved');
  const records = await makeRuntime(indexedDB).store.list();
  assert.deepEqual(plain(records.find(record => record.id === recordA.id).metadata), {
    favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['Account A only'] },
  });
  assert.deepEqual(plain(records.find(record => record.id === recordB.id).metadata), metadataB);
});

test('simultaneous imports of one original produce one archive', async () => {
  const { context, store } = makeRuntime();
  const source = await makeExport(context, 'A');
  const records = await Promise.all([store.importFile(source), store.importFile(source)]);
  assert.equal(records[0].id, records[1].id);
  assert.equal((await store.list()).length, 1);
  assert.equal(await digest(await store.read(records[0])), await digest(source));
});

test('an account export with no conversations is still a valid original archive', async () => {
  const { context, store } = makeRuntime();
  const source = await makeExport(context, 'Empty', 'EMPTY.ZIP', { entries: { 'conversations.json': '[]' } });
  const record = await store.importFile(source);
  assert.equal(record.filename, 'EMPTY.ZIP');
  assert.equal((await store.list()).length, 1);
  assert.equal(await digest(await store.read(record)), await digest(source));
});

test('invalid ZIPs and malformed recognized JSON do not change the existing library', async () => {
  const { context, store } = makeRuntime();
  const source = await makeExport(context, 'A');
  const saved = await store.importFile(source);
  const before = plain(await store.list());
  const invalidZip = new File(['not a zip'], 'broken.zip', { type: 'application/zip' });
  const malformed = await makeExport(context, 'B', 'malformed.zip', { entries: { 'users.json': '{broken' } });
  const wrongShape = await makeExport(context, 'B', 'wrong-shape.zip', { entries: { 'conversations.json': '{}' } });
  const malformedMembers = [];
  for (const value of [[null], [{ uuid: 'bad', chat_messages: 'not an array' }],
    [{ uuid: 'bad', chat_messages: [null] }], [{ uuid: 'bad', chat_messages: [{ content: {} }] }]]) {
    malformedMembers.push(await makeExport(context, 'B', 'bad-members.zip', { entries: { 'conversations.json': JSON.stringify(value) } }));
  }
  const noConversationsZip = new context.JSZip();
  noConversationsZip.file('readme.txt', 'Unrelated ZIP');
  const noConversations = new File([await noConversationsZip.generateAsync({ type: 'uint8array' })], 'unrelated.zip');
  const checksumZip = new context.JSZip();
  checksumZip.file('conversations.json', '[{"uuid":"CRC marker","chat_messages":[]}]');
  const checksumBytes = Buffer.from(await checksumZip.generateAsync({ type: 'uint8array', compression: 'STORE' }));
  checksumBytes[checksumBytes.indexOf('CRC marker')] = 'X'.charCodeAt(0);
  const wrongChecksum = new File([checksumBytes], 'wrong-checksum.zip');
  for (const invalid of [invalidZip, malformed, wrongShape, ...malformedMembers, noConversations, wrongChecksum]) {
    await assert.rejects(store.importFile(invalid));
    assert.deepEqual(plain(await store.list()), before);
    assert.equal(await digest(await store.read(saved)), await digest(source));
  }
});

test('removing one archive survives restart without deleting another or the legacy cache', async () => {
  const { context, store, indexedDB } = makeRuntime();
  const legacy = await seedLegacyCache(indexedDB);
  const recordA = await store.importFile(await makeExport(context, 'A'));
  const sourceB = await makeExport(context, 'B');
  const recordB = await store.importFile(sourceB);
  await store.remove(recordA.id);
  const reopened = makeRuntime(indexedDB).store;
  assert.deepEqual((await reopened.list()).map(record => record.id), [recordB.id]);
  await assert.rejects(reopened.read(recordA));
  assert.equal(await digest(await reopened.read(recordB)), await digest(sourceB));
  assert.deepEqual(await legacy.read(), legacy.sentinel);
});

test('a reused parser populates isolated targets without mixing account or project data', async () => {
  const { context } = makeRuntime();
  const parserStart = html.indexOf('async function parseZip(');
  const parserEnd = html.indexOf('\nfunction classifyMd(', parserStart);
  assert.ok(parserStart > 0 && parserEnd > parserStart, 'Viewer parser should remain directly reusable.');
  context.loadingMsg = { textContent: '' };
  context.appData = { convs: [{ uuid: 'untouched-current-view' }], projects: [], account: null, memories: null };
  vm.runInContext(html.slice(parserStart, parserEnd) + '\nglobalThis.parseFixtureZip = parseZip;', context);
  const empty = () => ({ convs: [], projects: [], memories: null, account: null, globalMemory: null });
  const targetA = empty();
  const targetB = empty();
  await context.parseFixtureZip(await makeExport(context, 'A'), targetA);
  await context.parseFixtureZip(await makeExport(context, 'B'), targetB);
  assert.equal(targetA.account.uuid, 'account-A');
  assert.equal(targetB.account.uuid, 'account-B');
  assert.equal(targetA.memories.conversations_memory, 'Memory A');
  assert.equal(targetB.memories.conversations_memory, 'Memory B');
  assert.equal(targetA.projects[0].name, 'Project A');
  assert.equal(targetB.projects[0].name, 'Project B');
  assert.equal(targetA.convs.length, 1);
  assert.equal(targetB.convs.length, 1);
  assert.equal(context.appData.convs[0].uuid, 'untouched-current-view');
});

test('viewer selection restores each account annotations and clears previous search state', async () => {
  const { context, store } = makeRuntime();
  const recordA = await store.importFile(await makeExport(context, 'A'));
  const recordB = await store.importFile(await makeExport(context, 'B'));
  const { controller, localValues } = makeViewerController(context);
  await controller.selectArchive(recordA);
  await controller.annotate({ favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['A only'] } });
  controller.transient();
  await controller.selectArchive(recordB);
  let state = plain(controller.state());
  assert.equal(state.appData.account.uuid, 'account-B');
  assert.deepEqual(state.favorites, []);
  assert.deepEqual(state.tags, {});
  assert.equal(state.dayFilter, '');
  assert.deepEqual(state.gsResults, []);
  assert.deepEqual(state.curMsgs, []);
  await controller.selectArchive((await store.list()).find(record => record.id === recordA.id));
  assert.deepEqual(plain(controller.state()).favorites, ['same-conversation-uuid']);
  controller.mode('cc');
  assert.deepEqual(plain(controller.state()).favorites, ['legacy-favorite']);
  controller.mode('export');
  assert.deepEqual(plain(controller.state()).tags, { 'same-conversation-uuid': ['A only'] });
  assert.equal(localValues.get('cv_favs'), '["legacy-favorite"]');
  assert.equal(localValues.get('cv_tags'), '{"legacy-favorite":["legacy tag"]}');
});

test('failed archive selection keeps the current account and its annotations intact', async () => {
  const { context, store } = makeRuntime();
  const recordA = await store.importFile(await makeExport(context, 'A'));
  const recordB = await store.importFile(await makeExport(context, 'B'));
  const { controller } = makeViewerController(context);
  await controller.selectArchive(recordA);
  await controller.annotate({ favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['A only'] } });
  const before = plain(controller.state());
  controller.corruptReads();
  await assert.rejects(controller.selectArchive(recordB));
  assert.deepEqual(plain(controller.state()), before);
});

test('a failed metadata save can be retried without loading stale annotations', async () => {
  const { context, store } = makeRuntime();
  context.console = { ...console, error() {} }; // Expected simulated storage failure.
  const record = await store.importFile(await makeExport(context, 'A'));
  const staleListedRecord = (await store.list())[0];
  const { controller } = makeViewerController(context);
  await controller.selectArchive(record);
  controller.failOneMetadataWrite();
  const annotations = { favorites: ['same-conversation-uuid'], tags: { 'same-conversation-uuid': ['Keep on retry'] } };
  await controller.annotate(annotations);
  // The library remains usable after an error, and opening retries unsaved edits.
  await controller.refreshArchives();
  await controller.selectArchive(staleListedRecord);
  assert.deepEqual(plain(controller.state()).favorites, annotations.favorites);
  assert.deepEqual(plain(controller.state()).tags, annotations.tags);
  assert.deepEqual(plain((await store.list())[0].metadata), annotations);
});

test('the archive dialog hides background screens from keyboard and accessibility navigation', async () => {
  const { context } = makeRuntime();
  const { controller, elements } = makeViewerController(context);
  await controller.showArchivePanel();
  assert.equal(elements.get('archive-panel').hidden, false);
  for (const screen of [context.mainScreen, context.uploadScreen]) {
    assert.equal(screen.inert, true);
    assert.equal(screen.getAttribute('aria-hidden'), 'true');
  }
  controller.closeArchivePanel();
  assert.equal(elements.get('archive-panel').hidden, true);
  for (const screen of [context.mainScreen, context.uploadScreen]) {
    assert.equal(screen.inert, false);
    assert.equal(screen.getAttribute('aria-hidden'), 'false');
  }
});
