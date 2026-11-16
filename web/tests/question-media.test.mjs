import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { plainQuestionText, editableQuestionText, restoreQuestionText, hasCompleteMediaReferences, verifyQuestionMedia } from '../src/question-media.js';

// A generated 1x1 RGBA PNG: no school picture cache is needed by this test.
const source = {width:1,height:1};
const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/QFb/BsAAAAASUVORK5CYII=','base64');
const id = createHash('sha256').update(bytes).digest('hex');
const asset = {mime:'image/png',data:bytes.toString('base64'),width:source.width,height:source.height};
const token = `{{img:${id}}}`;

test('source previews verify their exact checksum and dimensions before display',async()=>{
  const result = await verifyQuestionMedia(id,asset);
  assert.equal(result.src,`data:image/png;base64,${asset.data}`);
  await assert.rejects(verifyQuestionMedia('0'.repeat(64),asset),/校验失败/);
  await assert.rejects(verifyQuestionMedia(id,{...asset,width:source.width+1}),/尺寸校验失败/);
  await assert.rejects(verifyQuestionMedia(id,{...asset,mime:'image/svg+xml'}),/题图缺失/);
  await assert.rejects(verifyQuestionMedia(id,undefined),/题图缺失/);
});

test('summaries conceal internal identifiers while edit round trips preserve original image references',()=>{
  const original=`已知${token}，求${token}。`;
  assert.equal(plainQuestionText(original),'已知〔题图〕，求〔题图〕。');
  assert.equal(editableQuestionText(original),'已知〔原图1〕，求〔原图2〕。');
  assert.equal(restoreQuestionText('修改文字〔原图2〕。',original),`修改文字${token}。`);
  assert.equal(restoreQuestionText('删除原图后仅保留文字',original),'删除原图后仅保留文字');
});

test('known image counts cannot mask missing or unsupported media references',()=>{
  assert.equal(hasCompleteMediaReferences({stem:token,media:{[id]:asset}}),true);
  assert.equal(hasCompleteMediaReferences({stem:token,media:{}}),false);
  assert.equal(hasCompleteMediaReferences({stem:'普通文字',media:{[id]:asset}}),false);
  assert.equal(hasCompleteMediaReferences({stem:token,media:{[id]:{...asset,mime:'text/html'}}}),false);
});
