const COMMON_FIELDS = ['username', 'name'];
const STUDENT_FIELDS = ['birth_year', 'subject_group_id', 'exam_year', 'grade', 'target'];

export function editableProfileFields(role, serverFields) {
  const fields = [...COMMON_FIELDS, ...(role === 'student' ? STUDENT_FIELDS : [])];
  return Array.isArray(serverFields) ? fields.filter(field => serverFields.includes(field)) : [];
}

export function userEditForm(user) {
  return Object.fromEntries([...COMMON_FIELDS, ...(user.role === 'student' ? STUDENT_FIELDS : [])]
    .map(field => [field, user[field] === null || user[field] === undefined ? '' : String(user[field])]));
}

function text(value, field) {
  if (typeof value !== 'string') throw new Error(`${field}格式无效。`);
  return value.trim();
}

export function userEditPatch(user, form, serverFields, limits = {}) {
  const patch = {}, old = userEditForm(user);
  for (const field of editableProfileFields(user.role, serverFields)) {
    if (!Object.hasOwn(form, field)) continue;
    if (form[field] === old[field]) continue;
    const value = text(form[field], '资料');
    // Unchanged historical years do not have to satisfy today's new-entry range.
    if (value === old[field]) continue;
    if (field === 'username') {
      if (!/^[A-Za-z0-9_.@-]{3,64}$/.test(value)) throw new Error('账号须为3至64位字母、数字或 _ . @ -。');
      patch[field] = value;
    } else if (field === 'name') {
      if (!value || value.length > 50) throw new Error('姓名须为1至50字。');
      patch[field] = value;
    } else if (field === 'grade' || field === 'target') {
      if (value.length > (field === 'grade' ? 40 : 200)) throw new Error(field === 'grade' ? '年级最多40字。' : '学习目标最多200字。');
      patch[field] = value;
    } else if (field === 'subject_group_id') {
      if (!value && user.activated) throw new Error('已激活学生必须保留一个专业。');
      patch[field] = value || null;
    } else {
      if (!value && field === 'birth_year' && !user.activated) {patch[field] = null; continue;}
      if (!/^\d{4}$/.test(value)) throw new Error(field === 'birth_year' ? '请填写有效的四位出生年份。' : '请填写有效的四位备考年份。');
      const year = Number(value), min = limits[`${field}_min`], max = limits[`${field}_max`];
      if (!Number.isInteger(min) || !Number.isInteger(max)) throw new Error('年份校验范围尚未加载，请重新打开编辑。');
      if (year < min || year > max) throw new Error(`${field === 'birth_year' ? '出生年份' : '备考年份'}须为${min}至${max}年。`);
      patch[field] = year;
    }
  }
  return patch;
}

export function userEditOutcome(currentUser, original, updated) {
  const loginChanged = original.username !== updated.username;
  const professionChanged = (original.subject_group_id || null) !== (updated.subject_group_id || null);
  return {
    ownAccount: currentUser.id === updated.id,
    requiresRelogin: loginChanged || professionChanged,
    message: loginChanged ? '资料已保存，该账号需使用新登录账号重新登录。'
      : professionChanged ? '专业已更新，该学生需重新登录后查看新的备考科目。' : '用户资料已保存。'
  };
}
