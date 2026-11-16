import test from 'node:test';
import assert from 'node:assert/strict';
import { canImportWordQuestion, UNKNOWN_SUBJECT_REASON } from '../src/word-import-scope.js';

const question = { type: 'single', subject_hint: 'unknown', eligible: false,
  blocked_reasons: [UNKNOWN_SUBJECT_REASON], options: [{ key: 'A', text: '甲' }, { key: 'B', text: '乙' }], answer: ['A'] };

test('unknown subjects remain blocked until an explicit target is selected', () => {
  assert.equal(canImportWordQuestion(question), false);
  assert.equal(canImportWordQuestion(question, 'actual-subject'), true);
  assert.equal(canImportWordQuestion({ ...question, subject_hint: 'math', eligible: true, blocked_reasons: [] }), true);
});

test('manual subject selection cannot bypass incomplete answers, media or unsupported types', () => {
  for (const changes of [
    { answer: [] },
    { answer: ['C'] },
    { unresolved_image_count: 1 },
    { unresolved_formula_count: 1 },
    { image_count: 1 },
    { blocked_reasons: [UNKNOWN_SUBJECT_REASON, '缺少完整阅读材料'] },
    { type: 'drawing' },
  ]) assert.equal(canImportWordQuestion({ ...question, ...changes }, 'actual-subject'), false);
  assert.equal(canImportWordQuestion({ ...question, blocked_reasons: [UNKNOWN_SUBJECT_REASON, '缺少答案'], corrected: true }, 'actual-subject'), true);
  assert.equal(canImportWordQuestion({ ...question, type: 'fill', options: [], answer: [['']] }, 'actual-subject'), false);
});
