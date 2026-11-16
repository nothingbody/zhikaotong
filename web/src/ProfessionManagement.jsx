import React, { useState } from 'react';
import { api, post, patch } from './api';
import './profession-management.css';

export default function ProfessionManagement({ notify, onChanged, ui }) {
  const { Button, Field, Modal, Badge, Table, FormError, DataState, useData, SearchInput } = ui;
  const state = useData(() => api('/management/professions'), []);
  const [search, setSearch] = useState('');
  const [form, setForm] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const data = state.data || { items: [], subjects: [] };
  const groups = data.items.filter(group => `${group.name} ${(group.subjects || []).map(subject => subject.name).join(' ')}`.toLowerCase().includes(search.trim().toLowerCase()));
  const open = group => {
    setError('');
    setForm(group ? { ...group, subject_ids: [...group.subject_ids] } : { name: '', enabled: false, subject_ids: [] });
  };
  const save = async event => {
    event.preventDefault();
    if (busy) return;
    if (!form.name.trim()) return setError('请填写专业名称。');
    if (form.enabled && !form.subject_ids.length) return setError('启用专业前请至少选择一个真实科目，或先保持停用。');
    setBusy(true); setError('');
    try {
      const body = { name: form.name.trim(), enabled: form.enabled, subject_ids: form.subject_ids };
      if (form.id) await patch(`/management/groups/${form.id}`, body);
      else await post('/management/groups', body);
      setForm(null);
      notify('专业配置已保存，APP联网刷新后加载对应科目。');
      await state.reload();
      if (onChanged) await onChanged();
    } catch (failure) { setError(failure.message); }
    finally { setBusy(false); }
  };
  return <div className="profession-management">
    <div className="profession-intro">
      <div><h2>专业配置</h2><p>专业关联学生可见的科目，公共课可以供多个专业共用。题库管理继续按“科目 → 题目”查看。</p></div>
      <Button icon="plus" onClick={() => open(null)}>新增专业</Button>
    </div>
    <div className="profession-summary" aria-label="专业配置概览">
      <div><strong>{data.items.length}</strong><span>已配置专业</span></div>
      <div><strong>{data.items.filter(group => group.enabled).length}</strong><span>启用专业</span></div>
      <div><strong>{data.subjects.length}</strong><span>独立科目</span></div>
      <div><strong>{data.subjects.filter(subject => subject.profession_count > 1).length}</strong><span>多专业共享科目</span></div>
    </div>
    <div className="profession-toolbar"><SearchInput value={search} onChange={setSearch} placeholder="搜索专业或关联科目"/><button className="text-btn" onClick={state.reload}>刷新配置</button></div>
    <DataState state={state}><Table headers={['专业名称', '关联科目', '可练题量', '账号与班级', '状态', '操作']} empty={!groups.length}>
      {groups.map(group => <tr key={group.id}>
        <td><strong>{group.name}</strong><small className="profession-subtext">{group.subject_count}个科目</small></td>
        <td><div className="profession-subject-tags">{group.subjects.map(subject => <span key={subject.id}>{subject.name}<small>{subject.published_count}题</small></span>)}</div>{!group.subjects.length && <span className="subtle-text">尚未配置科目</span>}</td>
        <td><strong>{group.published_count}</strong><small className="profession-subtext">当前已发布题目</small></td>
        <td><span>{group.student_count}名学生 · {group.class_count}个班级</span><small className="profession-subtext">启用学生{group.active_student_count} · 未归档班级{group.active_class_count}</small></td>
        <td><Badge status={group.enabled ? 'active' : 'offline'}>{group.enabled ? '启用' : '停用'}</Badge></td>
        <td><button className="text-btn" onClick={() => open(group)}>编辑专业</button></td>
      </tr>)}
    </Table></DataState>
    <p className="profession-note">新增专业不会复制公共课题目，也不会创建演示题。先在科目目录建立真实科目、导入题目，再关联到对应专业；没有题目的科目会如实显示0题。</p>
    {form && <Modal wide title={form.id ? `编辑专业 · ${form.name}` : '新增专业'} description="关联科目决定学习范围。已有学生或班级引用时，不能移除科目；仍有启用学生或未归档班级时不能停用。" onClose={() => { if (!busy) setForm(null); }}>
      <form onSubmit={save}>
        <div className="form-grid"><Field label="专业名称"><input autoFocus required maxLength={80} value={form.name} onChange={event => setForm({ ...form, name: event.target.value })} placeholder="例如：学校实际开设的专业"/></Field>
          <Field label="启用状态"><select disabled={busy} value={String(form.enabled)} onChange={event => setForm({ ...form, enabled: event.target.value === 'true' })}><option value="false">停用／预备配置</option><option value="true">启用</option></select></Field></div>
        <fieldset className="profession-subject-picker"><legend>关联科目 · 已选{form.subject_ids.length}科</legend>
          <p>可以选择已有公共课，不需要为每个专业重复创建“语文、数学”等科目。</p>
          <div>{data.subjects.map(subject => <label key={subject.id}><input type="checkbox" disabled={busy} checked={form.subject_ids.includes(subject.id)} onChange={() => setForm({ ...form, subject_ids: form.subject_ids.includes(subject.id) ? form.subject_ids.filter(id => id !== subject.id) : [...form.subject_ids, subject.id] })}/><span><strong>{subject.name}</strong><small>{subject.published_count}题{subject.profession_count > 1 ? ` · 已有${subject.profession_count}个专业共享` : ''}</small></span></label>)}</div>
          {!data.subjects.length && <p>请先建立科目，再配置本专业。</p>}
        </fieldset>
        {form.id && <p className="profession-note">当前关联{form.student_count}名学生、{form.class_count}个班级。系统会检查最新引用，历史学习记录和成绩不会因编辑名称而清除。</p>}
        <FormError error={error}/><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={() => setForm(null)}>取消</Button><Button disabled={busy}>{busy ? '保存中…' : '保存专业配置'}</Button></div>
      </form>
    </Modal>}
  </div>;
}
