import { hasCompleteMediaReferences } from './question-media.js';

export const WORD_SUBJECTS = { chinese: '语文', math: '数学', english: '英语', politics: '思想政治', mechanics: '机械专业综合理论' };
export const UNKNOWN_SUBJECT_REASON = '未能可靠识别科目，请人工指定科目';

export function isContentBlocked(question, subjectResolved = false) {
  const missingAnswer = /missing_answer|answer_missing|缺少答案|未找到答案|答案缺失|缺少可确定的答案/i;
  const unresolved = Number(question.unresolved_image_count || 0) + Number(question.unresolved_formula_count || 0);
  const oldUnresolved = (Number(question.image_count || 0) > 0 || Number(question.formula_count || 0) > 0) && !hasCompleteMediaReferences(question);
  return unresolved > 0 || oldUnresolved || (question.blocked_reasons || []).some(reason => !(subjectResolved && reason === UNKNOWN_SUBJECT_REASON) && !missingAnswer.test(String(reason)));
}

export function hasAnswer(question) {
  if (question.type === 'fill') return Array.isArray(question.answer) && question.answer.length > 0 && question.answer.every(slot => Array.isArray(slot) && slot.some(value => typeof value === 'string' && value.trim()));
  const keys = new Set((question.options || []).map(option => option.key));
  return Array.isArray(question.answer) && question.answer.length > 0 && question.answer.every(value => keys.has(value)) && (question.type === 'multiple' || question.answer.length === 1);
}

export function canImportWordQuestion(question, defaultSubjectId = '') {
  const known = Boolean(WORD_SUBJECTS[question.subject_hint]);
  const manual = !known && Boolean(defaultSubjectId);
  return ['single', 'multiple', 'fill', 'judge'].includes(question.type) && (known || manual) && !isContentBlocked(question, manual) && (question.eligible || question.corrected || manual) && hasAnswer(question);
}
