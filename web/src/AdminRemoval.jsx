import React, { useState } from 'react';
import { api, post } from './api';
import './admin-removal.css';

export function RemovalViews({ kind, deleted, onChange }) {
  const noun = kind === 'users' ? '账号' : '班级';
  return <div className="removal-view-switch">
    <div className="tabs" aria-label={`${noun}列表范围`}>
      <button type="button" aria-pressed={!deleted} className={!deleted ? 'active' : ''} onClick={() => onChange(false)}>正常{noun}</button>
      <button type="button" aria-pressed={deleted} className={deleted ? 'active' : ''} onClick={() => onChange(true)}>已删除{noun}</button>
    </div>
    <span>{deleted ? '删除记录可在条件满足时恢复；原有历史记录保留。' : '管理员可删除误建或不再使用的账号、班级，并从已删除列表恢复。'}</span>
  </div>;
}

export default function AdminRemovalModal({ kind, target, restore = false, ui, onClose, onDone }) {
  const { Modal, Field, Button, FormError } = ui;
  const [confirm, setConfirm] = useState(''), [reason, setReason] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const account = kind === 'users', noun = account ? '账号' : '班级';
  const expected = account ? target.username : target.name;
  const close = () => { if (!busy) onClose(); };
  const submit = async event => {
    event.preventDefault();
    if (!reason.trim() || (!restore && confirm.trim() !== expected)) return;
    setBusy(true); setError('');
    try {
      const path = `/management/${kind}/${target.id}`;
      const result = restore ? await post(path + '/restore', { reason: reason.trim() }) : await api(path, { method: 'DELETE', body: { confirm: confirm.trim(), reason: reason.trim() } });
      await onDone(result);
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  };
  return <Modal title={`${restore ? '恢复' : '删除'}${noun}`} description={account ? `${target.name || target.username} · ${target.username}` : target.name} onClose={close}>
    <form className="admin-removal-form" onSubmit={submit}>
      <div className={`removal-explanation ${restore ? '' : 'deleting'}`}>
        {restore ? account ? <p>恢复后使用原账号登录，启用或禁用状态恢复为删除前状态。此前的登录凭证已失效，需要重新登录。</p> : <p>恢复后回到删除前的教学或归档状态。教师账号与科目组必须有效，原有成员关系和任务成绩会保留。</p> : account ? <><p>删除后账号移至“已删除账号”，立即禁用并退出全部设备。历史任务、成绩和审计记录会保留，可在条件满足时恢复。</p><p>当前管理员不能删除自己；教师名下仍有班级时，需先处理这些班级。</p></> : <><p>删除后班级移至“已删除班级”，停止入班和布置练习，未完成练习不能继续。原成员关系与历史成绩会保留，可恢复。</p><p>删除班级不会删除其中的学生账号。</p></>}
      </div>
      {!restore && <Field label={`输入完整${account ? '账号' : '班级名称'}确认`} hint={`请输入：${expected}`}><input autoComplete="off" required disabled={busy} value={confirm} onChange={event => setConfirm(event.target.value)} maxLength={account ? 64 : 100} /></Field>}
      <Field label={`${restore ? '恢复' : '删除'}原因`} hint="原因会记录到审计日志，限500字。"><textarea required maxLength={500} rows={3} disabled={busy} value={reason} onChange={event => setReason(event.target.value)} /></Field>
      <FormError error={error} />
      <div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={close}>取消</Button><Button variant={restore ? 'primary' : 'danger'} disabled={busy || !reason.trim() || (!restore && confirm.trim() !== expected)}>{busy ? '正在处理…' : `${restore ? '确认恢复' : '确认删除'}${noun}`}</Button></div>
    </form>
  </Modal>;
}
