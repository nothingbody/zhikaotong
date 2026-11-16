import React, {useEffect, useRef, useState} from 'react';
import {api, post, patch} from './api';
import AdminRemovalModal from './AdminRemoval';
import StudentDetails from './StudentDetails';
import StudentOverview from './StudentOverview';
import UserEditModal from './UserEditModal';
import {userEditOutcome} from './user-edit';
import {directoryQuery, accountQuery, staffPath, studentImportRows, studentRowsCSV, creationClass} from './account-workspace';
import './student-workspace.css';

function useRemote(path, revision = 0, enabled = true) {
  const [state, setState] = useState({key: null, data: null, loading: false, error: ''});
  const [retry, setRetry] = useState(0);
  const key = path ? `${path}|${revision}|${retry}` : null;
  useEffect(() => {
    if (!enabled || !path) return;
    let current = true;
    setState({key, data: null, loading: true, error: ''});
    api(path).then(data => {if (current) setState({key, data, loading: false, error: ''});}, failure => {if (current) setState({key, data: null, loading: false, error: failure.message});});
    return () => {current = false;};
  }, [key, enabled]);
  return {...(state.key === key ? state : {data: null, loading: Boolean(enabled && path), error: ''}), reload: () => setRetry(value => value + 1)};
}

function useDebounced(value) {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {const timer = setTimeout(() => setDebounced(value), 300); return () => clearTimeout(timer);}, [value]);
  return debounced;
}

function LoadState({state, ui, children}) {
  const {Loading, Button, Icon} = ui;
  if (state.loading) return <Loading/>;
  if (state.error) return <div className="error-panel" role="alert"><Icon name="message"/><span>{state.error}</span><Button variant="secondary" onClick={state.reload}>重试</Button></div>;
  return children;
}

function Pagination({data, page, pageSize, onPage, onSize, loading, ui, noun = '项'}) {
  const {Button} = ui;
  const total = Number(data?.total || 0), pages = Math.max(1, Number(data?.pages || 1));
  return <nav className="student-workspace-pagination" aria-label="结果分页"><span>共 {total.toLocaleString('zh-CN')} {noun} · 第 {page} / {pages} 页</span><div>{onSize && <label>每页 <select aria-label="每页数量" value={pageSize} disabled={loading} onChange={event => onSize(Number(event.target.value))}>{[20, 50, 100].map(size => <option key={size} value={size}>{size}</option>)}</select></label>}<Button variant="secondary" disabled={loading || page <= 1} onClick={() => onPage(page - 1)}>上一页</Button><Button variant="secondary" disabled={loading || page >= pages} onClick={() => onPage(page + 1)}>下一页</Button></div></nav>;
}

