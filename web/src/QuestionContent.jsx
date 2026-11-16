import React, { useEffect, useState } from 'react';
import { IMAGE_TOKEN, verifyQuestionMedia } from './question-media';
import './question-content.css';

function QuestionImage({id,asset}) {
  const [state,setState] = useState({loading:true}),[expanded,setExpanded] = useState(false);
  useEffect(() => {
    let active = true;
    setState({loading:true});setExpanded(false);
    verifyQuestionMedia(id,asset).then(value => {if(active)setState({value});}).catch(error => {if(active)setState({error:error.message});});
    return () => {active=false;};
  },[id,asset]);
  if (state.error) return <span className="question-image-error" role="alert">{state.error}</span>;
  if (state.loading) return <span className="question-image-loading" role="status">正在校验题图…</span>;
  const {src,width,height} = state.value;
  return <span className={`question-image ${expanded?'expanded':''}`}>
    <button type="button" className="question-image-button" aria-label={expanded?'收起原图':'放大原图'} aria-expanded={expanded} onClick={() => setExpanded(!expanded)}>
      <img src={src} width={width} height={height} alt="原题图片或公式" loading="lazy" style={{width:Math.min(width/2,640)}} onError={() => setState({error:'题图无法显示，请重新下载题库'})}/>
      <span className="question-image-hint">{expanded?'收起原图':'点击放大'}</span>
    </button>
    {expanded&&<span className="question-image-viewer" role="group" aria-label="原图放大">
      <span className="question-image-scroll"><img src={src} width={width} height={height} style={{width,height}} alt="放大的原题图片或公式" onError={() => setState({error:'题图无法显示，请重新下载题库'})}/></span>
      <button type="button" className="text-btn" onClick={() => setExpanded(false)}>收起原图</button>
    </span>}
  </span>;
}

export default function QuestionContent({text,media={},className=''}) {
  const value = String(text ?? ''),fragments=[];
  let start=0,index=0;
  for (const match of value.matchAll(IMAGE_TOKEN)) {
    if(match.index>start)fragments.push(value.slice(start,match.index));
    fragments.push(<QuestionImage key={`${match.index}-${index++}`} id={match[1]} asset={media?.[match[1]]}/>);
    start=match.index+match[0].length;
  }
  if(start<value.length)fragments.push(value.slice(start));
  return <span className={`question-content ${className}`}>{fragments}</span>;
}
