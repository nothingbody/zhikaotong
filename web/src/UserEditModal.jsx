import React, {useEffect, useRef, useState} from 'react';
import {api, patch} from './api';
import {editableProfileFields, userEditForm, userEditPatch} from './user-edit';
import './user-edit.css';

const ROLE_NAMES = {student:'学生', teacher:'教师', admin:'管理员'};

export default function UserEditModal({target, onClose, onSaved, ui}) {
  const {Modal, Field, Button, Loading, FormError} = ui;
  const [resource,setResource] = useState({loading:true,error:'',profile:null,groups:[]});
  const [form,setForm] = useState({}),[error,setError] = useState(''),[busy,setBusy] = useState(false),[retry,setRetry] = useState(0);
  const mounted = useRef(false),saving = useRef(false);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  useEffect(()=>{
    let current=true;
    setResource({loading:true,error:'',profile:null,groups:[]});setError('');
    const load=async()=>{
      const profile=await api(`/management/users/${encodeURIComponent(target.id)}`);
      if(!profile?.user||profile.user.id!==target.id||!Array.isArray(profile.editable_fields))throw new Error('用户资料不完整，请重新加载。');
      if(!current)return;
      const groups=profile.user.role==='student'?await api('/management/groups'):[];
      if(!current)return;
      if(!Array.isArray(groups))throw new Error('专业目录获取失败，请重试。');
      setForm(userEditForm(profile.user));setResource({loading:false,error:'',profile,groups});
    };
    load().catch(failure=>{if(current)setResource({loading:false,error:failure.message,profile:null,groups:[]});});
    return()=>{current=false;};
  },[target.id,retry]);
  const close=()=>{if(!saving.current)onClose();};
  const profile=resource.profile,account=profile?.user,student=account?.role==='student';
  const fields=editableProfileFields(account?.role,profile?.editable_fields),can=field=>fields.includes(field);
  const change=field=>event=>setForm(previous=>({...previous,[field]:event.target.value}));
  const submit=async event=>{
    event.preventDefault();if(saving.current||!account)return;
    setError('');
    try{
      const changes=userEditPatch(account,form,profile.editable_fields,profile.limits);
      if(!Object.keys(changes).length){setError('尚未修改资料。');return;}
      saving.current=true;setBusy(true);
      const updated=await patch(`/management/users/${encodeURIComponent(account.id)}`,changes);
      if(!mounted.current)return;
      if(!updated||updated.id!==account.id)throw new Error('保存结果未返回有效用户，请刷新列表后核对。');
      onSaved(updated,account);
    }catch(failure){if(mounted.current)setError(failure.message);}
    finally{saving.current=false;if(mounted.current)setBusy(false);}
  };
  const currentGroup=resource.groups.find(group=>group.id===account?.subject_group_id);
  const groups=resource.groups.filter(group=>group.enabled!==false||group.id===account?.subject_group_id);
  const limits=profile?.limits||{},professionChanged=student&&(form.subject_group_id||null)!==(account.subject_group_id||null);
  return <Modal title="编辑用户资料" description="修改后保留原有学习记录，账号角色保持不变。" onClose={close}>
    {resource.loading?<Loading/>:resource.error?<div className="user-edit-load-error" role="alert"><p>{resource.error}</p><Button variant="secondary" type="button" onClick={()=>setRetry(value=>value+1)}>重新加载资料</Button></div>:account&&<form onSubmit={submit} noValidate className="user-edit-form">
      <div className="user-edit-identity"><span className={`role-tag ${account.role}`}>{ROLE_NAMES[account.role]||account.role}</span><span>{account.activated?'已激活':'待激活'} · {account.enabled?'账号正常':'账号已禁用'}</span></div>
      <div className="form-grid"><Field label="登录账号 / 学号" hint="更改后，该用户需要使用新账号重新登录。"><input aria-label="编辑登录账号" autoComplete="off" required minLength={3} maxLength={64} pattern="[A-Za-z0-9_.@\-]{3,64}" disabled={busy||!can('username')} value={form.username||''} onChange={change('username')}/></Field><Field label="姓名"><input aria-label="编辑姓名" required maxLength={50} disabled={busy||!can('name')} value={form.name||''} onChange={change('name')}/></Field></div>
      {student&&<><div className="form-grid"><Field label="出生年份" hint={limits.birth_year_max?`有效范围：${limits.birth_year_min}—${limits.birth_year_max}年。`:null}><input aria-label="编辑出生年份" type="number" inputMode="numeric" step="1" min={limits.birth_year_min} max={limits.birth_year_max} required={account.activated} disabled={busy||!can('birth_year')} value={form.birth_year||''} onChange={change('birth_year')}/></Field><Field label="备考年份"><input aria-label="编辑备考年份" type="number" inputMode="numeric" step="1" min={limits.exam_year_min} max={limits.exam_year_max} disabled={busy||!can('exam_year')} value={form.exam_year||''} onChange={change('exam_year')}/></Field></div>
        <Field label="学生专业" hint="班级关系请在班级管理调整。"><select aria-label="编辑学生专业" required={account.activated} disabled={busy||!can('subject_group_id')} value={form.subject_group_id||''} onChange={change('subject_group_id')}><option value="" disabled={account.activated}>尚未分配</option>{!currentGroup&&account.subject_group_id&&<option value={account.subject_group_id} disabled>{account.subject_group_name||'当前专业'}（当前目录不可用）</option>}{groups.map(group=><option key={group.id} value={group.id} disabled={group.enabled===false}>{group.name}{group.enabled===false?'（已停用，保留原分配）':''}</option>)}</select></Field>
        {professionChanged&&<p className="user-edit-note" role="status">更改前请先让学生联网同步作答；更改后需要重新登录。当前班级须与新专业兼容。</p>}
        <Field label="年级"><input aria-label="编辑年级" maxLength={40} disabled={busy||!can('grade')} value={form.grade||''} placeholder="例如：高三" onChange={change('grade')}/></Field><Field label="学习目标"><textarea aria-label="编辑学习目标" rows={3} maxLength={200} disabled={busy||!can('target')} value={form.target||''} onChange={change('target')}/></Field>
      </>}
      <p className="user-edit-note">角色、激活与协议状态为只读；修改密码请使用列表中的“重置密码”。</p><FormError error={error}/><div className="form-actions"><Button variant="secondary" type="button" disabled={busy} onClick={close}>取消</Button><Button type="submit" disabled={busy||resource.loading}>{busy?'正在保存…':'保存资料'}</Button></div>
    </form>}
  </Modal>;
}
