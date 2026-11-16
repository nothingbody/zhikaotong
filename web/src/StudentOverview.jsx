import React, {useEffect, useRef, useState} from 'react';
import {api, apiBlob} from './api';
import {displayAccuracy, displayDuration, displayNumber} from './StudentDetails';
import {OVERVIEW_SORTS, dateRangeError, overviewExportPayload, overviewFilename, overviewFilters, overviewQuery, recentDateRange} from './student-overview';
import './student-overview.css';

const initialFilters = () => ({...recentDateRange(30), subject_id:'', q:'', enabled:'', sort_by:'answered', order:'desc'});
const dateLabel = value => {
  if(!value)return '—';
  const date=new Date(value);
  return Number.isFinite(date.getTime())?date.toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}):'—';
};

export default function StudentOverview({classId, className, onBack, onOpenStudent, ui, notify, embedded=false, refreshVersion=0}) {
  const {Icon, Button, Loading}=ui;
  const [filters,setFilters]=useState(initialFilters),[draft,setDraft]=useState(initialFilters),[preset,setPreset]=useState(30);
  const [page,setPage]=useState(1),[pageSize,setPageSize]=useState(20),[revision,setRevision]=useState(0);
  const [resource,setResource]=useState({key:'',data:null,loading:false,error:''});
  const [selected,setSelected]=useState(new Set()),[formError,setFormError]=useState(''),[exportError,setExportError]=useState(''),[exporting,setExporting]=useState(false);
  const [subjectChoices,setSubjectChoices]=useState({classId:'',items:[]});
  const mounted=useRef(false),selectPageRef=useRef(null);
  const normalized=overviewFilters(classId,filters),selectionKey=JSON.stringify(normalized);
  const requestKey=`${overviewQuery(normalized,page,pageSize)}&revision=${revision}&parent_revision=${refreshVersion}`;
  const currentScope=useRef(selectionKey);currentScope.current=selectionKey;
  const data=resource.key===requestKey?resource.data:null;
  const loading=Boolean(classId)&&(resource.key!==requestKey||resource.loading);
  const failure=resource.key===requestKey?resource.error:'';
  const rows=data?.items||[],total=Number(data?.total||0),actualPage=Number(data?.page||page),pages=Math.max(1,Number(data?.pages||1));
  const allPage=rows.length>0&&rows.every(row=>selected.has(row.id)),somePage=rows.some(row=>selected.has(row.id));
  const subjects=subjectChoices.classId===classId?subjectChoices.items:[];
  const label=data?.classroom?.name||className||'所选班级';

  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  useEffect(()=>{
    let active=true;
    if(!classId){setResource({key:requestKey,data:null,loading:false,error:''});return()=>{active=false;};}
    setResource({key:requestKey,data:null,loading:true,error:''});
    api(`/management/students/overview?${overviewQuery(normalized,page,pageSize)}`).then(value=>{
      if(!active)return;
      setResource({key:requestKey,data:value,loading:false,error:''});
      setSubjectChoices({classId,items:value.available_subjects||[]});
    }).catch(error=>{if(active)setResource({key:requestKey,data:null,loading:false,error:error.message});});
    return()=>{active=false;};
  },[requestKey,classId]);
  useEffect(()=>{setSelected(new Set());setExportError('');},[selectionKey,refreshVersion]);
  useEffect(()=>{if(selectPageRef.current)selectPageRef.current.indeterminate=!allPage&&somePage;},[allPage,somePage]);

  const apply=(event,next=draft)=>{
    event?.preventDefault();
    const error=dateRangeError(next.date_from,next.date_to);
    setFormError(error);if(error)return;
    setFilters({...next,q:next.q.trim()});setPage(1);setExportError('');
  };
  const recent=days=>{
    const next={...draft,...recentDateRange(days)};
    setPreset(days);setDraft(next);apply(null,next);
  };
  const sort=(sortBy,order)=>{
    const nextOrder=order||(filters.sort_by===sortBy&&filters.order==='desc'?'asc':'desc');
    setFilters(value=>({...value,sort_by:sortBy,order:nextOrder}));
    setDraft(value=>({...value,sort_by:sortBy,order:nextOrder}));setPage(1);
  };
  const choose=(id,checked)=>{
    if(checked&&selected.size>=500&&!selected.has(id)){setExportError('一次最多选择500名学生，请缩小范围或导出筛选结果。');return;}
    setSelected(previous=>{
      const next=new Set(previous);checked?next.add(id):next.delete(id);return next;
    });
  };
  const choosePage=()=>{
    const next=new Set(selected);
    rows.forEach(row=>{allPage?next.delete(row.id):next.add(row.id);});
    if(next.size>500){setExportError('一次最多选择500名学生，请缩小范围或导出筛选结果。');return;}
    setSelected(next);
  };
  const refresh=()=>{setSelected(new Set());setRevision(value=>value+1);setExportError('');};
  const download=async onlySelected=>{
    if(loading||exporting||!data)return;
    setExportError('');
    const scope=selectionKey,ids=onlySelected?[...selected]:undefined;
    try{
      if(!onlySelected&&total>5000)throw new Error('筛选结果超过5000名学生，请缩小范围或选择学生后导出。');
      const body=overviewExportPayload(normalized,ids);
      setExporting(true);
      const blob=await apiBlob('/management/students/overview/export',{method:'POST',body});
      if(!mounted.current||currentScope.current!==scope)return;
      if(!blob.type.toLowerCase().startsWith('text/csv'))throw new Error('导出文件格式不正确，请刷新后重试。');
      const url=URL.createObjectURL(blob),link=document.createElement('a');
      try{
        link.href=url;link.download=overviewFilename(label,filters.date_from,filters.date_to);
        document.body.appendChild(link);link.click();link.remove();
      }finally{window.setTimeout(()=>URL.revokeObjectURL(url),1000);}
      notify?.(onlySelected?`已导出所选 ${ids.length} 名学生的学习汇总。`:`已导出当前筛选的 ${total} 名学生学习汇总。`);
    }catch(error){if(mounted.current&&currentScope.current===scope)setExportError(error.message);}
    finally{if(mounted.current)setExporting(false);}
  };
  const sortHeader=(key,name)=>{
    const active=filters.sort_by===key;
    return <th scope="col" aria-sort={active?(filters.order==='asc'?'ascending':'descending'):'none'}><button type="button" className={`overview-sort-header ${active?'active':''}`} onClick={()=>sort(key)} aria-label={`按${name}排序${active?`，当前${filters.order==='asc'?'升序':'降序'}`:''}`}>{name}<span aria-hidden="true">{active?(filters.order==='asc'?'↑':'↓'):'↕'}</span></button></th>;
  };

  if(!classId)return <section className="panel student-overview-empty"><Icon name="school" size={30}/><h2>先选择班级</h2><p>进入班级后，可集中查看该班学生的学习情况。</p>{onBack&&<Button variant="secondary" onClick={onBack}>选择班级</Button>}</section>;
  return <div className={`student-overview-page ${embedded?'is-embedded':''}`}>
    {!embedded&&<div className="student-overview-heading"><div>{onBack&&<button className="overview-back" type="button" onClick={onBack}><Icon name="chevron" size={15}/>返回班级列表</button>}<h2>{label}<span>学习总览</span></h2><p>同页了解多名学生，按科目和时间比较学习进度。</p></div><Button variant="secondary" icon="refresh" disabled={loading||exporting} onClick={refresh}>刷新数据</Button></div>}
    <section className="panel student-overview-filters" aria-label="学生学习汇总筛选">
      <div className="overview-filter-topbar"><div className="overview-date-presets" role="group" aria-label="学习汇总时间范围">{[7,30,90].map(days=><button key={days} type="button" className={preset===days?'active':''} aria-pressed={preset===days} onClick={()=>recent(days)}>近{days}天</button>)}<button type="button" className={preset==='custom'?'active':''} aria-pressed={preset==='custom'} onClick={()=>setPreset('custom')}>自定义</button><span>北京时间 · 含首尾日期</span></div>{embedded&&<Button variant="secondary" icon="refresh" disabled={loading||exporting} onClick={refresh}>刷新数据</Button>}</div>
      <form onSubmit={apply} className="overview-filter-form">
        <label>开始日期<input type="date" aria-label="学习汇总开始日期" required value={draft.date_from} onChange={event=>{setPreset('custom');setDraft(value=>({...value,date_from:event.target.value}));}}/></label>
        <label>结束日期<input type="date" aria-label="学习汇总结束日期" required value={draft.date_to} onChange={event=>{setPreset('custom');setDraft(value=>({...value,date_to:event.target.value}));}}/></label>
        <label>课程 / 科目<select aria-label="学习汇总科目" value={draft.subject_id} onChange={event=>setDraft(value=>({...value,subject_id:event.target.value}))}><option value="">全部科目</option>{subjects.map(subject=><option key={subject.id} value={subject.id}>{subject.name}</option>)}</select></label>
        <label className="overview-student-search">学生姓名 / 账号<input type="search" aria-label="学习汇总学生搜索" maxLength={100} value={draft.q} onChange={event=>setDraft(value=>({...value,q:event.target.value}))} placeholder="输入姓名或账号，可匹配多名学生"/></label>
        <label>账号状态<select aria-label="学习汇总账号状态" value={draft.enabled} onChange={event=>setDraft(value=>({...value,enabled:event.target.value}))}><option value="">全部状态</option><option value="true">已启用</option><option value="false">已停用</option></select></label>
        <Button type="submit" disabled={exporting}>应用筛选</Button>
      </form>
      {formError&&<p className="overview-inline-error" role="alert">{formError}</p>}
    </section>
    <div className="overview-scope-note"><Icon name="shield" size={17}/><p>{classId==='unassigned'?'展示当前未分配有效班级的学生。':'展示当前正式在班学生，已退出学生不列入本班汇总。'}只统计已同步的自主练习；班级任务单独在学生详情中查看，未同步记录暂不计入。{Number(data?.summary?.pending_student_count)>0&&<span>本班另有 {displayNumber(data.summary.pending_student_count)} 名待确认或未完成授权的成员，暂不计入学习汇总；可在本班账户管理中查看。</span>}</p></div>
    {loading?<Loading/>:failure?<div className="overview-resource-error" role="alert"><strong>学习汇总加载失败</strong><p>{failure}</p><Button variant="secondary" onClick={refresh}>重试</Button></div>:data&&<>
      <section className="overview-summary-grid" aria-label="全筛选范围学习概况">
        <div><span>筛选学生</span><strong>{displayNumber(data.summary?.student_count)}</strong><small>当前筛选名单，包含本期间无作答学生</small></div>
        <div><span>期间有练习</span><strong>{displayNumber(data.summary?.active_students)}</strong><small>{displayNumber(Math.max(0,Number(data.summary?.student_count||0)-Number(data.summary?.active_students||0)))} 名学生本期间暂无已同步练习</small></div>
        <div><span>自主答题次数</span><strong>{displayNumber(data.summary?.answered)}</strong><small>答对 {displayNumber(data.summary?.correct)} · 答错 {displayNumber(data.summary?.wrong)}</small></div>
        <div><span>整体正确率</span><strong>{displayAccuracy(data.summary)}</strong><small>按全部作答计算 · 用时 {displayDuration(data.summary?.study_seconds)}</small></div>
      </section>
      <section className="panel overview-results" aria-label="学生学习汇总列表">
        <div className="overview-results-heading"><div><h3>学生学习汇总<span>{displayNumber(total)} 人</span></h3><p>{data.period?.date_from||filters.date_from} 至 {data.period?.date_to||filters.date_to} · {filters.subject_id?subjects.find(subject=>subject.id===filters.subject_id)?.name||'所选科目':'全部科目'}{filters.q?` · 搜索“${filters.q}”`:''}</p></div><div className="overview-sort-controls"><label>排序<select aria-label="学习汇总排序字段" value={filters.sort_by} onChange={event=>sort(event.target.value,filters.order)}>{Object.entries(OVERVIEW_SORTS).map(([key,name])=><option key={key} value={key}>{name}</option>)}</select></label><select aria-label="学习汇总排序方向" value={filters.order} onChange={event=>sort(filters.sort_by,event.target.value)}><option value="desc">从高到低 / 从新到旧</option><option value="asc">从低到高 / 从旧到新</option></select></div></div>
        <div className="overview-batch-bar"><div><strong>已选 {selected.size} 人</strong><span>可跨页保留，最多500人</span>{selected.size>0&&<button type="button" className="text-btn" onClick={()=>setSelected(new Set())}>清空选择</button>}</div><div><Button variant="secondary" icon="download" disabled={exporting||!selected.size} onClick={()=>download(true)}>{exporting?'正在导出…':`导出已选${selected.size?`（${selected.size}）`:''}`}</Button><Button variant="secondary" icon="download" disabled={exporting||!total||total>5000} onClick={()=>download(false)}>导出筛选结果</Button></div></div>
        {exportError&&<p className="overview-inline-error overview-export-message" role="alert">{exportError}</p>}
        {total>5000&&<p className="overview-export-limit">筛选结果超过5000人，请缩小范围或勾选学生后导出；系统不会截断导出结果。</p>}
        {rows.length?<div className="overview-table-scroll" tabIndex={0} role="region" aria-label="学生学习汇总表格，可横向滚动"><table><thead><tr><th className="overview-check-cell" scope="col"><input ref={selectPageRef} type="checkbox" aria-label={allPage?'取消选择本页学生':'选择本页学生'} checked={allPage} disabled={exporting} onChange={choosePage}/></th><th className="overview-student-cell" scope="col" aria-sort={filters.sort_by==='name'?(filters.order==='asc'?'ascending':'descending'):'none'}><button type="button" className="overview-sort-header" aria-label="按姓名排序" onClick={()=>sort('name')}>学生 / 账号<span aria-hidden="true">{filters.sort_by==='name'?(filters.order==='asc'?'↑':'↓'):'↕'}</span></button></th><th scope="col">账号状态</th>{sortHeader('answered','答题次数')}<th scope="col">不同题目</th><th scope="col">答对 / 答错</th>{sortHeader('accuracy','正确率')}{sortHeader('study_seconds','练习用时')}{sortHeader('active_days','活跃天数')}{sortHeader('last_answered_at','最近作答')}<th scope="col">学生详情</th></tr></thead><tbody>{rows.map(row=><tr key={row.id} className={selected.has(row.id)?'selected':''}><td className="overview-check-cell"><input type="checkbox" aria-label={`选择学生：${row.name||row.username}（${row.username}）`} checked={selected.has(row.id)} disabled={exporting} onChange={event=>choose(row.id,event.target.checked)}/></td><th scope="row" className="overview-student-cell"><strong>{row.name||'未填写姓名'}</strong><small>{row.username}</small>{row.class_name&&row.class_name!==row.name&&<small>班内姓名：{row.class_name}</small>}<small className="overview-profession">{row.subject_group_name||'未分配专业'}</small></th><td><span className={`overview-account-state ${row.enabled?'enabled':'disabled'}`}>{row.enabled?'已启用':'已停用'}</span><small className="overview-activation">{row.activated?'已激活':'待激活'}</small></td><td className="overview-number-strong">{displayNumber(row.practice?.answered)}</td><td>{displayNumber(row.practice?.unique_questions)}</td><td><span className="overview-correct">{displayNumber(row.practice?.correct)}</span><span className="overview-number-divider">/</span><span className="overview-wrong">{displayNumber(row.practice?.wrong)}</span></td><td className={!row.practice?.answered?'overview-muted':''}>{displayAccuracy(row.practice)}</td><td>{displayDuration(row.practice?.study_seconds)}</td><td>{displayNumber(row.practice?.active_days)} 天</td><td title={row.practice?.last_answered_at||''}>{dateLabel(row.practice?.last_answered_at)}</td><td><div className="overview-detail-actions"><button type="button" className="text-btn" onClick={()=>onOpenStudent(row,'profile')}>基础信息</button><button type="button" className="text-btn" onClick={()=>onOpenStudent(row,'analytics')}>学习详情</button></div></td></tr>)}</tbody></table></div>:<div className="overview-empty-results"><Icon name="users" size={30}/><h3>暂无符合条件的学生</h3><p>可调整姓名、账号状态或返回班级列表；无作答学生会保留在名单中。</p></div>}
        <nav className="overview-pagination" aria-label="学习汇总分页"><p>{total?`第 ${(actualPage-1)*pageSize+1}–${Math.min(actualPage*pageSize,total)} 人，共 ${displayNumber(total)} 人`:'共 0 人'}</p><div><label>每页<select aria-label="学习汇总每页人数" value={pageSize} onChange={event=>{setPageSize(Number(event.target.value));setPage(1);}}>{[20,50,100].map(size=><option key={size} value={size}>{size} 人</option>)}</select></label><Button variant="secondary" disabled={actualPage<=1} onClick={()=>setPage(actualPage-1)}>上一页</Button><span>第 {actualPage} / {pages} 页</span><Button variant="secondary" disabled={actualPage>=pages} onClick={()=>setPage(actualPage+1)}>下一页</Button></div></nav>
        <p className="overview-metric-note">答题次数含重复作答；不同题目按每名学生去重。正确率按作答次数计算，无作答显示“—”；表头或排序菜单可调整比较顺序。</p>
      </section>
    </>}
    <p className="overview-audit-note"><Icon name="lock" size={15}/>汇总查看和导出按当前账号权限校验并记录用途；导出只含基础资料与学习汇总，不包含密码、私人逐题选择或笔记。</p>
  </div>;
}