function ClassDirectory({admin, mode, onSelect, revision, ui}) {
  const {Icon, Button, Empty, SearchInput} = ui;
  const [q, setQ] = useState(''), [status, setStatus] = useState('active'), [page, setPage] = useState(1), [pageSize, setPageSize] = useState(20);
  const search = useDebounced(q);
  const state = useRemote(`/management/student-classes?${directoryQuery({q: search, status: admin ? status : 'active', page, pageSize})}`, revision);
  const data = state.data, items = data?.items || [];
  useEffect(() => {if (data && page > Math.max(1, data.pages)) setPage(Math.max(1, data.pages));}, [data, page]);
  const card = (row, unassigned = false) => <button type="button" className={`student-class-card ${unassigned ? 'unassigned' : ''}`} key={row.id} onClick={() => onSelect(row)}>
    <div className="student-class-card-top"><span className="student-class-symbol"><Icon name={unassigned ? 'contact' : 'school'} size={23}/></span><span className={`badge ${row.archived ? 'gray' : unassigned ? 'blue' : 'green'}`}>{row.archived ? '已归档' : unassigned ? '学校账号' : '教学中'}</span></div>
    <h2>{row.name}</h2><p>{unassigned ? '暂无当前班级关联，可查看并分配学生账号。' : row.term || '未设置学期'}</p>
    {!unassigned && <div className="student-class-description"><span>{row.teacher_name || '未分配教师'}</span><span>{row.subject_group_name || '未设置专业'}</span></div>}
    <div className="student-class-counts"><div><strong>{Number(row.student_count || 0).toLocaleString('zh-CN')}</strong><span>学生账号</span></div>{!unassigned && <><div><strong>{Number(row.formal_student_count || 0).toLocaleString('zh-CN')}</strong><span>正式成员</span></div><div><strong>{Number(row.pending_student_count || 0).toLocaleString('zh-CN')}</strong><span>待确认 / 授权</span></div></>}</div>
    <div className="student-class-entry">{mode === 'overview' ? '查看集中学情' : '查看学生信息'}<Icon name="arrow" size={17}/></div>
  </button>;
  return <section className="student-directory"><div className="panel student-directory-toolbar"><div><h2>先选择班级</h2><p>{mode === 'overview' ? '进入班级后，统一筛选、比较并导出学生学习情况。' : '按班级分页加载学生，快速找到需要管理的账号。'}</p></div><div className="student-directory-filters"><SearchInput value={q} onChange={value => {setQ(value); setPage(1);}} placeholder="搜索班级或教师"/>{admin && <select aria-label="班级状态" value={status} onChange={event => {setStatus(event.target.value); setPage(1);}}><option value="active">教学中班级</option><option value="archived">已归档班级</option><option value="all">全部班级</option></select>}<Button variant="secondary" icon="refresh" onClick={state.reload} disabled={state.loading}>刷新</Button></div></div>
    <LoadState state={state} ui={ui}><div className="student-directory-grid">{items.map(row => card(row))}{admin && data?.unassigned && page === 1 && card(data.unassigned, true)}</div>{!items.length && !(admin && data?.unassigned && page === 1) && <section className="panel"><Empty text={search ? '没有匹配的班级' : '暂无可查看的班级'} detail={search ? '请调整班级名称、教师或状态筛选。' : admin ? '可先创建班级，或在未分班学生中管理学校账号。' : '这里只展示你负责的教学中班级。'}/></section>}</LoadState>
    <Pagination data={data} page={page} pageSize={pageSize} onPage={setPage} onSize={size => {setPageSize(size); setPage(1);}} loading={state.loading} ui={ui} noun="个班级"/>
  </section>;
}

const ROLE_NAMES = {student: '学生', teacher: '教师', admin: '管理员'};

function AccountsTable({rows, admin, deleted = false, student = false, actions, ui}) {
  const {Badge, Empty, date} = ui;
  const headers = ['姓名 / 账号', ...(student ? ['班级身份'] : ['角色']), ...(admin && student && !deleted ? ['专业'] : []), '账号状态', ...(admin ? [deleted ? '删除时间' : '激活情况'] : []), '开通时间', ...(admin && student && !deleted ? ['最近登录'] : []), '操作'];
  return <div className="data-table"><div className="table-wrap"><table><thead><tr>{headers.map(header => <th key={header}>{header}</th>)}</tr></thead><tbody>{rows.map(row => <tr key={row.id}>
    <td><div className="name-cell"><span className="avatar small">{(row.name || row.username || '?').slice(0, 1)}</span><div><strong>{row.name || '未填写姓名'}</strong><small>{row.username}</small></div></div></td>
    <td>{student ? row.membership_status === 'unassigned' ? <span className="subtle-text">未分班</span> : <Badge status={row.membership_status === 'active' && row.visibility_confirmed ? 'active' : 'pending_confirmation'}>{row.membership_status === 'active' && row.visibility_confirmed ? '正式成员' : row.membership_status === 'pending_approval' ? '待教师审批' : '待确认 / 授权'}</Badge> : <span className={`role-tag ${row.role}`}>{ROLE_NAMES[row.role] || row.role}</span>}</td>
    {admin && student && !deleted && <td>{row.subject_group_name || '待激活 / 学校分配'}</td>}
    <td><Badge status={deleted || row.enabled === false ? 'offline' : 'active'}>{deleted ? '已删除' : row.enabled === false ? '已禁用' : '正常'}</Badge></td>
    {admin && <td>{deleted ? <span className="subtle-text">{date(row.deleted_at, true)}</span> : row.must_change_password ? <span className="subtle-text">待首次改密</span> : row.role === 'student' && !row.activated ? <span className="subtle-text">待激活</span> : <span className="text-green">已启用</span>}</td>}
    <td className="subtle-text">{date(row.created_at)}</td>{admin && student && !deleted && <td className="subtle-text">{date(row.last_login_at, true)}</td>}
    <td><div className="row-actions">{actions(row)}</div></td>
  </tr>)}</tbody></table>{!rows.length && <Empty text="没有匹配的账号" detail="可调整搜索和筛选条件，或开通新账号。"/>}</div></div>;
}

