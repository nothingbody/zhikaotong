import React, { useEffect, useMemo, useState } from 'react';
import { api, post } from './api';
import './word-import-ios.css';
import QuestionContent from './QuestionContent';
import { editableQuestionText, restoreQuestionText, questionImageIds } from './question-media';
import { WORD_SUBJECTS as SUBJECTS, UNKNOWN_SUBJECT_REASON, isContentBlocked, hasAnswer, canImportWordQuestion } from './word-import-scope';

const TYPES = { single: '单选题', multiple: '多选题', fill: '填空题', judge: '判断题' };
const PAGE_SIZE = 20;

export function formatQuestionAnswer(question) {
  if (question?.type === 'fill') return (question.answer || []).map((values, index) => `第${index + 1}空：${(Array.isArray(values) ? values : [values]).join(' / ')}`).join('；');
  if (question?.type === 'judge') return (question.answer || []).map(value => value === 'A' ? '正确' : value === 'B' ? '错误' : value).join('、');
  return (question?.answer || []).join('、');
}

export function FillAnswerEditor({ answer, onChange, disabled = false, prefix = '填空答案' }) {
  const slots = answer?.length ? answer.map(value => Array.isArray(value) ? value : [String(value)]) : [['']];
  return <div className="fill-editor">
    <div className="fill-editor-title"><strong>逐空设置参考答案</strong><small>按空格顺序填写；同一空的可接受写法用 | 分隔。</small></div>
    {slots.map((values, index) => <div className="fill-slot" key={index}>
      <label htmlFor={`${prefix}-${index}`}>第 {index + 1} 空</label>
      <input id={`${prefix}-${index}`} disabled={disabled} value={values.join(' | ')} placeholder="例如：车床 | 普通车床" onChange={event => onChange(slots.map((slot, i) => i === index ? event.target.value.split('|').map(value => value.trim()) : slot))} />
      <button type="button" className="text-btn" disabled={disabled || slots.length <= 1} aria-label={`删除第${index + 1}空`} onClick={() => onChange(slots.filter((_, i) => i !== index))}>删除</button>
    </div>)}
    <button type="button" className="text-btn" disabled={disabled || slots.length >= 20} onClick={() => onChange([...slots, ['']])}>＋ 增加一空</button>
  </div>;
}

async function fileBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = () => reject(new Error('无法读取文件，请重新选择。'));
    reader.readAsDataURL(file);
  });
}

function QuestionCorrection({ question, ui, onSave, onCancel }) {
  const { Field, Button, FormError } = ui;
  const [stem, setStem] = useState(question.stem || '');
  const [answer, setAnswer] = useState(question.answer || []);
  const [explanation, setExplanation] = useState(question.explanation || '');
  const [error, setError] = useState('');
  const submit = event => {
    event.preventDefault();
    const normalized = question.type === 'fill' ? answer.map(slot => [...new Set(slot.map(value => value.trim()).filter(Boolean))]) : answer;
    if (!stem.trim() || !hasAnswer({ ...question, answer: normalized })) { setError('请填写完整题干及每一空／选项的正确答案。'); return; }
    onSave({ stem: stem.trim(), answer: normalized, options: question.type === 'fill' ? [] : question.options, ...(explanation.trim() ? { explanation: explanation.trim() } : {}) });
  };
  return <form className="word-correction" onSubmit={submit}>
    <Field label="校对题干"><textarea rows={5} value={editableQuestionText(stem)} required onChange={event => setStem(restoreQuestionText(event.target.value,stem))} /></Field>{questionImageIds(stem).length>0&&<div className="question-editor-preview"><small>原图已保留，校对文字时无需重新上传。</small><QuestionContent text={stem} media={question.media}/></div>}
    {question.type === 'fill' ? <FillAnswerEditor answer={answer} onChange={setAnswer} prefix={`word-fill-${question.source_key}`} /> : <fieldset className="word-choice-editor"><legend>校对正确答案</legend>{(question.options || []).map(option => <label key={option.key}><input type={question.type === 'multiple' ? 'checkbox' : 'radio'} name={`word-answer-${question.source_key}`} checked={answer.includes(option.key)} onChange={() => setAnswer(question.type === 'multiple' ? answer.includes(option.key) ? answer.filter(value => value !== option.key) : [...answer, option.key] : [option.key])} /><b>{option.key}</b><span><QuestionContent text={option.text} media={question.media}/></span></label>)}</fieldset>}
    <Field label="补充解析（可选）"><textarea rows={2} value={editableQuestionText(explanation)} onChange={event => setExplanation(restoreQuestionText(event.target.value,explanation))} /></Field>
    <FormError error={error} />
    <div className="form-actions"><Button type="button" variant="secondary" onClick={onCancel}>取消校对</Button><Button>保存校对结果</Button></div>
  </form>;
}

