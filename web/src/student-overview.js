export const OVERVIEW_SORTS = Object.freeze({
  answered: '答题次数', accuracy: '正确率', study_seconds: '练习用时',
  active_days: '活跃天数', last_answered_at: '最近作答', name: '姓名', username: '账号'
});

export function shanghaiToday(now = new Date()) {
  const parts = new Intl.DateTimeFormat('en-CA', {timeZone:'Asia/Shanghai', year:'numeric', month:'2-digit', day:'2-digit'}).formatToParts(now);
  const value = Object.fromEntries(parts.map(part => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}

export function recentDateRange(days = 30, today = shanghaiToday()) {
  const end = new Date(`${today}T00:00:00Z`);
  if (!Number.isInteger(days) || days < 1 || !validDate(today)) throw new Error('日期范围无效');
  const first = new Date(end);
  first.setUTCDate(first.getUTCDate() - days + 1);
  return {date_from:first.toISOString().slice(0,10), date_to:today};
}

function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value || '')) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0,10) === value;
}

export function dateRangeError(from, to) {
  if (!validDate(from) || !validDate(to)) return '请选择完整、有效的开始和结束日期。';
  if (from > to) return '开始日期不能晚于结束日期。';
  const count = (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86400000 + 1;
  return count > 366 ? '一次最多查看366天，请缩小时间范围。' : '';
}

export function overviewFilters(classId, values) {
  return {
    class_id:String(classId || ''), subject_id:values.subject_id || '',
    q:(values.q || '').trim(), enabled:typeof values.enabled === 'boolean' ? String(values.enabled) : values.enabled || '',
    date_from:values.date_from, date_to:values.date_to,
    sort_by:values.sort_by || 'answered', order:values.order || 'desc'
  };
}

export function overviewQuery(filters, page = 1, pageSize = 20) {
  return new URLSearchParams({
    ...Object.fromEntries(Object.entries(filters).filter(([,value]) => value !== '' && value !== undefined && value !== null)),
    page:String(page), page_size:String(pageSize)
  }).toString();
}

export function overviewExportPayload(filters, ids) {
  const keys = ['class_id','q','subject_id','date_from','date_to','enabled','sort_by','order'];
  const result = Object.fromEntries(Object.entries(filters).filter(([key,value]) => keys.includes(key) && value !== '' && value !== undefined && value !== null));
  if (result.enabled !== undefined) result.enabled = result.enabled === true || result.enabled === 'true';
  if (ids !== undefined) {
    if (!Array.isArray(ids) || !ids.length || ids.length > 500 || new Set(ids).size !== ids.length) throw new Error('请选择1至500名不同学生。');
    result.student_ids = ids;
  }
  return result;
}

export function overviewFilename(className, from, to) {
  const name = String(className || '学生').replace(/[\\/:*?"<>|\u0000-\u001f]/g,'_').replace(/^[.\s]+|[.\s]+$/g,'').slice(0,50) || '学生';
  return `${name}-学习汇总-${from}-${to}.csv`;
}
