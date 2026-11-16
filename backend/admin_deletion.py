"""Administrator-only reversible removal, distinct from student anonymization."""
from fastapi import Body, Depends


SCHEMA = '''
CREATE TABLE IF NOT EXISTS admin_user_deletions(
 user_id TEXT PRIMARY KEY REFERENCES users(id),deleted_at TEXT NOT NULL,
 previous_enabled INTEGER NOT NULL,actor_id TEXT NOT NULL,reason TEXT NOT NULL);
'''


def register_admin_deletion(app, core):
    core.SCHEMA += SCHEMA

    def request_reason(data, confirmation=None):
        allowed = {'reason'} if confirmation is None else {'confirm', 'reason'}
        if set(data) - allowed:
            core.fail(422, '包含不支持的删除或恢复字段')
        reason = data.get('reason')
        if not isinstance(reason, str) or not 1 <= len(reason.strip()) <= 500:
            core.fail(422, '请填写1至500字的操作原因')
        if confirmation is not None and (not isinstance(data.get('confirm'), str) or data['confirm'].strip() != confirmation):
            core.fail(422, '确认内容须与完整账号或班级名称一致')
        return reason.strip()

    @app.delete('/api/management/users/{user_id}')
    def delete_user(user_id: str, data: dict = Body(...), actor=Depends(core.admin)):
        core.identifier(user_id)
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            target = core.one(conn, 'SELECT * FROM users WHERE id=?', (user_id,))
            if not target:
                core.fail(404, '账号不存在')
            reason = request_reason(data, target['username'])
            if user_id == actor['id']:
                core.fail(409, '不能删除当前登录的管理员账号')
            old = core.one(conn, 'SELECT * FROM admin_user_deletions WHERE user_id=?', (user_id,))
            if target['deleted_at']:
                if old and old['deleted_at'] == target['deleted_at'] and target['password_hash']:
                    return {'ok': True, 'id': user_id, 'deleted': True}
                core.fail(409, '该账号已完成注销，不能作为可恢复账号删除')
            if target['role'] == 'admin' and target['enabled']:
                count = conn.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND enabled=1 AND deleted_at IS NULL").fetchone()[0]
                if count <= 1:
                    core.fail(409, '至少保留一个有效管理员')
            if target['role'] == 'teacher' and core.one(conn, 'SELECT id FROM classes WHERE teacher_id=? AND deleted_at IS NULL LIMIT 1', (user_id,)):
                core.fail(409, '该教师仍有未删除班级，请先处理名下班级（包括归档班级）')
            deleted_at = core.iso()
            conn.execute('INSERT INTO admin_user_deletions(user_id,deleted_at,previous_enabled,actor_id,reason) VALUES(?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET deleted_at=excluded.deleted_at,previous_enabled=excluded.previous_enabled,actor_id=excluded.actor_id,reason=excluded.reason',
                         (user_id, deleted_at, target['enabled'], actor['id'], reason))
            conn.execute('UPDATE users SET deleted_at=?,enabled=0 WHERE id=?', (deleted_at, user_id))
            conn.execute('UPDATE sessions SET revoked=1 WHERE user_id=?', (user_id,))
            core.audit(conn, actor['id'], 'user.delete', user_id, reason)
            return {'ok': True, 'id': user_id, 'deleted': True}

    @app.post('/api/management/users/{user_id}/restore')
    def restore_user(user_id: str, data: dict = Body(...), actor=Depends(core.admin)):
        core.identifier(user_id)
        reason = request_reason(data)
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            target = core.one(conn, 'SELECT * FROM users WHERE id=?', (user_id,))
            marker = core.one(conn, 'SELECT * FROM admin_user_deletions WHERE user_id=?', (user_id,))
            if not target:
                core.fail(404, '账号不存在')
            if not marker or not target['deleted_at'] or target['deleted_at'] != marker['deleted_at'] or not target['password_hash'] or core.one(conn, "SELECT user_id FROM deletions WHERE user_id=? AND status='executed'", (user_id,)):
                core.fail(409, '该账号不是可恢复删除状态，已完成注销的账号不能恢复')
            enabled = bool(marker['previous_enabled'])
            if enabled and target['role'] == 'student' and target['subject_group_id']:
                if not core.one(conn, 'SELECT id FROM groups WHERE id=? AND enabled=1', (target['subject_group_id'],)):
                    core.fail(409, '学生原专业已停用，请先启用专业再恢复该账号')
            conn.execute('UPDATE users SET deleted_at=NULL,enabled=? WHERE id=?', (int(enabled), user_id))
            conn.execute('DELETE FROM admin_user_deletions WHERE user_id=?', (user_id,))
            # Revoked sessions are deliberately not revived by account restoration.
            core.audit(conn, actor['id'], 'user.restore', user_id, reason)
            return {'ok': True, 'id': user_id, 'deleted': False, 'enabled': enabled}

    @app.delete('/api/management/classes/{class_id}')
    def delete_class(class_id: str, data: dict = Body(...), actor=Depends(core.admin)):
        core.identifier(class_id)
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            classroom = core.one(conn, 'SELECT * FROM classes WHERE id=?', (class_id,))
            if not classroom:
                core.fail(404, '班级不存在')
            reason = request_reason(data, classroom['name'])
            if classroom['deleted_at']:
                return {'ok': True, 'id': class_id, 'deleted': True}
            conn.execute('UPDATE classes SET deleted_at=?,deleted_previous_archived=archived,archived=1 WHERE id=?', (core.iso(), class_id))
            core.audit(conn, actor['id'], 'class.delete', class_id, reason)
            return {'ok': True, 'id': class_id, 'deleted': True}

    @app.post('/api/management/classes/{class_id}/restore')
    def restore_class(class_id: str, data: dict = Body(...), actor=Depends(core.admin)):
        core.identifier(class_id)
        reason = request_reason(data)
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            classroom = core.one(conn, 'SELECT * FROM classes WHERE id=?', (class_id,))
            if not classroom:
                core.fail(404, '班级不存在')
            if not classroom['deleted_at']:
                core.fail(409, '班级未处于已删除状态')
            if not core.one(conn, "SELECT id FROM users WHERE id=? AND role='teacher' AND enabled=1 AND deleted_at IS NULL", (classroom['teacher_id'],)):
                core.fail(409, '请先恢复并启用该班级的任课教师')
            if not core.one(conn, 'SELECT id FROM groups WHERE id=? AND enabled=1', (classroom['subject_group_id'],)):
                core.fail(409, '班级科目组已停用，请先启用科目组')
            archived = bool(classroom['deleted_previous_archived'])
            conn.execute('UPDATE classes SET deleted_at=NULL,archived=?,deleted_previous_archived=NULL WHERE id=?', (int(archived), class_id))
            core.audit(conn, actor['id'], 'class.restore', class_id, reason)
            return {'ok': True, 'id': class_id, 'deleted': False, 'archived': archived}
