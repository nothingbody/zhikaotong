import test from 'node:test';
import assert from 'node:assert/strict';
import {directoryQuery, accountQuery, staffPath, studentImportRows, studentRowsCSV, creationClass} from '../src/account-workspace.js';

test('student accounts require an explicit class and keep filters in the server request', () => {
  assert.throws(() => accountQuery(''), /先选择班级/);
  const query = new URLSearchParams(accountQuery('班级&一', {q: ' 李 同学 ', enabled: 'false', membership: 'pending', sort: 'created_at', order: 'desc', page: 3, pageSize: 50}, true));
  assert.deepEqual(Object.fromEntries(query), {class_id: '班级&一', q: '李 同学', membership_status: 'pending', sort_by: 'created_at', order: 'desc', page: '3', page_size: '50', enabled: 'false'});
  assert.equal(new URLSearchParams(accountQuery('unassigned')).has('enabled'), false);
  assert.equal(new URLSearchParams(accountQuery('own-class', {sort: 'last_login_at'})).get('sort_by'), 'name');
  assert.equal(new URLSearchParams(accountQuery('own-class', {sort: 'last_login_at'}, true)).get('sort_by'), 'last_login_at');
});

test('directory paging and staff scopes cannot silently request all current students', () => {
  const query = new URLSearchParams(directoryQuery({q: ' 一班 ', page: 4, pageSize: 20, status: 'archived'}));
  assert.equal(query.get('q'), '一班');
  assert.equal(query.get('class_status'), 'archived');
  assert.equal(query.get('page'), '4');
  assert.equal(staffPath('teacher'), '/management/users?role=teacher');
  assert.equal(staffPath('admin'), '/management/users?role=admin');
  assert.equal(staffPath('student', true), '/management/users?role=student&deleted=true');
  assert.throws(() => staffPath('student'), /按班级加载/);
  assert.throws(() => staffPath(''), /按班级加载/);
});

test('CSV and spreadsheet round trips preserve quoted names and exact passwords', () => {
  const rows = [{username: '20270001', name: '李,同学\n二', password: ' a"B3,\nPass '}, {username: '000002', name: '陈同学', password: 'Another123A'}];
  assert.deepEqual(studentImportRows('\uFEFF' + studentRowsCSV(rows)), rows);
  assert.deepEqual(studentImportRows('学号,姓名,初始密码\r\n 000003 , 张同学 , PassA12345 \r\n\r\n'), [{username: '000003', name: '张同学', password: ' PassA12345 '}]);
  assert.throws(() => studentImportRows('username,name,password\n'), /至少一行/);
  assert.throws(() => studentImportRows('0001,张同学'), /三列/);
  assert.throws(() => studentImportRows('0001,"张同学,Password123'), /未闭合/);
});

test('creation prefills the current active class and never offers an archived class to a teacher', () => {
  const classes = [{id: 'archived', archived: true}, {id: 'own', archived: false}, {id: 'own-2', archived: false}];
  assert.equal(creationClass(classes[2], classes, true), 'own-2');
  assert.equal(creationClass(classes[0], classes, true), 'own');
  assert.equal(creationClass({id: 'foreign'}, classes, true), 'own');
  assert.equal(creationClass({id: 'unassigned'}, classes, false), '');
  assert.equal(creationClass(null, [{id: 'archived', archived: true}], true), '');
});
