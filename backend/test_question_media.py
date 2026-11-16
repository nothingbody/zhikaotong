"""Raster validation, offline payloads and class-task answer-image isolation."""
import base64
import hashlib
import struct
import zlib

import pytest

from . import app as core
from .question_media import validate_media
from .test_api import activate, c, headers, login, question_payload
from .test_teaching import school


def image(red=0):
    def chunk(name,data):
        return len(data).to_bytes(4,'big')+name+data+(zlib.crc32(name+data)&0xffffffff).to_bytes(4,'big')
    raw=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(bytes([0,red,0,0])))+chunk(b'IEND',b'')
    digest=hashlib.sha256(raw).hexdigest()
    return digest,{'mime':'image/png','data':base64.b64encode(raw).decode(),'width':1,'height':1}


def test_rich_question_roundtrip_and_edit_keeps_referenced_media(c):
    digest,asset=image()
    admin=login(c);auth=headers(admin);student=headers(activate(c))
    payload={**question_payload(),'stem':'原公式 {{img:'+digest+'}}','media':{digest:asset}}
    response=c.post('/api/management/questions',headers=auth,json=payload)
    assert response.status_code==200,response.text
    question=response.json();assert question['media'][digest]==asset
    package=c.get('/api/bank/package?subject_id=math',headers=student).json()
    assert next(item for item in package['questions'] if item['id']==question['id'])['media'][digest]==asset
    assert package['checksum']==hashlib.sha256(core.canonical(package['questions']).encode()).hexdigest()
    old_version=package['version']
    assert c.put('/api/management/questions/'+question['id'],headers=auth,json={key:value for key,value in {**payload,'stem':'保留原图 {{img:'+digest+'}}'}.items() if key!='media'}).status_code==200
    with core.db() as conn:
        previous=core.one(conn,'SELECT questions FROM bank_releases WHERE version=?',(old_version,))
        assert '原公式' in previous['questions']
        assert digest in core.one(conn,'SELECT media FROM questions WHERE id=?',(question['id'],))['media']


@pytest.mark.parametrize('bad_options',[None,1,{}])
def test_malformed_options_are_422(c,bad_options):
    response=c.post('/api/management/questions',headers=headers(login(c)),json={**question_payload(),'options':bad_options})
    assert response.status_code==422,response.text


def test_missing_corrupt_or_unsafe_media_is_rejected_and_unused_is_removed(c):
    digest,asset=image();second,unused=image(100)
    auth=headers(login(c));payload={**question_payload(),'stem':'原图 {{img:'+digest+'}}'}
    for media in ({},{digest:{**asset,'mime':'image/svg+xml'}},{digest:{**asset,'data':'bad'}},{digest:{**asset,'data':base64.b64encode(b'\x89PNG\r\n\x1a\n'+bytes(25)).decode()}}):
        response=c.post('/api/management/questions',headers=auth,json={**payload,'media':media})
        assert response.status_code==422,response.text
    raw=base64.b64decode(asset['data']);broken=raw[:-1]+bytes([raw[-1]^1]);broken_hash=hashlib.sha256(broken).hexdigest()
    with pytest.raises(ValueError):
        validate_media({'stem':'{{img:'+broken_hash+'}}','options':[],'media':{broken_hash:{**asset,'data':base64.b64encode(broken).decode()}}})
    accepted=c.post('/api/management/questions',headers=auth,json={**payload,'media':{digest:asset,second:unused}})
    assert accepted.status_code==200 and set(accepted.json()['media'])=={digest}


def test_old_phone_receives_update_instruction_instead_of_broken_formulas(c):
    digest,asset=image();admin=headers(login(c));student=headers(activate(c))
    c.post('/api/management/questions',headers=admin,json={**question_payload(),'stem':'原公式 {{img:'+digest+'}}','media':{digest:asset}})
    old={**student,'X-Zhikaotong-Surface':'app'}
    assert c.get('/api/questions?subject_id=math',headers=old).status_code==426
    assert c.get('/api/bank/package?subject_id=math',headers=old).status_code==426
    current={**old,'X-Question-Content':'media-v1'}
    assert c.get('/api/questions?subject_id=math',headers=current).status_code==200
    assert c.get('/api/bank/package?subject_id=math',headers=current).status_code==200
    assert c.get('/api/questions?subject_id=english',headers=old).status_code==200


def test_class_task_does_not_leak_explanation_only_images(school):
    _,call,_,class_id=school
    body,body_asset=image();secret,secret_asset=image(100)
    created=call('POST','/management/questions',role='admin',json={**question_payload(),'stem':'题图 {{img:'+body+'}}','explanation':'仅交卷后解析 {{img:'+secret+'}}','media':{body:body_asset,secret:secret_asset}}).json()
    paper=call('POST','/teaching/papers',json={'title':'原图练习','rules':[{'subject_id':'math','type':'single','knowledge_id':created['knowledge_id'],'count':1,'score':1}]}).json()
    # The random pool can contain several math questions, select the verified
    # rich snapshot in this isolated fixture to inspect the student projection.
    with core.db() as conn:
        rich={**core.question_public(core.one(conn,'SELECT * FROM questions WHERE id=?',(created['id'],))), 'score':1}
        conn.execute('UPDATE teaching_papers SET questions=? WHERE id=?',(core.canonical([rich]),paper['id']))
    task=call('POST','/teaching/papers/'+paper['id']+'/assign',json={'class_ids':[class_id]}).json()['assignments'][0]
    response=call('GET','/student/assignments/'+task['id'],role='student')
    assert response.status_code==200,response.text
    question=response.json()['questions'][0]
    assert 'answer' not in question and 'explanation' not in question
    assert set(question['media'])=={body} and secret not in core.canonical(question)
