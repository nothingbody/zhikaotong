"""Administrator profile edits preserve user identity and learning history."""
import re
import sqlite3
import unicodedata

from fastapi import Depends

COMMON_FIELDS = frozenset(('username', 'name', 'enabled'))
STUDENT_FIELDS = frozenset(('birth_year', 'subject_group_id', 'exam_year', 'grade', 'target'))


def profile_limits(core):
    year = core.now().year
    return {'birth_year_min': 1900, 'birth_year_max': year - 14,
            'exam_year_min': year, 'exam_year_max': year + 10}


def _text(core, value, label, maximum, required=False, multiline=False):
    if not isinstance(value, str):
        core.fail(422, label + '须为文本')
    value = value.strip()
    if len(value) > maximum or (required and not value):
        core.fail(422, label + (f'须为1至{maximum}字' if required else f'不能超过{maximum}字'))
    if any(unicodedata.category(char).startswith('C') and not (multiline and char in '\r\n\t') for char in value):
        core.fail(422, label + '包含无效控制字符')
    return value


def _current_classes(conn, core, user_id):
    return core.rows(conn, '''SELECT c.name,g.subject_ids FROM memberships m
      JOIN classes c ON c.id=m.class_id JOIN groups g ON g.id=c.subject_group_id
      WHERE m.user_id=? AND m.status IN ('active','pending_confirmation','pending_approval')
      AND c.archived=0 AND c.deleted_at IS NULL''', (user_id,))


def update_profile(conn, core, actor, target, data):
    """Called inside user_scope's IMMEDIATE transaction; all changes are atomic."""
    if not data:
        core.fail(422, '请至少填写一项需要修改的信息')
    if actor['role'] != 'admin':
        if set(data) - {'enabled'}:
            core.fail(403, '仅管理员可编辑用户基础资料')
    else:
        allowed = COMMON_FIELDS | (STUDENT_FIELDS if target['role'] == 'student' else frozenset())
        if set(data) - allowed:
            core.fail(422, '包含不可编辑字段，角色、激活、协议和密码请使用对应管理功能')
    values = {}
    limits = profile_limits(core)
    if 'username' in data:
        username = data['username']
        if not isinstance(username, str) or not re.fullmatch(r'[A-Za-z0-9_.@-]{3,64}', username):
            core.fail(422, '账号须为3至64位字母、数字或 _.@-，且全局唯一')
        if core.one(conn, 'SELECT id FROM users WHERE username=? AND id<>?', (username, target['id'])):
            core.fail(409, '账号或学号已存在，包括已删除账号占用的账号')
        values['username'] = username
    if 'name' in data:
        values['name'] = _text(core, data['name'], '姓名', 50, required=True)
    if 'enabled' in data:
        if not isinstance(data['enabled'], bool):
            core.fail(422, '启用状态须为布尔值')
        values['enabled'] = int(data['enabled'])
    if 'birth_year' in data:
        year = data['birth_year']
        if year is None:
            if target['activated']:
                core.fail(422, '已激活学生的出生年份不能为空')
        elif not isinstance(year, int) or isinstance(year, bool) or not limits['birth_year_min'] <= year <= limits['birth_year_max']:
            core.fail(422, '出生年份无效，学生须满14周岁')
        values['birth_year'] = year
    if 'exam_year' in data:
        year = data['exam_year']
        if not isinstance(year, int) or isinstance(year, bool) or not limits['exam_year_min'] <= year <= limits['exam_year_max']:
            core.fail(422, '考试年份无效')
        values['exam_year'] = year
    for field, label, maximum in (('grade', '年级', 40), ('target', '学习目标', 200)):
        if field in data:
            values[field] = _text(core, data[field], label, maximum, multiline=field == 'target')
    if 'subject_group_id' in data:
        group_id = data['subject_group_id']
        if group_id is not None and (not isinstance(group_id, str) or not 1 <= len(group_id) <= 128):
            core.fail(422, '请选择有效的专业')
        if group_id is None:
            if target['activated']:
                core.fail(422, '已激活学生的专业不能为空')
            if _current_classes(conn, core, target['id']):
                core.fail(409, '学生仍有当前班级，不能清空专业，请先在班级管理调整成员')
        elif group_id != target['subject_group_id']:
            from .professions import ensure_enabled_group
            group = ensure_enabled_group(conn, core, group_id)
            available = set(core.json.loads(group['subject_ids']))
            incompatible = [row for row in _current_classes(conn, core, target['id'])
                            if not set(core.json.loads(row['subject_ids'])).issubset(available)]
            if incompatible:
                core.fail(409, '所选专业与当前班级科目范围不兼容，请先在班级管理调整成员后再修改专业')
        values['subject_group_id'] = group_id
    changed = {key: value for key, value in values.items() if value != target[key]}
    if 'enabled' in changed:
        if changed['enabled']:
            group_id = values.get('subject_group_id', target['subject_group_id'])
            if target['role'] == 'student' and group_id:
                from .professions import ensure_enabled_group
                ensure_enabled_group(conn, core, group_id)
        else:
            if target['id'] == actor['id']:
                core.fail(409, '不能禁用当前账号')
            if target['role'] == 'admin' and conn.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND enabled=1 AND deleted_at IS NULL").fetchone()[0] <= 1:
                core.fail(409, '至少保留一个管理员')
    if changed:
        try:
            conn.execute('UPDATE users SET ' + ','.join(key + '=?' for key in changed) + ' WHERE id=?',
                         [*changed.values(), target['id']])
        except sqlite3.IntegrityError:
            core.fail(409, '账号或学号已存在，请刷新后重试')
        revoke_reasons = [field for field in ('username', 'subject_group_id') if field in changed]
        if changed.get('enabled') == 0:
            revoke_reasons.append('disabled')
        if revoke_reasons:
            conn.execute('UPDATE sessions SET revoked=1 WHERE user_id=?', (target['id'],))
        if 'enabled' in changed:
            core.audit(conn, actor['id'], 'user.enable' if changed['enabled'] else 'user.disable', target['id'])
        profile_fields = sorted(set(changed) - {'enabled'})
        if profile_fields:
            core.audit(conn, actor['id'], 'user.profile.update', target['id'],
                       core.canonical({'fields': profile_fields, 'sessions_revoked_for': revoke_reasons}))
    result = core.one(conn, 'SELECT * FROM users WHERE id=?', (target['id'],))
    return core.public_user(result) if actor['role'] == 'admin' else core.roster_user(result)


def register_user_profiles(app, core):
    @app.get('/api/management/users/{user_id}')
    def editable_user(user_id: str, actor=Depends(core.admin)):
        with core.db() as conn:
            target = core.user_scope(conn, user_id, actor)
            group = core.one(conn, 'SELECT name FROM groups WHERE id=?', (target['subject_group_id'],))
            value = {**core.public_user(target), 'subject_group_name': group['name'] if group else None}
            core.audit(conn, actor['id'], 'user.profile.edit.view', target['id'], '账号管理读取可编辑资料')
            return {'user': value, 'editable_fields': sorted(COMMON_FIELDS | (STUDENT_FIELDS if target['role'] == 'student' else frozenset())),
                    'limits': profile_limits(core)}
