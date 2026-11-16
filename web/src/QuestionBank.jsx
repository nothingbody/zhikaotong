import React, { useEffect, useRef, useState } from 'react';
import { api, patch, post, put } from './api';
import WordImportModal, { FillAnswerEditor, formatQuestionAnswer } from './WordImport';
import ImportHistoryModal from './ImportHistory';
import './question-bank.css';
import QuestionContent from './QuestionContent';
import { plainQuestionText, editableQuestionText, restoreQuestionText, questionImageIds } from './question-media';

const TYPES = {single:'单选题',multiple:'多选题',judge:'判断题',fill:'填空题'};
const TYPE_HINTS = {single:'每题选择一个答案。',multiple:'每题可选择多个答案，全部选对才得分。',judge:'逐题判断正确或错误。',fill:'按照空位填写答案。'};
const labelFor = status => status === 'published' ? '已发布' : status === 'offline' ? '已下线' : '未发布';
const emptyOptions = type => type==='fill'?[]:type==='judge'?[{key:'A',text:'正确'},{key:'B',text:'错误'}]:[{key:'A',text:''},{key:'B',text:''},{key:'C',text:''},{key:'D',text:''}];

export default function QuestionBankPage({notify,ui,QuestionImportModal}) {
  const {Icon,Button,Field,Modal,Badge,PageHeader,SearchInput,FormError,DataState,useData}=ui;
  const state=useData(()=>Promise.all([api('/management/subjects'),api('/management/bank/summary'),api('/management/bank/classifications')]).then(([subjects,summary,classifications])=>({subjects,summary,classifications})),[]);
  const [query,setQuery]=useState(''),[subject,setSubject]=useState(''),[kind,setKind]=useState(''),[status,setStatus]=useState('');
  const [page,setPage]=useState(1),[pageSize,setPageSize]=useState(20),[revision,setRevision]=useState(0),[pageResult,setPageResult]=useState({key:'',data:null,loading:false,error:''});
  const [selectingAll,setSelectingAll]=useState(false),[classificationSource,setClassificationSource]=useState('');
  const [selected,setSelected]=useState(new Set()),[editing,setEditing]=useState(false),[form,setForm]=useState({}),[preview,setPreview]=useState(null);
  const [importOpen,setImportOpen]=useState(false),[wordOpen,setWordOpen]=useState(false),[historyOpen,setHistoryOpen]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState(''),[formError,setFormError]=useState('');
  const [classifying,setClassifying]=useState(null),[targetSubject,setTargetSubject]=useState(''),[classificationError,setClassificationError]=useState('');
  const [managingSubjects,setManagingSubjects]=useState(false),[newSubject,setNewSubject]=useState(''),[renaming,setRenaming]=useState(null),[subjectError,setSubjectError]=useState('');
  const subjects=state.data?.subjects||[], summary=state.data?.summary||{}, classifications=state.data?.classifications||{};
  const subjectTotals=classifications.subjects||[];
  const subjectName=id=>subjects.find(item=>item.id===id)?.name||subjectTotals.find(item=>item.id===id)?.name||'未设置科目';
  const filters=new URLSearchParams({subject_id:subject,q:query,type:kind,status});
  const filterKey=filters.toString(),requestKey=`${filterKey}&page=${page}&page_size=${pageSize}&revision=${revision}`;
  const selectionScope=`${filterKey}&page_size=${pageSize}&revision=${revision}`;
  const filterRef=useRef(selectionScope);filterRef.current=selectionScope;
  const selectionGeneration=useRef(0);
  const currentPage=pageResult.key===requestKey?pageResult.data:null;
  const rows=currentPage?.items||[],total=Number(currentPage?.total||0),pages=Math.max(1,Number(currentPage?.pages||1));
  const pageLoading=Boolean(subject)&&(pageResult.key!==requestKey||pageResult.loading);
  const pageState={loading:pageLoading,error:pageResult.key===requestKey?pageResult.error:'',reload:()=>setRevision(value=>value+1)};
  const actionsDisabled=busy||pageLoading||selectingAll;
  const legacyCount=Number(summary.counts?.draft||0)+Number(summary.counts?.pending||0);
  useEffect(()=>{
    if(!subject){setPageResult({key:requestKey,data:null,loading:false,error:''});return;}
    let active=true;
    setPageResult({key:requestKey,data:null,loading:true,error:''});
    api(`/management/questions/page?${filterKey}&page=${page}&page_size=${pageSize}`).then(data=>{
      if(!active)return;
      if(data.page!==page){setPage(data.page);return;}
      setPageResult({key:requestKey,data,loading:false,error:''});
    }).catch(reason=>{if(active)setPageResult({key:requestKey,data:null,loading:false,error:reason.message});});
    return()=>{active=false;};
  },[requestKey]);
  const clearSelection=()=>{selectionGeneration.current+=1;setSelected(new Set());setSelectingAll(false);};
  const changeFilter=(setter,value)=>{setter(value);setPage(1);clearSelection();setError('');};
  const enterSubject=id=>{setSubject(id);setQuery('');setKind('');setStatus('');setPage(1);clearSelection();setError('');};
  const reload=async()=>{clearSelection();setRevision(value=>value+1);await state.reload();};
  const openClassification=ids=>{if(!ids.length||ids.length>5000)return;setClassifying([...ids]);setClassificationSource(subject);setTargetSubject(subject);setClassificationError('');};
  const selectFiltered=async()=>{
    const scope=selectionScope,generation=selectionGeneration.current;setSelectingAll(true);setError('');
    try{const result=await api(`/management/questions/ids?${filterKey}`);if(filterRef.current!==scope||selectionGeneration.current!==generation)return;if(result.ids.length>5000)throw new Error('一次最多选择5000道题，请缩小筛选范围。');setSelected(new Set(result.ids));}
    catch(reason){if(filterRef.current===scope&&selectionGeneration.current===generation)setError(reason.message);}finally{if(selectionGeneration.current===generation)setSelectingAll(false);}
  };
  const classify=async event=>{
    event.preventDefault();setBusy(true);setClassificationError('');
    try{const result=await post('/management/questions/classify',{ids:classifying,subject_id:targetSubject});setClassifying(null);notify(result.changed?`已调整 ${result.changed} 道题目的科目${result.published_changed?`，题库版本 ${result.version}`:''}。`:'所选题目已在该科目中。');await reload();}catch(reason){setClassificationError(reason.message);}finally{setBusy(false);}
  };
  const saveSubject=async(event,rename=false)=>{
    event.preventDefault();setBusy(true);setSubjectError('');
    try{const name=(rename?renaming.name:newSubject).trim();if(!name)throw new Error('请填写科目名称。');if(rename)await patch(`/management/bank/subjects/${renaming.id}`,{name});else await post('/management/bank/subjects',{name});setNewSubject('');setRenaming(null);notify(rename?'科目名称已更新。':'科目已创建，可以添加或调整题目。');await reload();}catch(reason){setSubjectError(reason.message);}finally{setBusy(false);}
  };
  const toggle=id=>setSelected(previous=>{const next=new Set(previous);next.has(id)?next.delete(id):next.add(id);return next;});
  const batch=async(action,ids)=>{
    if(!ids.length)return;
    const actionName={publish:'发布',offline:'下线',delete:'移除'}[action];
    const detail=action==='delete'?'移除后不再出现在练习和组卷题池中，历史答题记录与成绩保留。':action==='offline'?'下线后不再用于新练习和组卷，历史记录保留。':'发布后立即可用于学生练习和教师组卷。';
    if(!window.confirm(`确定${actionName}这 ${ids.length} 道题目？${detail}`))return;
    setBusy(true);setError('');
    try{const result=await post('/management/questions/batch',{action,ids});notify(`已${actionName} ${result.changed} 道题目，题库版本 ${result.version}。`);await reload();}catch(reason){setError(reason.message);}finally{setBusy(false);}
  };
  const publishLegacy=async()=>{
    if(!window.confirm(`将现有 ${legacyCount} 道草稿或待发布题目全部发布？已下线和已移除题目不会恢复。`))return;
    setBusy(true);setError('');try{const result=await post('/management/bank/publish');notify(`题库已更新至版本 ${result.version}，当前可练习 ${result.count} 道题。`);await reload();}catch(reason){setError(reason.message);}finally{setBusy(false);}
  };
  const open=question=>{
    setFormError('');setForm(question?{...question,answer:Array.isArray(question.answer)?question.answer:[],authorization:question.authorization||'',options:question.type==='fill'?[]:question.options?.length?question.options:emptyOptions(question.type)}:{subject_id:subject||subjects[0]?.id||'',type:kind||'single',stem:'',options:emptyOptions(kind||'single'),answer:[],explanation:'',difficulty:2,source:'',authorization:'',status:'published'});
    setEditing(true);
  };
  const selectType=type=>setForm(previous=>({...previous,type,answer:[],options:emptyOptions(type)}));
  const save=async event=>{
    event.preventDefault();setBusy(true);setFormError('');
    try{
      if(form.type==='fill'){if(!form.answer.length||form.answer.some(slot=>!Array.isArray(slot)||!slot.some(value=>typeof value==='string'&&value.trim())))throw new Error('请填写每一空的参考答案。');}
      else{if(!form.answer.length)throw new Error('请选择正确答案。');if(form.type!=='multiple'&&form.answer.length!==1)throw new Error('单选和判断题应只有一个正确答案。');}
      const payload={subject_id:form.subject_id,type:form.type,stem:form.stem,options:form.type==='fill'?[]:form.options,answer:form.type==='fill'?form.answer.map(slot=>[...new Set(slot.map(value=>value.trim()).filter(Boolean))]):form.answer,explanation:form.explanation,difficulty:Number(form.difficulty),source:form.source,authorization:form.authorization,media:form.media||{},status:'published'};
      const result=form.id?await put(`/management/questions/${form.id}`,payload):await post('/management/questions',payload);
      setEditing(false);notify(`题目已保存并发布${result.version?`，题库版本 ${result.version}`:''}。`);await reload();
    }catch(reason){setFormError(reason.message);}finally{setBusy(false);}
  };
  const resetFilters=()=>{setQuery('');setKind('');setStatus('');setPage(1);clearSelection();setError('');};
  return <>
    <PageHeader kicker={subject?'题库管理 / SUBJECT QUESTIONS':'内容管理 / QUESTION BANK'} title={subject?subjectName(subject):'题库管理'} description={subject?'在当前科目内查找、校对和整理题目。保存后直接发布。':'先选择科目，再查看和整理该科目的题目。'}>
      {subject&&<Button variant="secondary" className="bank-back-button" disabled={busy} onClick={()=>enterSubject('')}>返回科目列表</Button>}
      <Button variant="secondary" icon="file" onClick={()=>setWordOpen(true)}>Word自动识别</Button>
      <Button variant="secondary" icon="download" onClick={()=>setImportOpen(true)}>Excel导入</Button>
      <Button icon="plus" disabled={state.loading||Boolean(state.error)||busy} onClick={()=>open()}>录入题目</Button>
    </PageHeader>
    {!subject&&<DataState state={state}>
      <div className="bank-directory-summary"><span><strong>{subjects.length}</strong> 个科目</span><span><strong>{Number(summary.total||0).toLocaleString('zh-CN')}</strong> 道题目</span><span>已发布 {Number(summary.count||0).toLocaleString('zh-CN')} 道</span><span>题库版本 {summary.version??'—'}</span></div>
      <section className="bank-subject-navigation" aria-label="科目列表">
        <div className="bank-subject-heading"><div><h2>选择科目</h2><p>每个科目独立查看，题目按页加载。</p></div><Button variant="secondary" disabled={busy} onClick={()=>{setManagingSubjects(true);setSubjectError('');setRenaming(null);}}>管理科目</Button></div>
        <div className="bank-subject-grid">
          {subjectTotals.map(item=><button key={item.id} className="bank-subject-card" aria-label={`查看科目：${item.name}`} disabled={busy} onClick={()=>enterSubject(item.id)}><div className="bank-subject-card-top"><span className="bank-subject-icon"><Icon name="book" size={20}/></span><Icon name="chevron" size={17}/></div><span>{item.name}</span><strong>{Number(item.total||0).toLocaleString('zh-CN')}<small>道题</small></strong><p>{Object.entries(TYPES).filter(([type])=>Number(item.by_type?.[type])).map(([type,label])=>`${label.replace('题','')} ${item.by_type[type]}`).join(' · ')||'暂无题目，可进入录入'}</p><div className="bank-subject-card-footer"><span>已发布 {Number(item.published||0)}</span><span>查看题目 <Icon name="arrow" size={13}/></span></div></button>)}
        </div>
        {!subjectTotals.length&&<div className="bank-directory-empty"><Icon name="book" size={28}/><p>还没有科目</p><span>先在“管理科目”中新建，再录入或导入题目。</span></div>}
      </section>
    </DataState>}
    <div className="bank-workflow-note"><div><Icon name="check" size={19}/><span>管理员保存后立即生效，无需审核。已完成练习的题目与成绩保留原快照。</span></div><Button variant="secondary" onClick={()=>setHistoryOpen(true)}>导入记录</Button></div>
    {legacyCount>0&&<div className="bank-legacy"><span>还有 {legacyCount} 道历史草稿或待发布题目。</span><Button variant="secondary" disabled={busy} onClick={publishLegacy}>发布全部草稿</Button></div>}
    <FormError error={error}/>
    {subject&&<section className="panel bank-management-panel" aria-label={`${subjectName(subject)}题目列表`}>
      <div className="bank-subject-breadcrumb"><button type="button" disabled={busy} onClick={()=>enterSubject('')}>科目列表</button><Icon name="chevron" size={14}/><strong>{subjectName(subject)}</strong><span>{currentPage?`${TYPES[kind]||'全部题型'} · ${total.toLocaleString('zh-CN')} 道`:'正在加载题目'}</span></div>
      <div className="bank-type-section">
        <div className="bank-type-heading"><strong>按题型查看</strong><span>{TYPE_HINTS[kind]||'单选、多选、判断和填空分别查看。'}</span></div>
        <div className="bank-type-navigation" role="group" aria-label="按题型筛选">
          {[['','全部题型'],...Object.entries(TYPES)].map(([value,label])=><button key={value} type="button" aria-pressed={kind===value} className={kind===value?'active':''} disabled={busy} onClick={()=>{if(kind!==value)changeFilter(setKind,value);}}>{label}</button>)}
        </div>
      </div>
      <div className="bank-filter-toolbar">
        <SearchInput value={query} onChange={value=>changeFilter(setQuery,value)} placeholder="在本科目搜索题干或来源"/>
        <div className="bank-filter-selects">
          <select aria-label="按状态筛选" value={status} disabled={busy} onChange={event=>changeFilter(setStatus,event.target.value)}><option value="">全部状态</option><option value="published">已发布</option><option value="offline">已下线</option><option value="unpublished">未发布</option></select>
          {(query||kind||status)&&<button className="text-btn" disabled={busy} onClick={resetFilters}>清除筛选</button>}
          <button className="icon-btn" aria-label="刷新本科目题目" disabled={actionsDisabled} onClick={reload}><Icon name="refresh" size={18}/></button>
        </div>
      </div>
      <DataState state={pageState}>
        {total>5000&&<p className="bank-selection-limit">一次批量操作最多5000道题，请先缩小筛选范围再选择全部结果。</p>}
        <div className="bank-bulk-toolbar"><div><button className="text-btn" disabled={actionsDisabled||!rows.length} onClick={()=>setSelected(previous=>new Set([...previous,...rows.map(row=>row.id)]))}>选择本页（{rows.length}）</button><button className="text-btn" disabled={actionsDisabled||!total||total>5000} onClick={selectFiltered}>{selectingAll?'正在选择…':`选择全部筛选结果（${total}）`}</button>{selected.size>0&&<button className="text-btn" disabled={busy} onClick={clearSelection}>取消选择</button>}<span aria-live="polite">已选 {selected.size} 道（跨页保留）</span></div><div><Button variant="secondary" disabled={actionsDisabled||!selected.size||selected.size>5000} onClick={()=>openClassification([...selected])}>批量调整科目</Button><Button variant="secondary" disabled={actionsDisabled||!selected.size||selected.size>5000} onClick={()=>batch('publish',[...selected])}>批量发布</Button><Button variant="secondary" disabled={actionsDisabled||!selected.size||selected.size>5000} onClick={()=>batch('offline',[...selected])}>批量下线</Button><Button variant="danger" disabled={actionsDisabled||!selected.size||selected.size>5000} onClick={()=>batch('delete',[...selected])}>批量移除</Button></div></div>
        <div className="data-table"><div className="table-wrap"><table><thead><tr>{['选择','题目内容','题型 / 难度','状态','操作'].map(label=><th key={label}>{label}</th>)}</tr></thead><tbody>
          {rows.map(question=><tr key={question.id}>
            <td className="bank-select-cell"><input type="checkbox" aria-label={`选择：${plainQuestionText(question.stem).slice(0,45)}`} checked={selected.has(question.id)} disabled={actionsDisabled} onChange={()=>toggle(question.id)}/></td>
            <td className="question-stem"><button disabled={actionsDisabled} onClick={()=>setPreview(question)}>{plainQuestionText(question.stem)}</button><small>{question.source||'未记录来源'}</small></td>
            <td>{TYPES[question.type]||question.type}<small className="table-sub"><span className="difficulty" aria-label={`难度 ${question.difficulty} / 5`}>{[1,2,3,4,5].map(number=><i key={number} className={number<=question.difficulty?'filled':''}/>)}</span></small></td>
            <td><Badge status={question.status}>{labelFor(question.status)}</Badge></td>
            <td><div className="row-actions"><button disabled={actionsDisabled} onClick={()=>setPreview(question)}>预览</button><button disabled={actionsDisabled} onClick={()=>open(question)}>编辑</button><button disabled={actionsDisabled} onClick={()=>openClassification([question.id])}>调整科目</button><button disabled={actionsDisabled} onClick={()=>batch(question.status==='published'?'offline':'publish',[question.id])}>{question.status==='published'?'下线':'发布'}</button><button disabled={actionsDisabled} className="danger-text" onClick={()=>batch('delete',[question.id])}>移除</button></div></td>
          </tr>)}
        </tbody></table>{!rows.length&&<div className="bank-question-empty"><Icon name="search" size={28}/><p>{query||kind||status?'没有符合筛选条件的题目':'本科目还没有题目'}</p><span>{query||kind||status?'调整搜索内容或清除筛选后重试。':'可以录入题目，或通过Word、Excel导入。'}</span></div>}</div></div>
        <nav className="bank-pagination" aria-label="本科目题目分页"><span>{total?`第 ${(page-1)*pageSize+1}–${Math.min(page*pageSize,total)} 道，共 ${total.toLocaleString('zh-CN')} 道`:'共 0 道题目'}</span><div><label>每页<select aria-label="每页题目数量" value={pageSize} disabled={actionsDisabled} onChange={event=>changeFilter(setPageSize,Number(event.target.value))}>{[20,50,100].map(size=><option key={size} value={size}>{size} 道</option>)}</select></label><Button variant="secondary" aria-label="上一页题目" disabled={actionsDisabled||page<=1} onClick={()=>setPage(value=>value-1)}>上一页</Button><select aria-label="题目页码" value={page} disabled={actionsDisabled} onChange={event=>setPage(Number(event.target.value))}>{Array.from({length:pages},(_,index)=><option key={index+1} value={index+1}>第 {index+1} / {pages} 页</option>)}</select><Button variant="secondary" aria-label="下一页题目" disabled={actionsDisabled||page>=pages} onClick={()=>setPage(value=>value+1)}>下一页</Button></div></nav>
        <div className="table-footer">仅加载当前科目的这一页题目<span>普通勾选可跨页保留；更换科目或筛选条件后清空选择。</span></div>
      </DataState>
    </section>}
    {editing&&<Modal wide title={form.id?'编辑题目':'录入题目'} description="填写完整后保存并发布，无需其他管理员确认。" onClose={busy?()=>{}:()=>setEditing(false)}><form onSubmit={save}>
      {form.id&&<div className="inline-note">修改后将立即用于新的练习和组卷；已发布的练习及历史成绩保留原题目快照。</div>}
      <div className="form-grid"><Field label="科目"><select required value={form.subject_id} onChange={event=>setForm({...form,subject_id:event.target.value})}>{subjects.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></Field><Field label="题型"><select value={form.type} onChange={event=>selectType(event.target.value)}>{Object.entries(TYPES).map(([value,label])=><option key={value} value={value}>{label}</option>)}</select></Field><Field label="难度"><select value={form.difficulty} onChange={event=>setForm({...form,difficulty:Number(event.target.value)})}>{[1,2,3,4,5].map(value=><option key={value} value={value}>{value} / 5</option>)}</select></Field></div>
      <Field label="题干"><textarea rows={4} required value={editableQuestionText(form.stem)} onChange={event=>setForm({...form,stem:restoreQuestionText(event.target.value,form.stem)})} placeholder="请输入清晰、完整的题干"/></Field>{questionImageIds(form.stem).length>0&&<div className="question-editor-preview"><small>原图已保留。编辑文字不会丢图；删除“原图”标记可移除对应图片。</small><QuestionContent text={form.stem} media={form.media}/></div>}
      {form.type==='fill'?<FillAnswerEditor answer={form.answer} onChange={answer=>setForm({...form,answer})} prefix="bank-fill"/>:<div className="field"><span>选项与正确答案 <small>勾选正确选项</small></span><div className="option-editor">{form.options.map((option,index)=><div key={option.key}><input aria-label={`${option.key} 为正确答案`} type={form.type==='multiple'?'checkbox':'radio'} name="correct_answer" checked={form.answer.includes(option.key)} onChange={()=>setForm({...form,answer:form.type==='multiple'?(form.answer.includes(option.key)?form.answer.filter(answer=>answer!==option.key):[...form.answer,option.key]):[option.key]})}/><b>{option.key}</b><input aria-label={`选项 ${option.key}`} required value={editableQuestionText(option.text)} onChange={event=>setForm({...form,options:form.options.map((item,number)=>number===index?{...item,text:restoreQuestionText(event.target.value,option.text)}:item)})}/></div>)}</div></div>}
      {form.type!=='fill'&&form.options.some(option=>questionImageIds(option.text).length>0)&&<div className="question-editor-preview"><small>选项原图会随题目一同保存。</small>{form.options.filter(option=>questionImageIds(option.text).length>0).map(option=><p key={option.key}><b>{option.key}：</b><QuestionContent text={option.text} media={form.media}/></p>)}</div>}
      <Field label="答案解析"><textarea required rows={3} value={editableQuestionText(form.explanation)} onChange={event=>setForm({...form,explanation:restoreQuestionText(event.target.value,form.explanation)})}/></Field>{questionImageIds(form.explanation).length>0&&<div className="question-editor-preview"><QuestionContent text={form.explanation} media={form.media}/></div>}<div className="form-grid"><Field label="题目来源"><input required value={form.source} onChange={event=>setForm({...form,source:event.target.value})} placeholder="例如：教师自编 / 授权教材"/></Field><Field label="授权记录"><input required value={form.authorization} onChange={event=>setForm({...form,authorization:event.target.value})} placeholder="授权编号或校内使用说明"/></Field></div>
      <FormError error={formError}/><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={()=>setEditing(false)}>取消</Button><Button disabled={busy}>{busy?'正在保存…':'保存并发布'}</Button></div>
    </form></Modal>}
    {preview&&<Modal wide title="题目预览" description={`${subjects.find(item=>item.id===preview.subject_id)?.name||''} · ${TYPES[preview.type]} · ${preview.source}`} onClose={()=>setPreview(null)}><div className="question-preview"><Badge status={preview.status}>{labelFor(preview.status)}</Badge><h3><QuestionContent text={preview.stem} media={preview.media}/></h3>{preview.options?.map(option=><div key={option.key} className={`preview-option ${preview.answer?.includes(option.key)?'correct':''}`}><b>{option.key}</b><span><QuestionContent text={option.text} media={preview.media}/></span>{preview.answer?.includes(option.key)&&<Icon name="check" size={17}/>}</div>)}<div className="answer-explanation"><strong>参考答案：{formatQuestionAnswer(preview)}</strong><p><QuestionContent text={preview.explanation} media={preview.media}/></p></div><small className="subtle-text">来源：{preview.source}<br/>授权：{preview.authorization||'—'}</small></div><div className="form-actions"><Button variant="secondary" onClick={()=>setPreview(null)}>关闭</Button><Button onClick={()=>{setPreview(null);open(preview);}}>编辑题目</Button></div></Modal>}
    {importOpen&&<QuestionImportModal notify={notify} onClose={()=>setImportOpen(false)} onImported={reload}/>}
    {wordOpen&&<WordImportModal ui={ui} notify={notify} onClose={()=>setWordOpen(false)} onImported={reload}/>}
    {historyOpen&&<ImportHistoryModal ui={ui} notify={notify} onClose={()=>setHistoryOpen(false)} onChanged={reload}/>}
    {classifying&&<Modal title="调整题目科目" description={`已选择 ${classifying.length} 道题目，确认目标科目后统一调整。`} onClose={busy?()=>{}:()=>setClassifying(null)}><form onSubmit={classify}><div className="bank-classification-preview"><span>当前科目</span><div><span className="bank-source-tag">{subjectName(classificationSource)}<b>{classifying.length} 道</b></span></div></div><Field label="目标科目"><select required value={targetSubject} onChange={event=>setTargetSubject(event.target.value)}><option value="">请选择科目</option>{subjects.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></Field>{targetSubject&&<div className="bank-target-preview"><Icon name="arrow" size={18}/><span>调整至 <strong>{subjectName(targetSubject)}</strong> · {classifying.length} 道</span></div>}<p className="form-intro">题目内容和上下线状态保留。已发布题目调整后立即用于目标科目的新练习和组卷；历史作答与成绩保留。</p><FormError error={classificationError}/><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={()=>setClassifying(null)}>取消</Button><Button disabled={busy||!targetSubject}>{busy?'正在调整…':'确认调整科目'}</Button></div></form></Modal>}
    {managingSubjects&&<Modal wide title="管理题库科目" description="科目直接对应题目列表，新增或改名后即可整理题目。" onClose={busy?()=>{}:()=>setManagingSubjects(false)}><form className="bank-new-subject" onSubmit={event=>saveSubject(event)}><Field label="新科目名称"><input required maxLength={100} value={newSubject} disabled={busy} placeholder="例如：语文、数学、英语" onChange={event=>setNewSubject(event.target.value)}/></Field><Button disabled={busy||!newSubject.trim()} icon="plus">新增科目</Button></form><FormError error={subjectError}/><div className="bank-subject-list">{subjects.map(item=><div className="bank-subject-manage-row" key={item.id}>{renaming?.id===item.id?<form onSubmit={event=>saveSubject(event,true)}><Field label={`科目名称：${item.name}`}><input autoFocus required maxLength={100} value={renaming.name} disabled={busy} onChange={event=>setRenaming({...renaming,name:event.target.value})}/></Field><div><button type="button" className="text-btn" disabled={busy} onClick={()=>setRenaming(null)}>取消</button><Button disabled={busy||!renaming.name.trim()}>保存名称</Button></div></form>:<><div><strong>{item.name}</strong><small>{subjectTotals.find(value=>value.id===item.id)?.total||0} 道题目</small></div><button type="button" className="text-btn" disabled={busy} onClick={()=>{setRenaming({id:item.id,name:item.name});setSubjectError('');}}>改名</button></>}</div>)}</div><p className="form-intro">学生可见的科目范围在“考试与科目”中配置。</p><div className="form-actions"><Button type="button" disabled={busy} onClick={()=>setManagingSubjects(false)}>完成</Button></div></Modal>}
  </>;
}
