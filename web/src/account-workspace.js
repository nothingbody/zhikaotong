export function directoryQuery({q = '', page = 1, pageSize = 20, status = 'active'} = {}) {
  return new URLSearchParams({q: q.trim(), page: String(page), page_size: String(pageSize), class_status: status}).toString();
}

export function accountQuery(classId, {q = '', enabled = '', membership = 'all', sort = 'name', order = 'asc', page = 1, pageSize = 20} = {}, admin = false) {
  if (!classId) throw new Error('请先选择班级。');
  const params = new URLSearchParams({class_id: classId, q: q.trim(), membership_status: membership, sort_by: !admin && sort === 'last_login_at' ? 'name' : sort, order, page: String(page), page_size: String(pageSize)});
  if (enabled !== '') params.set('enabled', String(enabled));
  return params.toString();
}

export function staffPath(role, deleted = false) {
  if (!['student', 'teacher', 'admin'].includes(role) || (!deleted && role === 'student')) throw new Error('学生账号请按班级加载。');
  const query = new URLSearchParams({role});
  if (deleted) query.set('deleted', 'true');
  return `/management/users?${query}`;
}

export function parseCSV(text) {
  const rows = []; let row = [], cell = '', quoted = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') { if (quoted && text[i + 1] === '"') { cell += '"'; i++; } else quoted = !quoted; }
    else if (c === ',' && !quoted) { row.push(cell); cell = ''; }
    else if ((c === '\n' || c === '\r') && !quoted) { if (c === '\r' && text[i + 1] === '\n') i++; row.push(cell); if (row.some(x => x.trim())) rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (quoted) throw new Error('CSV 双引号未闭合。');
  row.push(cell); if (row.some(x => x.trim())) rows.push(row);
  return rows;
}

export function studentImportRows(text) {
  const parsed = parseCSV(text);
  if (/^(username|账号|学号)$/i.test(parsed[0]?.[0]?.replace(/^\uFEFF/, '').trim() || '')) parsed.shift();
  if (!parsed.length) throw new Error('请上传或粘贴至少一行学生信息。');
  if (parsed.some(row => row.length !== 3)) throw new Error('每行必须恰好包含账号、姓名、初始密码三列。');
  return parsed.map(([username, name, password]) => ({username: username.trim(), name: name.trim(), password}));
}

export function studentRowsCSV(rows) {
  const cell = value => `"${String(value ?? '').replaceAll('"', '""')}"`;
  return ['username,name,password', ...rows.map(row => [row.username, row.name, row.password].map(cell).join(','))].join('\n');
}

export function creationClass(selectedClass, classes, teacher) {
  if (selectedClass && selectedClass.id !== 'unassigned' && !selectedClass.archived && classes.some(row => row.id === selectedClass.id && !row.archived)) return selectedClass.id;
  return teacher ? classes.find(row => !row.archived)?.id || '' : '';
}
