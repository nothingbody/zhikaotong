import test from 'node:test';
import assert from 'node:assert/strict';
import {shanghaiToday,recentDateRange,dateRangeError,overviewFilters,overviewQuery,overviewExportPayload,overviewFilename} from '../src/student-overview.js';

test('Shanghai quick ranges include both end dates across UTC midnight and leap days', () => {
  assert.equal(shanghaiToday(new Date('2026-11-03T16:00:00Z')),'2026-11-04');
  assert.equal(shanghaiToday(new Date('2026-11-03T15:59:59Z')),'2026-11-03');
  assert.deepEqual(recentDateRange(7,'2024-03-01'),{date_from:'2024-02-24',date_to:'2024-03-01'});
  assert.equal(dateRangeError('2024-02-29','2025-02-28'),'');
  assert.match(dateRangeError('2024-02-29','2025-03-01'),/366/);
  assert.match(dateRangeError('2026-02-29','2026-03-01'),/有效/);
  assert.match(dateRangeError('2026-11-04','2026-11-03'),/开始日期/);
});

test('list and export keep identical class, student, subject and date scopes without leaking pagination', () => {
  const filters=overviewFilters('class-1',{q:' 李 同学 ',subject_id:'math',enabled:'false',date_from:'2026-11-01',date_to:'2026-11-04',sort_by:'accuracy',order:'asc'});
  const query=new URLSearchParams(overviewQuery(filters,3,50));
  assert.equal(query.get('class_id'),'class-1');
  assert.equal(query.get('q'),'李 同学');
  assert.equal(query.get('page'),'3');
  assert.equal(query.get('page_size'),'50');
  const payload=overviewExportPayload({...filters,page:3,page_size:50},['s-2','s-1']);
  assert.deepEqual(payload,{...filters,enabled:false,student_ids:['s-2','s-1']});
  assert.equal('page' in payload,false);
  assert.equal('page_size' in payload,false);
  assert.equal('student_ids' in overviewExportPayload(filters),false);
  assert.equal(overviewExportPayload({...filters,enabled:'true'}).enabled,true);
  assert.equal(new URLSearchParams(overviewQuery(overviewFilters('c',{enabled:false}))).get('enabled'),'false');
  assert.throws(()=>overviewExportPayload(filters,[]),/请选择/);
  assert.throws(()=>overviewExportPayload(filters,['s','s']),/不同学生/);
  assert.throws(()=>overviewExportPayload(filters,Array.from({length:501},(_,i)=>String(i))),/500/);
  assert.equal(new URLSearchParams(overviewQuery(overviewFilters('c',{date_from:'2026-11-01',date_to:'2026-11-04'}))).has('subject_id'),false);
});

test('download filenames remain a single CSV filename even for unusual class names', () => {
  assert.equal(overviewFilename('../一班/二班:2026','2026-11-01','2026-11-04'),'_一班_二班_2026-学习汇总-2026-11-01-2026-11-04.csv');
  assert.equal(overviewFilename('', '2026-11-01','2026-11-04'),'学生-学习汇总-2026-11-01-2026-11-04.csv');
});