function StudentAccounts({classroom, admin, revision, active, actions, ui}) {
  const {SearchInput, Button} = ui;
  const [q, setQ] = useState(''), [enabled, setEnabled] = useState(''), [membership, setMembership] = useState('all'), [sort, setSort] = useState('name'), [order, setOrder] = useState('asc'), [page, setPage] = useState(1), [pageSize, setPageSize] = useState(20);
  const search = useDebounced(q);
  const state = useRemote(`/management/students/page?${accountQuery(classroom.id, {q: search, enabled, membership, sort, order, page, pageSize}, admin)}`, revision, active);
  const data = state.data;
  useEffect(() => {if (data && page > Math.max(1, data.pages)) setPage(Math.max(1, data.pages));}, [data, page]);
  const update = setter => event => {setter(event.target.value); setPage(1);};
  return <section className="panel student-accounts-panel"><div className="student-account-toolbar"><SearchInput value={q} onChange={value => {setQ(value); setPage(1);}} placeholder="搜索学生姓名或账号"/><div className="student-account-filters"><select aria-label="账号状态" value={enabled} onChange={update(setEnabled)}><option value="">全部账号状态</option><option value="true">正常账号</option><option value="false">已禁用账号</option></select>{classroom.id !== 'unassigned' && <select aria-label="班级身份" value={membership} onChange={update(setMembership)}><option value="all">全部班级身份</option><option value="active">正式成员</option><option value="pending">待确认 / 授权</option></select>}<select aria-label="账号排序字段" value={sort} onChange={update(setSort)}><option value="name">按姓名排序</option><option value="username">按账号排序</option><option value="created_at">按开通时间</option>{admin && <option value="last_login_at">按最近登录</option>}</select><select aria-label="排序方向" value={order} onChange={update(setOrder)}><option value="asc">升序</option><option value="desc">降序</option></select><Button variant="secondary" icon="refresh" onClick={state.reload} disabled={state.loading}>刷新</Button></div></div>
    <LoadState state={state} ui={ui}><AccountsTable rows={data?.items || []} admin={admin} student actions={actions} ui={ui}/></LoadState>
    <Pagination data={data} page={page} pageSize={pageSize} onPage={setPage} onSize={size => {setPageSize(size); setPage(1);}} loading={state.loading} ui={ui} noun="个学生账号"/>
  </section>;
}

function StaffAccounts({deleted, revision, actions, ui}) {
  const {SearchInput, Button} = ui;
  const [role, setRole] = useState(deleted ? 'student' : 'teacher'), [q, setQ] = useState(''), [page, setPage] = useState(1);
  const state = useRemote(staffPath(role, deleted), revision);
  const rows = (state.data || []).filter(row => `${row.name} ${row.username}`.toLowerCase().includes(q.toLowerCase().trim()));
  const data = {total: rows.length, pages: Math.max(1, Math.ceil(rows.length / 50))};
  useEffect(() => {if (page > data.pages) setPage(data.pages);}, [page, data.pages]);
  return <section className="panel"><div className="student-account-toolbar"><div className="tabs" aria-label="账号角色">{[...(deleted ? ['student'] : []), 'teacher', 'admin'].map(value => <button type="button" key={value} className={role === value ? 'active' : ''} onClick={() => {setRole(value); setPage(1);}}>{ROLE_NAMES[value]}</button>)}</div><SearchInput value={q} onChange={value => {setQ(value); setPage(1);}} placeholder="搜索姓名或账号"/><Button variant="secondary" icon="refresh" onClick={state.reload} disabled={state.loading}>刷新</Button></div><LoadState state={state} ui={ui}><AccountsTable rows={rows.slice((page - 1) * 50, page * 50)} admin deleted={deleted} actions={actions} ui={ui}/></LoadState><Pagination data={data} page={page} pageSize={50} onPage={setPage} loading={state.loading} ui={ui} noun="个账号"/></section>;
}

