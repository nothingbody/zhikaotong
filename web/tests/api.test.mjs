import test from 'node:test';
import assert from 'node:assert/strict';

const storage = new Map();
globalThis.sessionStorage = { getItem: key => storage.get(key) ?? null, setItem: (key,value) => storage.set(key,value), removeItem: key => storage.delete(key) };
globalThis.window = { dispatchEvent() {} };
const client = await import('../src/api.js');
const json = (value,status=200) => new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});

test('concurrent expired requests share one rotating refresh', async () => {
  client.clearSession();
  client.storeSession({access_token:'expired',refresh_token:'refresh-old'});
  let refreshes=0;
  globalThis.fetch=async (path,options) => {
    if(path==='/api/auth/refresh') { refreshes++; await new Promise(resolve=>setTimeout(resolve,15)); return json({access_token:'renewed',refresh_token:'refresh-new'}); }
    if(options.headers.Authorization==='Bearer expired')return json({detail:'expired'},401);
    assert.equal(options.headers.Authorization,'Bearer renewed');
    return json({ok:true});
  };
  assert.deepEqual(await Promise.all([client.api('/auth/me'),client.api('/management/classes')]),[{ok:true},{ok:true}]);
  assert.equal(refreshes,1);
  assert.equal(client.getRefreshToken(),'refresh-new');
});

test('late refresh cannot restore a cleared session', async () => {
  client.clearSession();
  client.storeSession({access_token:'expired',refresh_token:'refresh-old'});
  let release, started;
  const began=new Promise(resolve=>{started=resolve;});
  globalThis.fetch=async path => {
    if(path==='/api/auth/refresh') { started(); return new Promise(resolve=>{release=()=>resolve(json({access_token:'late',refresh_token:'late-refresh'}));}); }
    return json({detail:'expired'},401);
  };
  const request=client.api('/auth/me');
  await began;
  client.clearSession();
  release();
  await assert.rejects(request,/登录状态已变更/);
  assert.equal(client.hasSession(),false);
  assert.equal(client.getRefreshToken(),null);
});

test('network failure returns an actionable message', async () => {
  client.clearSession();
  globalThis.fetch=async()=>{throw new TypeError('network disconnected');};
  await assert.rejects(client.api('/health'),/连接服务失败/);
});

test('authorized CSV exports preserve the POST filter body and return its original bytes', async () => {
  client.clearSession();
  client.storeSession({access_token:'download-token',refresh_token:'download-refresh'});
  const body={class_id:'class-1',subject_id:'math',date_from:'2026-11-01',date_to:'2026-11-04',student_ids:['student-2']};
  globalThis.fetch=async(path,options)=>{
    assert.equal(path,'/api/management/students/overview/export');
    assert.equal(options.method,'POST');
    assert.equal(options.headers.Authorization,'Bearer download-token');
    assert.deepEqual(JSON.parse(options.body),body);
    assert.equal('responseType' in options,false);
    return new Response('\ufeff姓名,答题次数\r\n学生甲,12\r\n',{headers:{'content-type':'text/csv; charset=utf-8'}});
  };
  const blob=await client.apiBlob('/management/students/overview/export',{method:'POST',body});
  assert.equal(blob.type,'text/csv;charset=utf-8');
  assert.deepEqual([...new Uint8Array(await blob.arrayBuffer()).slice(0,3)],[239,187,191]);
});

test('CSV download rotates expired authorization once without broadening selected students', async () => {
  client.clearSession();
  client.storeSession({access_token:'expired',refresh_token:'refresh-old'});
  const body={class_id:'class-1',student_ids:['student-2']};
  let refreshes=0,downloads=0;
  globalThis.fetch=async(path,options)=>{
    if(path==='/api/auth/refresh') {refreshes++;return json({access_token:'fresh-download',refresh_token:'refresh-new'});}
    downloads++;
    assert.deepEqual(JSON.parse(options.body),body);
    if(downloads===1)return json({detail:'expired'},401);
    assert.equal(options.headers.Authorization,'Bearer fresh-download');
    return new Response('csv',{headers:{'content-type':'text/csv'}});
  };
  assert.equal(await (await client.apiBlob('/management/students/overview/export',{method:'POST',body})).text(),'csv');
  assert.equal(refreshes,1);
  assert.equal(downloads,2);
});

test('a CSV body finishing after logout cannot be delivered to the replacement session', async () => {
  client.clearSession();
  client.storeSession({access_token:'old-user',refresh_token:'old-refresh'});
  let release,started;
  const began=new Promise(resolve=>{started=resolve;});
  globalThis.fetch=async()=>({ok:true,status:200,blob:()=>{started();return new Promise(resolve=>{release=()=>resolve(new Blob(['private export'],{type:'text/csv'}));});}});
  const download=client.apiBlob('/management/students/overview/export',{method:'POST',body:{class_id:'class-1'}});
  await began;
  client.clearSession();
  client.storeSession({access_token:'new-user',refresh_token:'new-refresh'});
  release();
  await assert.rejects(download,/登录状态已变更/);
  assert.equal(client.getRefreshToken(),'new-refresh');
});

test('forbidden CSV requests preserve structured errors rather than creating a download', async () => {
  client.clearSession();
  globalThis.fetch=async()=>json({detail:'仅管理员可导出学习汇总'},403);
  await assert.rejects(client.apiBlob('/management/students/overview/export',{method:'POST',body:{class_id:'other-class'}}),error=>error.status===403&&error.message==='仅管理员可导出学习汇总');
});
