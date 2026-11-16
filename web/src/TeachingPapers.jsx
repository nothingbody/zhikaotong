import React, { useCallback, useEffect, useState } from 'react';
import { api, post } from './api';
import { formatQuestionAnswer } from './WordImport';
import QuestionContent from './QuestionContent';
import './teaching-papers.css';

const types = { single: '单选题', multiple: '多选题', fill: '填空题', judge: '判断题' };
const number = value => Number(value || 0).toLocaleString('zh-CN');
const time = value => value ? new Date(value).toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—';
const available = (catalog, rule) => Number(catalog.subjects.find(subject => subject.id === rule.subject_id)?.available?.[rule.type] || 0);
const initialRule = catalog => {
  const subject = catalog.subjects.find(item => Object.values(item.available || {}).some(count => Number(count) > 0)) || catalog.subjects[0];
  const type = Object.keys(types).find(kind => Number(subject?.available?.[kind]) > 0) || 'single';
  return { subject_id: subject?.id || '', type, count: Math.min(10, Number(subject?.available?.[type] || 1)), score: 1, difficulty: '' };
};

export default function TeachingPapersPage({ notify, ui }) {
  const { Button, Field, Modal, Loading, Empty, Table, FormError } = ui;
  const [data, setData] = useState(null), [loading, setLoading] = useState(true), [error, setError] = useState('');
  const [tab, setTab] = useState('papers'), [modal, setModal] = useState(null), [busy, setBusy] = useState(false), [formError, setFormError] = useState('');
  const [form, setForm] = useState(null), [paper, setPaper] = useState(null), [selectedClasses, setSelectedClasses] = useState([]), [results, setResults] = useState(null);
  const load = useCallback(async () => {
    setLoading(true); setError('');
    try {
      const [catalog, papers, assignments] = await Promise.all([api('/teaching/catalog'), api('/teaching/papers'), api('/teaching/assignments')]);
      setData({ catalog, papers, assignments });
    } catch (failure) { setError(failure.message); }
    finally { setLoading(false); }
  }, []);
  useEffect(() => { load(); }, [load]);
  const catalog = data?.catalog || { subjects: [], classes: [] };
  const subjectName = id => catalog.subjects.find(subject => subject.id === id)?.name || id;
  const close = () => { if (!busy) { setModal(null); setFormError(''); } };
  const create = () => {
    setForm({ title: '', rules: [initialRule(catalog)], shuffle_questions: true, shuffle_options: true });
    setFormError(''); setModal('create');
  };
  const changeRule = (index, changes) => setForm(current => ({ ...current, rules: current.rules.map((rule, i) => i === index ? { ...rule, ...changes } : rule) }));
  const preview = async id => {
    setBusy(true); setFormError('');
    try { setPaper(await api(`/teaching/papers/${id}`)); setModal('preview'); }
    catch (failure) { notify(failure.message, 'error'); }
    finally { setBusy(false); }
  };
  const submitPaper = async event => {
    event.preventDefault(); setFormError('');
    const total = form.rules.reduce((sum, rule) => sum + Number(rule.count), 0);
    if (total < 1 || total > 100) { setFormError('每份试卷需要 1 至 100 道题。'); return; }
    setBusy(true);
    try {
      const payload = { ...form, title: form.title.trim(), rules: form.rules.map(rule => ({ ...rule, count: Number(rule.count), score: Number(rule.score), ...(rule.difficulty ? { difficulty: Number(rule.difficulty) } : {}) })) };
      payload.rules.forEach(rule => { if (rule.difficulty === '') delete rule.difficulty; });
      const created = await post('/teaching/papers', payload);
      setPaper(created.questions ? created : await api(`/teaching/papers/${created.id}`));
      setModal('preview');
      await load();
    } catch (failure) { setFormError(failure.message); }
    finally { setBusy(false); }
  };
  const openAssign = selected => { setPaper(selected); setSelectedClasses([]); setFormError(''); setModal('assign'); };
  const paperSubjects = new Set((paper?.rules || []).map(rule => rule.subject_id));
  const eligibleClasses = catalog.classes.filter(item => [...paperSubjects].every(id => (item.subject_ids || []).includes(id)));
  const assign = async event => {
    event.preventDefault(); setBusy(true); setFormError('');
    try {
      const response = await post(`/teaching/papers/${paper.id}/assign`, { class_ids: selectedClasses });
      setModal(null); setTab('assignments'); notify(`已向 ${response.assignments.length} 个班级布置练习。`); await load();
    } catch (failure) { setFormError(failure.message); }
    finally { setBusy(false); }
  };
  const showResults = async assignment => {
    setBusy(true);
    try { setResults(await api(`/teaching/assignments/${assignment.id}/results`)); setModal('results'); setFormError(''); }
    catch (failure) { notify(failure.message, 'error'); }
    finally { setBusy(false); }
  };
  const publishedCount = catalog.subjects.reduce((sum, item) => sum + Object.values(item.available || {}).reduce((n, value) => n + Number(value), 0), 0);
  return <>
    <div className="page-heading"><div><div className="page-kicker">教学管理 / CLASS PRACTICE</div><h1>组卷与布置</h1><p>从学校已发布题库抽题，布置班级练习并查看完成情况。</p></div><div className="heading-actions"><Button icon="refresh" variant="secondary" disabled={loading || busy} onClick={load}>刷新</Button><Button icon="plus" disabled={loading || busy || !publishedCount} onClick={create}>自动组卷</Button></div></div>
    <div className="inline-note"><span>学生只使用学校已发布题库和教师布置的练习；没有创建、上传或修改题库的权限。这里的试卷为班级练习，当前不设置考试计时或截止时间。</span></div>
    {loading ? <Loading /> : error ? <div className="error-panel"><span>{error}</span><Button variant="secondary" onClick={load}>重试</Button></div> : <>
      <div className="teaching-overview"><div><span>可抽取题目</span><strong>{number(publishedCount)}</strong><small>仅统计已发布的学校题库</small></div><div><span>我的试卷</span><strong>{number(data.papers.length)}</strong><small>生成后保留题目快照</small></div><div><span>班级练习</span><strong>{number(data.assignments.length)}</strong><small>仅管理自己布置的练习</small></div></div>
      <section className="panel"><div className="toolbar"><div className="tabs"><button className={tab === 'papers' ? 'active' : ''} onClick={() => setTab('papers')}>我的试卷</button><button className={tab === 'assignments' ? 'active' : ''} onClick={() => setTab('assignments')}>已布置练习</button></div><span className="subtle-text">题库维护由学校管理员负责</span></div>
        {tab === 'papers' ? data.papers.length ? <div className="teaching-list">{data.papers.map(item => <article className="teaching-card" key={item.id}><div className="teaching-card-main"><h2>{item.title}</h2><p>{number(item.question_count)} 道题 · 满分 {number(item.full_score)} 分 · {time(item.created_at)}</p><div className="teaching-tags"><span>{item.shuffle_questions ? '题目乱序' : '题目顺序'}</span><span>{item.shuffle_options ? '选项乱序' : '选项顺序'}</span></div></div><div className="teaching-card-actions"><Button variant="secondary" disabled={busy} onClick={() => preview(item.id)}>预览试卷</Button><Button disabled={busy} onClick={() => openAssign(item)}>布置到班级</Button></div></article>)}</div> : <Empty text="还没有生成试卷" detail="选择科目、题型和题量，即可从学校已发布题库自动抽题。" /> : data.assignments.length ? <div className="teaching-list">{data.assignments.map(item => <article className="teaching-card" key={item.id}><div className="teaching-card-main"><h2>{item.paper_title}</h2><p>{item.class_name} · {time(item.created_at)}</p><div className="teaching-completion"><progress value={item.submitted_count} max={Math.max(1, item.recipient_count)} aria-label={`${item.paper_title}完成情况`} /><span>{number(item.submitted_count)} / {number(item.recipient_count)} 人已提交</span></div></div><Button variant="secondary" disabled={busy} onClick={() => showResults(item)}>查看成绩</Button></article>)}</div> : <Empty text="还没有布置班级练习" detail="先生成并核对试卷，再选择自己的班级进行布置。" />}
      </section>
    </>}
    {modal === 'create' && <Modal wide title="自动组卷" description="按科目和题型抽取不重复的题目。可混合多个科目，最多100题。" onClose={close}><form onSubmit={submitPaper} className="teaching-builder"><Field label="试卷名称"><input required maxLength={100} autoFocus value={form.title} onChange={event => setForm({ ...form, title: event.target.value })} placeholder="例如：机械基础每周练习" /></Field><div className="teaching-rule-heading"><h3>抽题规则</h3><span>每行设置一个科目和题型</span></div><div className="teaching-rules">{form.rules.map((rule, index) => <div className="teaching-rule" key={index}><div className="teaching-rule-number">规则 {index + 1}<button type="button" className="text-btn danger-text" disabled={busy || form.rules.length === 1} onClick={() => setForm({ ...form, rules: form.rules.filter((_, i) => i !== index) })}>移除</button></div><div className="teaching-rule-fields"><Field label={`规则${index + 1}科目`}><select value={rule.subject_id} onChange={event => changeRule(index, { subject_id: event.target.value })}>{catalog.subjects.map(subject => <option key={subject.id} value={subject.id}>{subject.name}</option>)}</select></Field><Field label={`规则${index + 1}题型`}><select value={rule.type} onChange={event => changeRule(index, { type: event.target.value })}>{Object.entries(types).map(([key, name]) => <option key={key} value={key}>{name}</option>)}</select></Field><Field label={`规则${index + 1}题数`}><input type="number" min={1} max={100} required value={rule.count} onChange={event => changeRule(index, { count: event.target.value })} /></Field><Field label={`规则${index + 1}每题分值`}><input type="number" min={1} max={100} step={1} required value={rule.score} onChange={event => changeRule(index, { score: event.target.value })} /></Field><Field label={`规则${index + 1}难度`}><select value={rule.difficulty} onChange={event => changeRule(index, { difficulty: event.target.value })}><option value="">不限</option><option value="1">基础</option><option value="2">中等</option><option value="3">较难</option><option value="4">困难</option><option value="5">综合</option></select></Field></div><p className="subtle-text">该科目题型共 {number(available(catalog, rule))} 道可用题；指定难度后的数量以生成结果为准。</p></div>)}</div><Button type="button" variant="secondary" disabled={busy || form.rules.length >= 20} onClick={() => setForm({ ...form, rules: [...form.rules, initialRule(catalog)] })}>＋ 添加抽题规则</Button><div className="teaching-shuffle"><label><input type="checkbox" checked={form.shuffle_questions} onChange={event => setForm({ ...form, shuffle_questions: event.target.checked })} /><span>每位学生题目乱序</span></label><label><input type="checkbox" checked={form.shuffle_options} onChange={event => setForm({ ...form, shuffle_options: event.target.checked })} /><span>选择题选项乱序</span></label><p>判断题、填空题，以及依赖选项原顺序的题目保留原序。重新打开同一练习时顺序保持一致。</p></div><div className="teaching-total">共 <strong>{number(form.rules.reduce((sum, rule) => sum + Number(rule.count), 0))}</strong> 道题 · 满分 <strong>{number(form.rules.reduce((sum, rule) => sum + Number(rule.count) * Number(rule.score), 0))}</strong> 分</div><FormError error={formError} /><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={close}>取消</Button><Button disabled={busy || !form.rules.length}>{busy ? '正在生成…' : '生成试卷'}</Button></div></form></Modal>}
    {modal === 'preview' && paper && <Modal wide title={paper.title} description={`${paper.question_count} 道题 · 已保存题目快照；核对后可布置给班级。`} onClose={close}><div className="teaching-preview">{paper.questions.map((question, index) => <article key={question.id} className="teaching-preview-question"><div className="teaching-question-meta"><span>第 {index + 1} 题 · {subjectName(question.subject_id)} · {types[question.type]}</span><span>{question.score || 1} 分</span></div><h3><QuestionContent text={question.stem} media={question.media}/></h3>{question.options?.length > 0 && <ul>{question.options.map(option => <li key={option.key}><b>{option.key}</b><span><QuestionContent text={option.text} media={question.media}/></span></li>)}</ul>}<div className="teaching-answer"><strong>参考答案：{formatQuestionAnswer(question)}</strong>{question.explanation && <p><QuestionContent text={question.explanation} media={question.media}/></p>}</div></article>)}</div><div className="form-actions"><Button variant="secondary" disabled={busy} onClick={close}>关闭</Button><Button disabled={busy} onClick={() => openAssign(paper)}>布置到班级</Button></div></Modal>}
    {modal === 'assign' && paper && <Modal title="布置到班级" description={paper.title} onClose={close}><form onSubmit={assign}><p className="form-intro">选择自己负责且科目范围匹配的班级，一次最多20个。布置时记录已确认入班的学生名单。</p><div className="teaching-class-list">{eligibleClasses.length ? eligibleClasses.map(item => <label key={item.id}><input type="checkbox" checked={selectedClasses.includes(item.id)} onChange={event => setSelectedClasses(event.target.checked ? [...selectedClasses, item.id] : selectedClasses.filter(id => id !== item.id))} /><span><strong>{item.name}</strong><small>{(item.subject_ids || []).map(subjectName).join('、')}</small></span></label>) : <Empty text="没有可布置的班级" detail="请先创建班级，并确认班级科目范围涵盖这份试卷。" />}</div><FormError error={formError} /><div className="form-actions"><Button type="button" variant="secondary" disabled={busy} onClick={close}>取消</Button><Button disabled={busy || !selectedClasses.length || selectedClasses.length > 20}>{busy ? '正在布置…' : '确认布置'}</Button></div></form></Modal>}
    {modal === 'results' && results && <Modal wide title="班级练习成绩" description={`${results.assignment.paper_title} · ${results.assignment.class_name}`} onClose={close}><div className="teaching-result-summary"><span>已提交 <strong>{number(results.assignment.submitted_count)} / {number(results.assignment.recipient_count)}</strong> 人</span><span>成绩仅包含这次班级练习</span></div><Table headers={['学生', '提交状态', '得分', '答对 / 总题数', '提交时间']} empty={!results.results.length}>{results.results.map(item => <tr key={item.user_id}><td><strong>{item.name || item.username}</strong><small className="teaching-username">{item.username}</small></td><td><span className={`badge ${item.submitted ? 'green' : 'gray'}`}>{item.submitted ? '已提交' : '未提交'}</span></td><td>{item.submitted ? number(item.score) : '—'}</td><td>{item.submitted ? `${number(item.correct)} / ${number(item.total)}` : '—'}</td><td>{time(item.submitted_at)}</td></tr>)}</Table><div className="form-actions"><Button variant="secondary" onClick={close}>关闭</Button></div></Modal>}
  </>;
}
