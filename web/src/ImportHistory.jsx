import React, { useEffect, useState } from 'react';
import { api, post } from './api';

export default function ImportHistoryModal({ ui, onClose, onChanged, notify }) {
  const { Modal, Button, Loading, FormError } = ui;
  const [batches, setBatches] = useState([]), [loading, setLoading] = useState(true), [busyId, setBusyId] = useState(''), [error, setError] = useState('');
  const load = async () => {
    setLoading(true);
    try { setBatches(await api('/management/questions/import/batches')); }
    catch (reason) { setError(reason.message); }
    finally { setLoading(false); }
  };
  useEffect(() => { load(); }, []);
  const rollback = async batch => {
    if (!window.confirm(`确定撤回此批次当前保留的${batch.remaining_count || 0}道题目？撤回后不再用于新练习和组卷，历史答题记录与成绩保留。`)) return;
    const id = batch.id || batch.batch_id;
    setBusyId(id); setError('');
    try {
      const response = await post(`/management/questions/import/${encodeURIComponent(id)}/rollback`);
      notify(`已撤回 ${response.rolled_back} 道题目，历史答题记录与成绩保留。`);
      onChanged(id);
      await load();
    } catch (reason) { setError(reason.message); }
    finally { setBusyId(''); }
  };
  const date = value => value ? new Date(value).toLocaleString('zh-CN', { year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }) : '—';
  return <Modal wide title="题库导入记录" description="导入后自动发布。可撤回本批次题目，历史答题记录与成绩保留；相同来源再次导入不会自动恢复已撤回题目。" onClose={busyId ? () => {} : onClose}>
    <FormError error={error} />
    {loading ? <Loading /> : batches.length ? <div className="table-wrap"><table><thead><tr>{['导入时间 / 操作人', '类型', '导入数量', '当前题目', '状态', '操作'].map(label => <th key={label}>{label}</th>)}</tr></thead><tbody>{batches.map(batch => <tr key={batch.id || batch.batch_id}>
      <td>{date(batch.created_at)}<small className="table-sub">{batch.creator_name || '管理员'}</small></td>
      <td>{batch.kind === 'word' ? 'Word' : 'Excel'}</td>
      <td>{batch.created_count ?? '—'}</td><td>{batch.remaining_count ?? '—'}</td>
      <td><span className={`badge ${batch.status === 'rolled_back' ? 'gray' : 'green'}`}>{batch.status === 'rolled_back' ? '已撤回' : '已导入'}</span></td>
      <td>{batch.status === 'rolled_back' || !Number(batch.remaining_count) ? <span className="subtle-text">—</span> : <button type="button" className="text-btn danger-text" disabled={Boolean(busyId)} onClick={() => rollback(batch)}>{busyId === (batch.id || batch.batch_id) ? '正在撤回…' : '撤回本批次'}</button>}</td>
    </tr>)}</tbody></table></div> : <p className="word-empty">服务器上暂无导入记录。</p>}
    <div className="form-actions"><Button type="button" variant="secondary" disabled={loading || Boolean(busyId)} onClick={() => { setError(''); load(); }}>刷新记录</Button><Button type="button" disabled={Boolean(busyId)} onClick={onClose}>完成</Button></div>
  </Modal>;
}