export default function WordImportModal({ ui, onClose, onImported, notify }) {
  const { Modal, Field, Button, Loading, FormError } = ui;
  const [files, setFiles] = useState([]), [fileId, setFileId] = useState(''), [localError, setLocalError] = useState('');
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [preview, setPreview] = useState(null), [selected, setSelected] = useState(new Set());
  const [authorization, setAuthorization] = useState(''), [subjectMap, setSubjectMap] = useState({}), [createSubjects, setCreateSubjects] = useState(true);
  const [defaultSubjectId, setDefaultSubjectId] = useState('');
  const [subjectFilter, setSubjectFilter] = useState('all');
  const [filter, setFilter] = useState('all'), [page, setPage] = useState(0), [editing, setEditing] = useState(null), [overrides, setOverrides] = useState({}), [result, setResult] = useState(null);
  useEffect(() => {
    let active = true;
    api('/management/imports/word/local').then(data => { if (active) { setFiles(data.files || []); setFileId(data.files?.[0]?.id || ''); } }).catch(reason => { if (active) setLocalError(reason.message); });
    return () => { active = false; };
  }, []);
  const candidates = useMemo(() => (preview?.questions || []).map(question => ({ ...question, ...overrides[question.source_key], corrected: Boolean(overrides[question.source_key]) })), [preview, overrides]);
  const manuallyMapped = question => !SUBJECTS[question.subject_hint] && Boolean(defaultSubjectId);
  const selectable = question => canImportWordQuestion(question, defaultSubjectId);
  const visible = candidates.filter(question => (subjectFilter === 'all' || (subjectFilter === 'unknown' ? !SUBJECTS[question.subject_hint] : question.subject_hint === subjectFilter)) && (filter === 'selected' ? selected.has(question.source_key) : filter === 'blocked' ? !selectable(question) : filter === 'ready' ? selectable(question) : filter === 'all' || question.type === filter));
  const pages = Math.max(1, Math.ceil(visible.length / PAGE_SIZE));
  const rows = visible.slice(Math.min(page, pages - 1) * PAGE_SIZE, (Math.min(page, pages - 1) + 1) * PAGE_SIZE);
  const selectedCandidates = candidates.filter(question => selected.has(question.source_key));
  const subjectHints = [...new Set(candidates.map(question => question.subject_hint).filter(hint => SUBJECTS[hint]))];
  const unknownSubjects = candidates.filter(question => !SUBJECTS[question.subject_hint]);
  const subjectCounts = useMemo(() => {
    const counts = {};
    for (const question of candidates) {
      const hint = SUBJECTS[question.subject_hint] ? question.subject_hint : 'unknown';
      counts[hint] ||= { total: 0, eligible: 0, judge: 0 };
      counts[hint].total += 1;
      counts[hint].eligible += Number(selectable(question));
      counts[hint].judge += Number(question.type === 'judge');
    }
    return counts;
  }, [candidates, defaultSubjectId]);
  const selectedHints = [...new Set(selectedCandidates.map(question => question.subject_hint).filter(Boolean))];
  const missingMapping = selectedHints.filter(hint => SUBJECTS[hint] ? !subjectMap[hint] && !createSubjects : !defaultSubjectId);
  const defaultSubject = preview?.subjects?.find(subject => subject.id === defaultSubjectId);
  const manualReadyCount = unknownSubjects.filter(selectable).length;
  const complete = result && !result.errors?.length;
  const toggle = question => { if (!selectable(question) || busy || complete) return; setSelected(previous => { const next = new Set(previous); next.has(question.source_key) ? next.delete(question.source_key) : next.add(question.source_key); return next; }); };
  const recognize = async payload => {
    setBusy(true); setError(''); setResult(null); setEditing(null); setPreview(null); setSelected(new Set()); setOverrides({}); setDefaultSubjectId('');
    try {
      const response = await post('/management/imports/word/preview', payload);
      setPreview(response); setOverrides({}); setPage(0); setFilter('all'); setSubjectFilter('all');
      setSelected(new Set((response.questions || []).filter(question => question.eligible && SUBJECTS[question.subject_hint] && !isContentBlocked(question) && hasAnswer(question)).map(question => question.source_key)));
      const mapping = {};
      for (const hint of Object.keys(SUBJECTS)) {
        const known = (response.subjects || []).find(subject => subject.id === hint || subject.name === SUBJECTS[hint] || hint === 'mechanics' && /机械/.test(subject.name));
        if (known) mapping[hint] = known.id;
      }
      setSubjectMap({ ...mapping, ...(response.subject_map || {}) });
    } catch (reason) { setError(reason.message); } finally { setBusy(false); }
  };
  const upload = async event => {
    const file = event.target.files?.[0];
    if (!file) return;
    if (!/\.docx$/i.test(file.name) || file.size > 15 * 1024 * 1024) { setError('请选择15MB以内的 .docx 文件；旧版 .doc 请先另存为 .docx。'); event.target.value = ''; return; }
    setBusy(true); setError('');
    try { const encoded = await fileBase64(file); await recognize({ filename: file.name, content_base64: encoded }); }
    catch (reason) { setError(reason.message); setBusy(false); }
    finally { event.target.value = ''; }
  };
  const commit = async () => {
    if (!authorization.trim()) { setError('请填写题库来源的授权记录或校内使用说明。'); return; }
    if (!selected.size) { setError('请至少选择一道已核对完整的题目。'); return; }
    if (missingMapping.length) { setError(`请为${missingMapping.map(hint => SUBJECTS[hint] || hint).join('、')}指定科目，或确认创建缺少的科目。`); return; }
    setBusy(true); setError('');
    try {
      const response = await post('/management/imports/word/commit', { preview_id: preview.preview_id, source_keys: [...selected], authorization: authorization.trim(), subject_map: subjectMap, ...(defaultSubjectId ? { default_subject_id: defaultSubjectId } : {}), create_missing_subjects: createSubjects, overrides });
      setResult(response);
      if (!response.errors?.length) { onImported(response.batch_id); notify(`Word导入完成：新增并发布${response.created}道题目，跳过${response.duplicates || 0}道重复题。`); }
    } catch (reason) { setError(reason.message); } finally { setBusy(false); }
  };
  return <Modal wide title="Word题库自动识别" description="自动识别选择、填空和判断题，并按原文科目分科；机械绘制等操作题排除，确认导入后立即发布。" onClose={busy ? () => {} : onClose}>
    <div className="word-source-area">
      <div className="word-local-source"><Field label="服务器已有Word文件"><select value={fileId} onChange={event => setFileId(event.target.value)} disabled={busy || complete}><option value="">{files.length ? '请选择文件' : '暂无配置的本地题库'}</option>{files.map(file => <option key={file.id} value={file.id}>{file.name}（{(file.size / 1024 / 1024).toFixed(1)}MB）</option>)}</select></Field><Button type="button" variant="secondary" disabled={busy || !fileId || complete} onClick={() => recognize({ local_file_id: fileId })}>识别已有Word</Button></div>
      {localError && <p className="word-local-message">本地文件列表暂不可用，可使用上传入口。{localError}</p>}
      <Field label="或上传Word题库" hint="支持 .docx，最大15MB；识别预览不发布，确认导入后立即生效。"><input type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document" disabled={busy || complete} onChange={upload} /></Field>
    </div>
    {busy && !preview && <Loading />}
    {preview && <>
      <div className="word-preview-title"><strong>{preview.filename}</strong><small>请核对答案、材料上下文及题型归类</small></div>
      <div className="word-summary">{[['识别题目', candidates.length], ['原文可导入', candidates.filter(selectable).length], ['需人工核对', candidates.filter(question => !selectable(question)).length], ['已排除', preview.summary?.excluded ?? preview.excluded?.length ?? 0]].map(([label, count]) => <div key={label}><strong>{count}</strong><span>{label}</span></div>)}</div>
      {Number.isInteger(preview.summary?.unique_eligible)&&Number.isInteger(preview.summary?.duplicate_eligible)&&<div className="word-dedup-area"><div className="word-dedup-summary" aria-label="Word去重统计"><div><strong>{preview.summary.unique_eligible}</strong><span>去重后题目</span></div><div><strong>{preview.summary.duplicate_eligible}</strong><span>原文重复</span></div></div><p>原文小题与去重后题目分别统计。同一内容在原文重复出现时，导入只保留一道；校对修改后的数量以导入结果为准。</p></div>}
      <section className="word-subject-summary" aria-label="自动分科结果"><div><strong>自动分科结果</strong><small>按文档科目标题和章节识别，点击科目查看对应题目。</small></div><div className="word-subject-cards">{Object.entries(subjectCounts).map(([hint, count]) => <button type="button" key={hint} className={subjectFilter === hint ? 'active' : ''} onClick={() => { setSubjectFilter(subjectFilter === hint ? 'all' : hint); setPage(0); }}><strong>{SUBJECTS[hint] || '科目待核对'}</strong><span>{count.total}题 · 可导入{count.eligible}题</span>{Number.isInteger(preview.summary?.by_subject?.[hint]?.unique_eligible)&&<small>原文可导入{count.eligible}题 / 去重后{preview.summary.by_subject[hint].unique_eligible}题</small>}{count.judge > 0 && <small>含判断题{count.judge}题</small>}</button>)}</div></section>
      {unknownSubjects.length > 0 && <section className="word-import-settings" aria-label="未识别科目人工指定"><h3>人工指定未识别科目</h3><p>有{unknownSubjects.length}道候选题无法从原文确定科目。请先核对它们是否属于同一科目，再选择目标；不同科目请分别上传。已自动识别的语文、数学、英语、政治、机械题不会受此设置影响。</p><Field label="未识别科目导入到" hint="仅允许选择已建立的真实科目。原文缺答案、题图、公式或材料的问题仍需处理。"><select value={defaultSubjectId} disabled={busy || complete} onChange={event => { setDefaultSubjectId(event.target.value); setSelected(previous => new Set([...previous].filter(key => !unknownSubjects.some(question => question.source_key === key)))); }}><option value="">保持待核对，不导入</option>{(preview.subjects || []).map(subject => <option key={subject.id} value={subject.id}>{subject.name}</option>)}</select></Field>{defaultSubject && <div className="inline-note">人工指定为“{defaultSubject.name}”：覆盖{unknownSubjects.length}道未识别候选题，其中{manualReadyCount}道内容及答案完整，可手动勾选导入。当前已选{selectedCandidates.filter(manuallyMapped).length}道。</div>}</section>}
      <div className="inline-note word-scope-note">机械绘图操作题不导入；涉及机械制图知识的文字选择题仍保留。含无法完整提取的图片、公式或缺失材料的题目会标为待核对，避免导入残缺题干。</div>
      {(preview.warnings || []).length > 0 && <details className="word-exclusions"><summary>文档识别提示（{preview.warnings.length}）</summary>{preview.warnings.map((warning, index) => <p key={index}>{String(warning)}</p>)}</details>}
      <div className="word-filter-bar"><div className="word-filter-selects"><label>显示范围<select aria-label="Word预览筛选" value={filter} onChange={event => { setFilter(event.target.value); setPage(0); }}><option value="all">全部候选题</option><option value="ready">可导入</option><option value="blocked">待人工核对</option><option value="selected">已勾选</option><option value="single">单选题</option><option value="multiple">多选题</option><option value="fill">填空题</option><option value="judge">判断题</option></select></label><label>科目<select aria-label="Word科目筛选" value={subjectFilter} onChange={event => { setSubjectFilter(event.target.value); setPage(0); }}><option value="all">全部科目</option>{subjectHints.map(hint => <option key={hint} value={hint}>{SUBJECTS[hint]}</option>)}{unknownSubjects.length > 0 && <option value="unknown">科目待核对</option>}</select></label></div><div><button type="button" className="text-btn" disabled={busy || complete} onClick={() => setSelected(new Set(candidates.filter(selectable).map(question => question.source_key)))}>选中全部可导入题</button><button type="button" className="text-btn" disabled={busy || complete} onClick={() => setSelected(new Set())}>清空选择</button></div></div>
      <div className="word-candidate-list">{rows.map(question => <article key={question.source_key} className={`word-candidate ${!selectable(question) ? 'blocked' : ''}`}>
        <div className="word-candidate-heading"><label><input type="checkbox" aria-label={`选择题目${question.source_label || question.source_index}`} checked={selected.has(question.source_key)} disabled={busy || complete || !selectable(question)} onChange={() => toggle(question)} /><strong>{question.source_label || `第${question.source_index}题`}</strong><span>{TYPES[question.type] || question.type}</span></label><span>{SUBJECTS[question.subject_hint] || (manuallyMapped(question) ? `${defaultSubject?.name}（人工指定）` : '科目待核对')} · {question.corrected ? '已校对' : selectable(question) ? '可导入' : '待核对'}</span></div>
        <small className="word-provenance">{question.section || question.source_section || '原文段落'}{question.source_index !== undefined ? ` · 来源位置${question.source_index}` : ''}</small>
        {editing === question.source_key ? <QuestionCorrection key={question.source_key} question={question} ui={ui} onCancel={() => setEditing(null)} onSave={override => { setOverrides(previous => ({ ...previous, [question.source_key]: override })); setEditing(null); if (canImportWordQuestion({ ...question, ...override, corrected: true }, defaultSubjectId)) setSelected(previous => new Set([...previous, question.source_key])); }} /> : <>
          <p className="word-stem"><QuestionContent text={question.stem || '题干缺失'} media={question.media}/></p>
          {!!question.options?.length && <div className="word-options">{question.options.map(option => <p key={option.key}><b>{option.key}.</b> <QuestionContent text={option.text} media={question.media}/></p>)}</div>}
          <p className="word-answer"><strong>参考答案：</strong>{hasAnswer(question) ? formatQuestionAnswer(question) : '原文未可靠识别，请人工补充'}</p>
          {(question.blocked_reasons || []).length > 0 && <ul className="word-warning-list">{question.blocked_reasons.map((reason, index) => <li key={index}>{manuallyMapped(question) && reason === UNKNOWN_SUBJECT_REASON ? `原科目未识别，已人工指定为：${defaultSubject?.name}` : String(reason)}</li>)}</ul>}
          {(question.warnings || []).length > 0 && <ul className="word-warning-list mild">{question.warnings.map((reason, index) => <li key={index}>{String(reason)}</li>)}</ul>}
          {!SUBJECTS[question.subject_hint] && !manuallyMapped(question) ? <p className="word-blocked-note">原文科目尚未确定，请在上方人工指定目标科目，或补充科目标题后重新识别。</p> : isContentBlocked(question, manuallyMapped(question)) ? <p className="word-blocked-note">该题原图、公式或材料仍未完整保留，暂不能导入。请先补全来源内容。</p> : <button type="button" className="text-btn" disabled={busy || complete} onClick={() => setEditing(question.source_key)}>校对题干与答案</button>}
        </>}
      </article>)}{!rows.length && <p className="word-empty">当前筛选下没有题目。</p>}</div>
      <div className="word-pagination"><Button type="button" variant="secondary" disabled={page <= 0 || busy} onClick={() => setPage(value => value - 1)}>上一页</Button><span>第{Math.min(page + 1, pages)} / {pages}页 · 共{visible.length}题 · 每页{PAGE_SIZE}题</span><Button type="button" variant="secondary" disabled={page >= pages - 1 || busy} onClick={() => setPage(value => value + 1)}>下一页</Button></div>
      {(preview.excluded || []).length > 0 && <details className="word-exclusions"><summary>查看已排除题目／段落（{preview.summary?.excluded ?? preview.excluded.length}）</summary>{preview.excluded.slice(0, 50).map((item, index) => <p key={index}><strong>{item.source_label || item.section || '原文段落'}</strong>：{item.reason}</p>)}{preview.excluded.length > 50 && <small>仅展开前50条排除记录。</small>}</details>}
      <section className="word-import-settings"><h3>自动分科与导入</h3><p className="word-auto-map-note">已按原文识别科目并自动匹配题库。已有科目直接归入；缺少的已识别科目按下方设置创建。科目无法确定的题保留待核对。</p><details className="word-mapping-details"><summary>核对或调整科目对应关系</summary><div className="form-grid">{subjectHints.map(hint => <Field key={hint} label={`${SUBJECTS[hint] || hint}导入到`}><select value={subjectMap[hint] || ''} disabled={busy || complete} onChange={event => setSubjectMap(previous => ({ ...previous, [hint]: event.target.value }))}><option value="">{createSubjects && SUBJECTS[hint] ? '自动创建该科目' : '请选择科目'}</option>{(preview.subjects || []).map(subject => <option key={subject.id} value={subject.id}>{subject.name}</option>)}</select></Field>)}</div></details><label className="word-create-subjects"><input type="checkbox" checked={createSubjects} disabled={busy || complete} onChange={event => setCreateSubjects(event.target.checked)} /><span>自动创建识别到的缺失科目（不改变现有考试方案或科目组）</span></label><Field label="本次题库授权记录" hint="填写学校已确认的来源授权、编写记录或使用说明；系统不会替你生成授权证明。"><textarea rows={2} required maxLength={1000} value={authorization} disabled={busy || complete} onChange={event => setAuthorization(event.target.value)} placeholder="请输入真实来源与校内使用依据" /></Field></section>
      {result && <div className={result.errors?.length ? 'form-error' : 'success-panel'} role="status">{result.errors?.length ? result.errors.map((item, index) => <p key={index}>{item.source_label || `第${item.row || index + 1}题`}：{item.message}</p>) : `已导入并发布${result.created}道题目，跳过${result.duplicates || 0}道重复题。可在导入记录中撤回本批次，历史答题和成绩保留。`}</div>}
    </>}
    <FormError error={error} />
    <div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={onClose}>{complete ? '完成' : '关闭'}</Button>{preview && !complete && <Button type="button" disabled={busy || !selected.size} onClick={commit}>{busy ? '正在处理…' : `导入并发布${selected.size}道题目`}</Button>}</div>
  </Modal>;
}
