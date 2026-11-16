import React, { useEffect, useRef, useState } from 'react';
import { api } from './api';
import './student-details.css';

const TYPE_NAMES={single:'单选题',multiple:'多选题',judge:'判断题',fill:'填空题'};
const MEMBER_STATUS={active:'正式成员',pending_confirmation:'待学生确认',pending_approval:'待审批',left:'已退出',rejected:'已拒绝'};
export const displayNumber=value=>Number(value||0).toLocaleString('zh-CN');
export function displayAccuracy(metrics){
  if(!Number(metrics?.answered)||metrics?.accuracy===null||!Number.isFinite(Number(metrics?.accuracy)))return '—';
  return `${Number(metrics.accuracy).toFixed(1)}%`;
}
export function displayDuration(value){
  const seconds=Math.max(0,Math.round(Number(value)||0));
  if(seconds<60)return `${seconds} 秒`;
  const minutes=Math.floor(seconds/60),hours=Math.floor(minutes/60);
  return hours?`${hours} 小时${minutes%60?` ${minutes%60} 分钟`:''}`:`${minutes} 分钟${seconds%60?` ${seconds%60} 秒`:''}`;
}
const displayDate=(value,clock=true)=>{
  if(!value)return '—';
  const date=new Date(value);
  return Number.isNaN(date.getTime())?'—':date.toLocaleString('zh-CN',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',...(clock?{hour:'2-digit',minute:'2-digit'}:{})});
};
function useScopedData(url,refreshVersion=0){
  const [revision,setRevision]=useState(0),[state,setState]=useState({key:'',data:null,loading:false,error:''});
  const key=`${url||''}|${revision}|${refreshVersion}`;
  useEffect(()=>{
    let active=true;
    if(!url){setState({key,data:null,loading:false,error:''});return()=>{active=false;};}
    setState({key,data:null,loading:true,error:''});
    api(url).then(data=>{if(active)setState({key,data,loading:false,error:''});}).catch(error=>{if(active)setState({key,data:null,loading:false,error:error.message});});
    return()=>{active=false;};
  },[key]);
  return {data:state.key===key?state.data:null,loading:Boolean(url)&&(state.key!==key||state.loading),error:state.key===key?state.error:'',reload:()=>setRevision(value=>value+1)};
}
function Resource({state,ui,children}){
  const {Loading,Button}=ui;
  return state.loading?<Loading/>:state.error?<div className="student-resource-error" role="alert"><p>{state.error}</p><Button variant="secondary" onClick={state.reload}>重试</Button></div>:children;
}
function MetricCards({metrics,label}){
  return <div className="student-metric-grid" aria-label={label}>{[
    ['答题次数',displayNumber(metrics?.answered),'含同一道题的重复作答'],
    ['不同题目',displayNumber(metrics?.unique_questions),'按题目去重'],
    ['正确率',displayAccuracy(metrics),`答对 ${displayNumber(metrics?.correct)} 次 · 答错 ${displayNumber(metrics?.wrong)} 次`],
    ['练习用时',displayDuration(metrics?.study_seconds),`活跃 ${displayNumber(metrics?.active_days)} 天`]
  ].map(([name,value,detail])=><div className="student-metric-card" key={name}><span>{name}</span><strong>{value}</strong><small>{detail}</small></div>)}</div>;
}
function TrendChart({daily}){
  const scroll=useRef(null);
  useEffect(()=>{
    const target=scroll.current;if(!target)return;
    const latest=()=>{target.scrollLeft=target.scrollWidth-target.clientWidth;};
    const observer=new ResizeObserver(latest);observer.observe(target);latest();
    return()=>observer.disconnect();
  },[daily]);
  const width=Math.max(620,daily.length*17+84),height=250,left=42,right=44,top=22,bottom=44,plotWidth=width-left-right,plotHeight=height-top-bottom;
  const max=Math.max(2,Math.ceil(Math.max(0,...daily.map(day=>Number(day.answered)||0))/2)*2),step=plotWidth/Math.max(1,daily.length),x=index=>left+step*(index+.5),yCount=value=>top+plotHeight-(Number(value)||0)/max*plotHeight,yRate=value=>top+plotHeight-Number(value)/100*plotHeight;
  const labels=new Set([0,daily.length-1,...daily.map((_,index)=>index).filter(index=>index%Math.max(1,Math.ceil(daily.length/6))===0)]);
  const segments=[];let segment=[];
  daily.forEach((day,index)=>{if(Number(day.answered)>0&&day.accuracy!==null&&Number.isFinite(Number(day.accuracy)))segment.push(`${x(index)},${yRate(day.accuracy)}`);else if(segment.length){segments.push(segment);segment=[];}});if(segment.length)segments.push(segment);
  return <div className="student-trend-scroll" ref={scroll} tabIndex={0} aria-label="每日答题趋势图，可横向滚动"><svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="每日答题次数柱形与正确率折线，左轴次数，右轴百分比" style={{minWidth:width}}>
    <title>每日自主练习趋势</title><desc>蓝色柱为答题次数，绿色折线为正确率；没有作答的日期不绘制正确率点。</desc>
    {[0,.5,1].map(value=><g key={value}><line x1={left} y1={top+plotHeight*(1-value)} x2={width-right} y2={top+plotHeight*(1-value)} stroke="#e8edf5" strokeDasharray="4 5"/><text x={left-8} y={top+plotHeight*(1-value)+4} textAnchor="end">{Math.round(max*value)}</text><text x={width-right+8} y={top+plotHeight*(1-value)+4}>{Math.round(value*100)}%</text></g>)}
    {daily.map((day,index)=><g key={day.date}><rect x={x(index)-Math.max(2,step*.27)} y={yCount(day.answered)} width={Math.max(4,step*.54)} height={Number(day.answered)>0?Math.max(1,top+plotHeight-yCount(day.answered)):0} rx="3" fill="#71aaff"><title>{day.date}：答题 {day.answered} 次，正确率 {displayAccuracy(day)}，用时 {displayDuration(day.study_seconds)}</title></rect>{labels.has(index)&&<text x={x(index)} y={height-16} textAnchor="middle">{day.date.slice(5).replace('-','/')}</text>}</g>)}
    {segments.map((points,index)=><polyline key={index} points={points.join(' ')} fill="none" stroke="#24a384" strokeWidth="2.5" strokeLinejoin="round"/>)}
    {daily.filter(day=>Number(day.answered)>0&&day.accuracy!==null&&Number.isFinite(Number(day.accuracy))).map(day=>{const index=daily.indexOf(day);return <circle key={day.date} cx={x(index)} cy={yRate(day.accuracy)} r="3" fill="#24a384"><title>{day.date}：正确率 {displayAccuracy(day)}</title></circle>;})}
  </svg></div>;
}
function Breakdown({items,kind}){
  const isSubject=kind==='subject';
  return <div className="student-table-scroll"><table><thead><tr>{[isSubject?'科目':'题型','答题次数','不同题目','正确率','用时'].map(label=><th key={label}>{label}</th>)}</tr></thead><tbody>{items.map(item=><tr key={isSubject?item.subject_id:item.type}><th scope="row">{isSubject?item.name:TYPE_NAMES[item.type]||item.type}</th><td>{displayNumber(item.answered)}</td><td>{displayNumber(item.unique_questions)}</td><td>{displayAccuracy(item)}</td><td>{displayDuration(item.study_seconds)}</td></tr>)}</tbody></table>{!items.length&&<p className="student-small-empty">暂无已同步的自主练习。</p>}</div>;
}
export default function StudentDetails({student,initialTab='profile',onBack,onPrivateRecords,onEdit,refreshVersion=0,ui,backLabel='返回账户列表'}){
  const {Icon,Button,PageHeader,Badge}=ui;
  const [tab,setTab]=useState(initialTab),[days,setDays]=useState(30),[subject,setSubject]=useState('');
  const [availableSubjects,setAvailableSubjects]=useState([]);
  const id=encodeURIComponent(student.id),profile=useScopedData(`/management/users/${id}/profile`,refreshVersion);
  const catalog=useScopedData(tab==='analytics'?'/management/subjects':null);
  const query=new URLSearchParams({days:String(days),subject_id:subject});
  const analytics=useScopedData(tab==='analytics'?`/management/users/${id}/analytics?${query}`:null,refreshVersion);
  const data=analytics.data,subjectChoices=availableSubjects.length?availableSubjects:catalog.data||[];
  useEffect(()=>{if(data?.available_subjects)setAvailableSubjects(data.available_subjects);},[data]);
  const account=profile.data?.user||student,subjectLabel=subject?subjectChoices.find(item=>item.id===subject)?.name||'所选科目':'全部科目';
  const chooseTab=value=>{setTab(value);};
  const classes=profile.data?.classes||[];
  return <div className="student-details-page">
    <PageHeader kicker="账号管理 / STUDENT DETAILS" title={account.name||account.username||'学生详情'} description={`学生账号 ${account.username||'—'} · 查看基础资料与已同步的学习概况。`}><Button variant="secondary" onClick={onBack}>{backLabel}</Button>{onEdit&&<Button variant="secondary" onClick={()=>onEdit(account)}>编辑资料</Button>}<Button variant="secondary" icon="file" onClick={()=>onPrivateRecords(account)}>逐题记录</Button></PageHeader>
    <nav className="student-detail-tabs" aria-label="学生详情栏目">{[['profile','基础信息'],['analytics','做题分析']].map(([value,label])=><button key={value} type="button" aria-current={tab===value?'page':undefined} className={tab===value?'active':''} onClick={()=>chooseTab(value)}><Icon name={value==='profile'?'contact':'chart'} size={18}/>{label}</button>)}</nav>
    {tab==='profile'?<Resource state={profile} ui={ui}>{profile.data&&<>
      <section className="panel student-profile-panel" aria-label="学生基础信息"><div className="student-profile-heading"><span className="student-profile-avatar">{(account.name||account.username||'?').slice(0,1)}</span><div><h2>{account.name||'未填写姓名'}</h2><p>{account.username}</p></div><div className="student-account-status"><Badge status={account.enabled===false?'offline':'active'}>{account.enabled===false?'已禁用':'已启用'}</Badge><Badge status={account.activated?'active':'pending'}>{account.activated?'已激活':'待激活'}</Badge></div></div><dl className="student-profile-fields">{[
        ['姓名',account.name],['账号',account.username],['出生年份',account.birth_year?`${account.birth_year} 年`:null],['年级',account.grade],['备考年份',account.exam_year?`${account.exam_year} 年`:null],['学习目标',account.target],['科目组',account.subject_group_name],['注册时间',displayDate(account.created_at)],['最后登录',displayDate(account.last_login_at)],['首次改密',account.must_change_password?'待首次改密':'已完成']
      ].map(([label,value])=><div key={label}><dt>{label}</dt><dd>{value||'未填写'}</dd></div>)}</dl></section>
      <section className="panel student-section" aria-label="学生班级"><div className="student-section-heading"><div><h2>所属班级</h2><p>包含正式、待确认与历史成员状态。</p></div><span>{classes.length} 个班级记录</span></div>{classes.length?<div className="student-class-list">{classes.map((item,index)=><div key={`${item.id}-${index}`}><span className="student-class-icon"><Icon name="school" size={21}/></span><div><strong>{item.name||item.class_name}</strong><p>{item.teacher_name||'未分配教师'}{item.term?` · ${item.term}`:''}</p></div><div className="student-class-status"><Badge status={item.status}>{MEMBER_STATUS[item.status]||item.status}</Badge>{item.archived&&<small>班级已归档</small>}{item.deleted_at&&<small>班级已删除</small>}</div></div>)}</div>:<p className="student-small-empty">该学生暂无班级记录。</p>}</section>
    </>}</Resource>:<>
      <section className="student-analytics-toolbar" aria-label="自主练习分析筛选"><div className="student-days-control" aria-label="分析时间范围">{[7,30,90].map(value=><button key={value} aria-pressed={days===value} className={days===value?'active':''} onClick={()=>setDays(value)}>近{value}天</button>)}</div><label>科目<select aria-label="分析科目" value={subject} onChange={event=>setSubject(event.target.value)}><option value="">全部科目</option>{subjectChoices.map(item=><option key={item.id} value={item.id}>{item.name}</option>)}</select></label><button className="icon-btn" aria-label="刷新学习分析" onClick={()=>{analytics.reload();catalog.reload();}}><Icon name="refresh" size={18}/></button></section>
      {catalog.error&&<div className="student-catalog-error" role="alert">科目列表获取失败：{catalog.error}<button className="text-btn" onClick={catalog.reload}>重试科目列表</button></div>}
      <div className="student-sync-note"><Icon name="clock" size={18}/><span>仅统计已同步的自主练习。手机离线待同步记录暂不计入；班级任务在下方单独展示。</span></div>
      <Resource state={analytics} ui={ui}>{data&&<>
        <section className="student-metric-section" aria-label="期间自主练习"><div className="student-section-heading"><div><h2>近{days}天自主练习</h2><p>{data.period?.start} 至 {data.period?.end} · 北京时间 · {subjectLabel}</p></div></div><MetricCards metrics={data.summary} label="期间自主练习统计"/></section>
        <section className="panel student-lifetime" aria-label="累计自主练习"><div className="student-section-heading"><div><h2>累计自主练习</h2><p>全部时间 · {subjectLabel} · 最近作答 {displayDate(data.lifetime?.last_answered_at)}</p></div></div><MetricCards metrics={data.lifetime} label="累计自主练习统计"/></section>
        <section className="panel student-section" aria-label="每日答题趋势"><div className="student-section-heading"><div><h2>每日答题趋势</h2><p>柱形看练习次数，折线看正确率；无作答日不显示正确率。</p></div><div className="student-chart-legend"><span><i/>答题次数</span><span><i/>正确率</span></div></div>{Number(data.summary?.answered)>0?<><TrendChart daily={data.daily||[]}/><p className="student-chart-hint">可左右滚动查看日期；悬停柱形或圆点查看当天数据。</p></>:<div className="student-analytics-empty"><Icon name="chart" size={30}/><h3>本期间暂无已同步的自主练习</h3><p>可调整日期或科目范围；尚未作答时，正确率显示“—”。</p></div>}</section>
        <div className="student-breakdown-grid"><section className="panel student-section" aria-label="分科学习情况"><div className="student-section-heading"><div><h2>分科学习情况</h2><p>近{days}天 · {subjectLabel}</p></div></div><Breakdown items={data.subjects||[]} kind="subject"/></section><section className="panel student-section" aria-label="题型学习情况"><div className="student-section-heading"><div><h2>题型学习情况</h2><p>近{days}天 · {subjectLabel}</p></div></div><Breakdown items={data.types||[]} kind="type"/></section></div>
        <section className="panel student-section student-classwork" aria-label="班级任务独立统计"><div className="student-section-heading"><div><h2>班级任务</h2><p>全部时间、全部科目，不随上方自主练习筛选变化；未提交数量包含未打开及历史已无法继续的任务，不代表当前仍可作答。任务作答不计入自主练习次数。</p></div><span>独立统计</span></div><div className="student-classwork-stats">{[['累计布置',data.classwork?.assigned],['已提交',data.classwork?.submitted],['未提交',data.classwork?.pending]].map(([label,value])=><div key={label}><strong>{displayNumber(value)}</strong><span>{label}</span></div>)}</div><h3 className="student-subheading">最近已交成绩</h3><div className="student-table-scroll"><table><thead><tr>{['任务 / 班级','提交时间','成绩','答对 / 总题数'].map(label=><th key={label}>{label}</th>)}</tr></thead><tbody>{(data.classwork?.results||[]).map(item=><tr key={item.assignment_id}><th scope="row">{item.title}<small>{item.class_name}</small></th><td>{displayDate(item.submitted_at)}</td><td><strong>{item.score??'—'}</strong> / {item.full_score??'—'} 分</td><td>{item.correct??'—'} / {item.total??'—'}</td></tr>)}</tbody></table>{!data.classwork?.results?.length&&<p className="student-small-empty">暂无已提交的班级任务成绩。</p>}</div></section>
      </>}</Resource>
    </>}
    <p className="student-audit-note"><Icon name="shield" size={15}/>基础信息与聚合分析的查看用途由后台自动记录；查看逐题记录仍需填写具体原因。</p>
  </div>;
}