export default function StudentWorkspace({user, notify, mode = 'accounts', onModeChange, onCurrentUserUpdated, ui, UserDetailsModal, fileBase64, downloadTemplate}) {
  const {Icon, Button, PageHeader, Modal, Field, FormError, Loading} = ui;
  const admin = user.role === 'admin';
  const [scope, setScope] = useState('students'), [classroom, setClassroom] = useState(null), [revision, setRevision] = useState(0), [studentView, setStudentView] = useState(null), [detailUser, setDetailUser] = useState(null);
  const [overviewClass, setOverviewClass] = useState(null);
  const [editingUser, setEditingUser] = useState(null);
  const [modal, setModal] = useState(null), [form, setForm] = useState({}), [error, setError] = useState(''), [busy, setBusy] = useState(false), [importResult, setImportResult] = useState(null), [removal, setRemoval] = useState(null), [actionBusy, setActionBusy] = useState(null);
  const mounted = useRef(true);
  useEffect(() => () => {mounted.current = false;}, []);
  useEffect(() => {if (mode === 'overview') setScope('students'); setStudentView(null); setDetailUser(null);}, [mode]);
  useEffect(() => {if (mode === 'overview' && classroom) setOverviewClass(classroom.id);}, [mode, classroom]);
  const needsMetadata = modal === 'create' || modal === 'import';
  const classState = useRemote('/management/classes', revision, needsMetadata), groupState = useRemote('/management/groups', revision, needsMetadata && admin);
  const classes = (classState.data || []).filter(row => !row.archived), groups = groupState.data || [];
  useEffect(() => {if (needsMetadata && classState.data && user.role === 'teacher' && !form.class_id) setForm(value => ({...value, class_id: creationClass(classroom, classState.data, true)}));}, [needsMetadata, classState.data, user.role, form.class_id, classroom]);
  const refresh = () => setRevision(value => value + 1);
  const open = (kind, value = {}) => {
    setError(''); setImportResult(null);
    setForm({username: '', name: '', role: kind !== 'import' && scope === 'staff' ? 'teacher' : 'student', password: '', subject_group_id: '', csv: '', class_id: classroom && classroom.id !== 'unassigned' && !classroom.archived ? classroom.id : '', ...value});
    setModal(kind);
  };
  const closeModal = () => {if (!busy) setModal(null);};
  const changeMode = next => {setScope('students'); setStudentView(null); onModeChange(next);};
  const selectClass = row => {setClassroom(row); setOverviewClass(mode === 'overview' ? row.id : null); setStudentView(null); setDetailUser(null);};
  const backToDirectory = () => {setClassroom(null); setOverviewClass(null); setStudentView(null); setDetailUser(null);};
  const submit = async event => {
    event.preventDefault(); setBusy(true); setError('');
    try {
      if (modal === 'create') {
        const payload = {username: form.username.trim(), name: form.name.trim(), role: form.role, password: form.password};
        if (form.role === 'student') {if (form.class_id) payload.class_id = form.class_id; if (admin && form.subject_group_id) payload.subject_group_id = form.subject_group_id; if (!admin && !payload.class_id) throw new Error('请先选择你负责的教学中班级。');}
        await post('/management/users', payload); if (!mounted.current) return;
        setModal(null); notify('账号已开通，首次登录需修改密码。'); refresh();
      } else if (modal === 'reset') {
        await post(`/management/users/${form.id}/reset-password`, {password: form.password}); if (!mounted.current) return;
        setModal(null); notify('密码已重置。');
      } else {
        if (!admin && !form.class_id) throw new Error('请先选择你负责的教学中班级。');
        const result = await post('/management/users/import', {class_id: form.class_id || undefined, rows: studentImportRows(form.csv)}); if (!mounted.current) return;
        setImportResult(result); if (!result.errors?.length) {notify(`已导入 ${Array.isArray(result.created) ? result.created.length : result.created} 个学生账号。`); refresh();}
      }
    } catch (failure) {if (mounted.current) setError(failure.message);} finally {if (mounted.current) setBusy(false);}
  };
  const upload = async event => {
    const file = event.target.files?.[0]; if (!file) return; setError(''); setImportResult(null); setBusy(true);
    try {if (file.size > 1024 * 1024) throw new Error('文件请控制在 1 MB 以内。'); const csv = file.name.toLowerCase().endsWith('.xlsx') ? studentRowsCSV((await post('/management/imports/parse', {kind: 'users', content_base64: await fileBase64(file)})).rows || []) : await file.text(); if (mounted.current) setForm(value => ({...value, csv}));}
    catch (failure) {if (mounted.current) setError(failure.message);} finally {if (mounted.current) setBusy(false);}
  };
  const toggle = async row => {
    if (!window.confirm(`确定${row.enabled === false ? '启用' : '禁用'} ${row.name || row.username} 的账号？`)) return;
    setActionBusy(row.id); try {await patch(`/management/users/${row.id}`, {enabled: row.enabled === false}); if (!mounted.current) return; notify('账号状态已更新。'); refresh();} catch (failure) {if (mounted.current) notify(failure.message, 'error');} finally {if (mounted.current) setActionBusy(null);}
  };
  const forceLogout = async row => {
    if (!window.confirm(`强制退出 ${row.name || row.username} 的全部设备？`)) return;
    setActionBusy(row.id); try {await post(`/management/users/${row.id}/force-logout`); if (mounted.current) notify('该账号的登录凭证已吊销。');} catch (failure) {if (mounted.current) notify(failure.message, 'error');} finally {if (mounted.current) setActionBusy(null);}
  };
  const actions = row => scope === 'deleted' ? <><button disabled={row.can_restore === false} onClick={() => setRemoval({target: row, restore: true})}>恢复账号</button>{row.can_restore === false && <span className="deleted-account-note">已匿名化，不可恢复</span>}</> : <>
    {admin && <button onClick={() => setEditingUser(row)}>编辑资料</button>}
    {admin && row.role === 'student' && <><button onClick={() => setStudentView({student: row, tab: 'profile'})}>基本信息</button><button onClick={() => setStudentView({student: row, tab: 'analytics'})}>学习分析</button><button onClick={() => setDetailUser(row)}>逐题记录</button></>}
    <button disabled={actionBusy === row.id} onClick={() => open('reset', {id: row.id, name: row.name, password: ''})}>重置密码</button>{admin && row.id !== user.id && <button disabled={actionBusy === row.id} onClick={() => forceLogout(row)}>强制下线</button>}{row.id !== user.id && <button disabled={actionBusy === row.id} className={row.enabled === false ? '' : 'danger-text'} onClick={() => toggle(row)}>{row.enabled === false ? '启用' : '禁用'}</button>}{admin && row.id !== user.id && <button disabled={actionBusy === row.id} className="danger-text" onClick={() => setRemoval({target: row, restore: false})}>删除账号</button>}
  </>;
  const metadataError = classState.error || (admin && groupState.error);
  const importDone = modal === 'import' && importResult && !importResult.errors?.length;
  return <div className={`student-workspace ${classroom ? 'has-class' : ''} ${mode === 'overview' ? 'overview-mode' : ''}`}>
    <div hidden={Boolean(studentView)}>
      <PageHeader kicker={mode === 'overview' ? '教学管理 / LEARNING' : '教学管理 / ACCOUNTS'} title={mode === 'overview' ? '学习总览' : '账号管理'} description={mode === 'overview' ? '在一个页面看清全班学习进度，筛选、比较与导出。' : '先选班级，再集中查看和管理学生账号。'}>{mode === 'accounts' && <><Button variant="secondary" icon="download" onClick={() => open('import')}>批量导入</Button><Button icon="plus" onClick={() => open('create')}>开通账号</Button></>}</PageHeader>
      {mode === 'accounts' && admin && <div className="student-workspace-scopes tabs" aria-label="账号管理范围">{[['students', '按班查看学生'], ['staff', '教职工账号'], ['deleted', '账号回收站']].map(([value, label]) => <button type="button" key={value} className={scope === value ? 'active' : ''} onClick={() => setScope(value)}>{label}</button>)}</div>}
      {scope === 'students' && <>
        <div hidden={Boolean(classroom)}><ClassDirectory admin={admin} mode={mode} onSelect={selectClass} revision={revision} ui={ui}/></div>
        {classroom && <><div className="student-workspace-class-heading"><Button variant="secondary" onClick={backToDirectory}>返回班级列表</Button><div><h2>{classroom.name}</h2><p>{classroom.teacher_name || (classroom.id === 'unassigned' ? '暂无当前班级关联' : '未分配教师')}{classroom.subject_group_name ? ` · ${classroom.subject_group_name}` : ''}{classroom.archived ? ' · 已归档' : ''}</p></div>{admin && <div className="tabs" aria-label="班级信息视图"><button type="button" className={mode === 'accounts' ? 'active' : ''} onClick={() => changeMode('accounts')}>学生账号</button><button type="button" className={mode === 'overview' ? 'active' : ''} onClick={() => changeMode('overview')}>集中学情</button></div>}</div>
          <div hidden={mode !== 'accounts'}><div className="inline-note"><Icon name="shield" size={18}/><span>{admin ? '管理员添加或导入至教学中班级的学生直接成为正式成员，无需确认或审批。已退出的学生不计入当前班级；历史数据保留。' : '仅可管理本人教学中班级的账号。待确认成员可处理入班，学生学习数据以已确认的授权范围为准。'}</span></div><StudentAccounts key={classroom.id} classroom={classroom} admin={admin} revision={revision} active={mode === 'accounts'} actions={actions} ui={ui}/></div>
          {admin && overviewClass === classroom.id && <div hidden={mode !== 'overview'}><StudentOverview key={classroom.id} classId={classroom.id} className={classroom.name} embedded refreshVersion={revision} onBack={backToDirectory} onOpenStudent={(row, tab) => setStudentView({student: row, tab})} notify={notify} ui={ui}/></div>}
        </>}
      </>}
      {scope === 'staff' && admin && <><div className="inline-note"><Icon name="contact" size={18}/><span>教师和管理员不依赖学生班级关系，按角色集中管理。</span></div><StaffAccounts key="staff" revision={revision} actions={actions} ui={ui}/></>}
      {scope === 'deleted' && admin && <><div className="inline-note"><Icon name="shield" size={18}/><span>按账号角色查看已删除记录。恢复后保留历史学习数据，需重新登录；已匿名化账号不可恢复。</span></div><StaffAccounts key="deleted" deleted revision={revision} actions={actions} ui={ui}/></>}
    </div>
    {studentView && admin && <StudentDetails key={`${studentView.student.id}-${studentView.tab}`} student={studentView.student} initialTab={studentView.tab} refreshVersion={revision} onEdit={setEditingUser} backLabel={mode === 'overview' ? '返回学习总览' : '返回账户列表'} onBack={() => setStudentView(null)} onPrivateRecords={setDetailUser} ui={ui}/>}
    {editingUser && admin && <UserEditModal key={editingUser.id} target={editingUser} ui={ui} onClose={() => setEditingUser(null)} onSaved={(updated, original) => {
      const outcome = userEditOutcome(user, original, updated);
      setEditingUser(null);
      setStudentView(value => value?.student.id === updated.id ? {...value, student: {...value.student, ...updated}} : value);
      refresh();
      if (outcome.ownAccount) onCurrentUserUpdated?.(updated, outcome);
      if (!outcome.ownAccount || !outcome.requiresRelogin) notify(outcome.message);
    }}/>}
    {detailUser && admin && <UserDetailsModal selected={detailUser} onClose={() => setDetailUser(null)}/>}
    {modal && <Modal title={modal === 'create' ? '开通新账号' : modal === 'reset' ? `重置密码 · ${form.name || ''}` : '批量导入学生'} description={modal === 'import' ? '支持 XLSX 模板或 CSV（账号,姓名,初始密码）。全部校验通过后才创建账号。' : null} onClose={closeModal}><form onSubmit={submit}>
      {modal === 'create' && <><div className="form-grid"><Field label="账号 / 学号"><input required maxLength={64} disabled={busy} value={form.username} onChange={event => setForm({...form, username: event.target.value})}/></Field><Field label="姓名"><input required maxLength={50} disabled={busy} value={form.name} onChange={event => setForm({...form, name: event.target.value})}/></Field></div><Field label="账号角色"><select disabled={busy} value={form.role} onChange={event => setForm({...form, role: event.target.value})}><option value="student">学生</option>{admin && <option value="teacher">教师</option>}</select></Field></>}
      {modal === 'create' && form.role === 'student' && admin && <Field label="学生专业（可选）" hint="选择班级时可自动分配；指定后学生激活时不能自行换专业。"><select value={form.subject_group_id} disabled={busy || groupState.loading} onChange={event => setForm({...form, subject_group_id: event.target.value})}><option value="">按班级分配 / 激活时选择</option>{groups.filter(row => row.enabled !== false).map(row => <option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>}
      {needsMetadata && form.role === 'student' && <Field label={admin ? '加入班级（可选）' : '加入班级（必选）'} hint={admin ? '只可加入教学中班级，添加后直接成为正式成员。' : '只可加入本人教学中班级，学生确认教师可见范围后入班。'}><select required={!admin} value={form.class_id} disabled={busy || classState.loading || importDone} onChange={event => setForm({...form, class_id: event.target.value})}><option value="">{classState.loading ? '正在加载班级…' : admin ? '暂不加入' : '请选择班级'}</option>{classes.map(row => <option key={row.id} value={row.id}>{row.name}</option>)}</select></Field>}
      {needsMetadata && metadataError && <div className="form-error" role="alert">{metadataError}<button type="button" className="text-btn" onClick={() => {classState.reload(); if (admin) groupState.reload();}}>重新加载</button></div>}
      {modal === 'import' ? <><div className="import-template"><div><strong>标准学生导入模板</strong><small>XLSX 或 CSV 均可，账号须全局唯一。</small></div><Button type="button" variant="secondary" icon="download" onClick={() => downloadTemplate('users').catch(failure => setError(failure.message))}>下载 XLSX 模板</Button></div><Field label="上传 XLSX / CSV 文件"><input type="file" accept=".xlsx,.csv,text/csv" disabled={busy || importDone} onChange={upload}/></Field><Field label="导入内容" hint="可粘贴 CSV，支持用双引号包裹逗号。"><textarea rows={8} required disabled={busy || importDone} value={form.csv} placeholder={'账号,姓名,初始密码\n20270001,张同学,自行设置强密码'} onChange={event => {setForm({...form, csv: event.target.value}); setImportResult(null);}}/></Field>{importResult && <div className={importResult.errors?.length ? 'form-error' : 'success-panel'}>{importResult.errors?.length ? importResult.errors.map((row, index) => <p key={index}>第 {row.row} 行：{row.message}</p>) : '导入成功，所有账号已创建。'}</div>}</> : <Field label={modal === 'reset' ? '新初始密码' : '初始密码'} hint="至少 10 位，包含大写、小写字母和数字；首次登录强制修改。"><input type="password" autoComplete="new-password" minLength={10} required disabled={busy} value={form.password} onChange={event => setForm({...form, password: event.target.value})}/></Field>}
      <FormError error={error}/><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={closeModal}>{importDone ? '完成' : '取消'}</Button>{!importDone && <Button disabled={busy || (needsMetadata && (classState.loading || Boolean(metadataError))) || (!admin && needsMetadata && !form.class_id)}>{busy ? '正在处理…' : modal === 'import' ? '校验并导入' : modal === 'reset' ? '确认重置' : '创建账号'}</Button>}</div>
    </form></Modal>}
    {removal && admin && <AdminRemovalModal kind="users" {...removal} ui={ui} onClose={() => setRemoval(null)} onDone={() => {setRemoval(null); notify(removal.restore ? '账号已恢复，需重新登录。' : '账号已移至回收站。'); refresh();}}/>}
  </div>;
}
