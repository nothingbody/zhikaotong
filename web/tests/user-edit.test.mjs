import test from 'node:test';
import assert from 'node:assert/strict';
import {editableProfileFields,userEditForm,userEditPatch,userEditOutcome} from '../src/user-edit.js';

const fields=['username','name','enabled','birth_year','subject_group_id','exam_year','grade','target'];
const limits={birth_year_min:1900,birth_year_max:2012,exam_year_min:2026,exam_year_max:2036};
const student={id:'student-1',username:'20270001',name:'李同学',role:'student',activated:true,enabled:true,
  birth_year:2008,subject_group_id:'mechanics',exam_year:2027,grade:'高三',target:'升学'};

test('editing a displayed name sends only that field and keeps all other student data',()=>{
  const form=userEditForm(student);
  form.name='  李小同学  ';
  assert.deepEqual(userEditPatch(student,form,fields,limits),{name:'李小同学'});
  assert.deepEqual(userEditPatch(student,userEditForm(student),fields,limits),{});
  assert.equal(student.birth_year,2008);
});

test('unmodified historical years and legacy null values do not block correcting a name',()=>{
  const legacy={...student,birth_year:null,exam_year:2025,grade:' 高三 ',target:' 升学 \n'};
  const form={...userEditForm(legacy),name:'修正姓名'};
  assert.deepEqual(userEditPatch(legacy,form,fields,limits),{name:'修正姓名'});
  assert.throws(()=>userEditPatch(legacy,{...form,exam_year:'2024'},fields,limits),/2026至2036/);
});

test('year changes are integer JSON numbers and cannot bypass bounds or null restrictions',()=>{
  const form={...userEditForm(student),birth_year:'2007',exam_year:'2028'};
  assert.deepEqual(userEditPatch(student,form,fields,limits),{birth_year:2007,exam_year:2028});
  for(const value of ['2013','1899','2008.5','2e3','',false]){
    assert.throws(()=>userEditPatch(student,{...userEditForm(student),birth_year:value},fields,limits));
  }
  assert.throws(()=>userEditPatch(student,{...userEditForm(student),exam_year:'2028'},fields,{}),/尚未加载/);
});

test('unactivated optional fields clear as null without altering activation or consent',()=>{
  const pending={...student,activated:false};
  const form={...userEditForm(pending),birth_year:'',subject_group_id:''};
  assert.deepEqual(userEditPatch(pending,form,fields,limits),{birth_year:null,subject_group_id:null});
  assert.throws(()=>userEditPatch(student,{...userEditForm(student),subject_group_id:''},fields,limits),/必须保留/);
});

test('role and server field allowlists prevent sending security, password or class changes',()=>{
  const form={...userEditForm(student),name:'新姓名',role:'admin',password:'private',activated:false,
    consent_version:'new',class_id:'another-class',enabled:false};
  assert.deepEqual(userEditPatch(student,form,fields,limits),{name:'新姓名'});
  assert.deepEqual(userEditPatch(student,{...form,name:'新姓名'},['username'],limits),{});
  assert.deepEqual(editableProfileFields('teacher',fields),['username','name']);
  assert.deepEqual(editableProfileFields('admin',undefined),[]);
  const teacher={...student,role:'teacher'};
  assert.deepEqual(userEditForm(teacher),{username:student.username,name:student.name});
  assert.deepEqual(userEditPatch(teacher,{...form,name:'陈老师',birth_year:'2005'},fields,limits),{name:'陈老师'});
});

test('changed text respects account format and profile lengths',()=>{
  const base=userEditForm(student);
  for(const username of ['ab','bad name','中文账号','x'.repeat(65)])assert.throws(()=>userEditPatch(student,{...base,username},fields,limits),/账号/);
  assert.throws(()=>userEditPatch(student,{...base,name:'   '},fields,limits),/姓名/);
  assert.throws(()=>userEditPatch(student,{...base,name:'甲'.repeat(51)},fields,limits),/姓名/);
  assert.throws(()=>userEditPatch(student,{...base,grade:'甲'.repeat(41)},fields,limits),/年级/);
  assert.throws(()=>userEditPatch(student,{...base,target:'甲'.repeat(201)},fields,limits),/学习目标/);
});

test('only own login changes require clearing the current administrator session',()=>{
  const admin={id:'admin-1',username:'admin',name:'管理员',role:'admin'};
  assert.deepEqual(userEditOutcome(admin,admin,{...admin,name:'校方管理员'}),{
    ownAccount:true,requiresRelogin:false,message:'用户资料已保存。'});
  const login=userEditOutcome(admin,admin,{...admin,username:'school-admin'});
  assert.equal(login.ownAccount,true);assert.equal(login.requiresRelogin,true);
  const other=userEditOutcome(admin,student,{...student,username:'20270002'});
  assert.equal(other.ownAccount,false);assert.equal(other.requiresRelogin,true);
  assert.equal(userEditOutcome(admin,student,{...student,subject_group_id:'computer'}).requiresRelogin,true);
  assert.equal(userEditOutcome(admin,student,{...student,grade:'高二'}).requiresRelogin,false);
});
