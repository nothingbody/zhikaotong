"""Risk-focused API regressions. Run: python -m pytest backend/test_api.py -q."""
import asyncio
import importlib
import json
import os
import sqlite3
import uuid
from datetime import timedelta

import httpx
import pytest

os.environ.setdefault("APP_ENV", "development")
os.environ.setdefault("DEV_SEED", "true")
for name in ("ADMIN", "REVIEWER", "TEACHER", "STUDENT"):
    os.environ["BOOTSTRAP_"+name+"_PASSWORD"]="Test"+name.title()+"123!"

api=importlib.import_module("backend.app")


class Client:
    def request(self, method, path, **kwargs):
        async def send():
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=api.app),base_url="http://test") as client:
                return await client.request(method,path,**kwargs)
        return asyncio.run(send())

    def get(self,path,**kwargs):return self.request("GET",path,**kwargs)
    def post(self,path,**kwargs):return self.request("POST",path,**kwargs)
    def patch(self,path,**kwargs):return self.request("PATCH",path,**kwargs)
    def put(self,path,**kwargs):return self.request("PUT",path,**kwargs)
    def delete(self,path,**kwargs):return self.request("DELETE",path,**kwargs)


@pytest.fixture
def c(tmp_path,monkeypatch):
    monkeypatch.setattr(api,"DB_PATH",str(tmp_path/"test.db"))
    monkeypatch.setattr(api,"APP_ENV","development")
    monkeypatch.setenv("DEV_SEED","true")
    monkeypatch.setenv("DEV_SEED_QUESTIONS","true")
    api.initialize()
    return Client()


def login(c,username="admin",password=None):
    response=c.post("/api/auth/login",json={"username":username,"password":password or "Test"+username.title()+"123!"})
    assert response.status_code==200,response.text
    return response.json()


def headers(tokens):return {"Authorization":"Bearer "+tokens["access_token"]}


def activate(c):
    tokens=login(c,"student");h=headers(tokens)
    assert c.get("/api/student/dashboard",headers=h).status_code==403
    assert c.post("/api/auth/password",headers=h,json={"old_password":"TestStudent123!","new_password":"NewStudent123!"}).status_code==200
    cfg=c.get("/api/public/config").json()
    payload={"birth_year":2008,"name":"测试学生","subject_group_id":cfg["subject_groups"][0]["id"],"exam_year":2027,"grade":"高三","target":"本科","consent_version":cfg["agreement_version"],"teacher_visibility_accepted":True}
    response=c.post("/api/student/activate",headers=h,json=payload)
    assert response.status_code==200,response.text
    return tokens


def question_payload():
    return {"subject_id":"math","knowledge_id":"math-basic","type":"single","stem":"测试题：1+1=?","options":[{"key":"A","text":"2"},{"key":"B","text":"3"}],"answer":["A"],"explanation":"1+1=2","difficulty":1,"source":"自编测试","authorization":"测试作者授权","status":"pending"}


def record(q,answer=None):
    return {"client_uuid":str(uuid.uuid4()),"question_id":q["id"],"question_version":q["version"],"selected":answer if answer is not None else q["answer"],"duration_seconds":12,"answered_at":api.iso()}


def test_refresh_rotation_replay_revokes_session(c):
    tokens=login(c)
    rotated=c.post("/api/auth/refresh",json={"refresh_token":tokens["refresh_token"]})
    assert rotated.status_code==200
    assert c.get("/api/auth/me",headers=headers(tokens)).status_code==401
    assert c.post("/api/auth/refresh",json={"refresh_token":tokens["refresh_token"]}).status_code==401
    assert c.get("/api/auth/me",headers=headers(rotated.json())).status_code==401


def test_activation_age_and_consent_gates(c):
    tokens=login(c,"student");h=headers(tokens)
    assert c.get("/api/auth/me",headers=h).status_code==200
    cfg=c.get("/api/public/config").json()
    payload={"birth_year":2020,"subject_group_id":cfg["subject_groups"][0]["id"],"consent_version":cfg["agreement_version"],"teacher_visibility_accepted":True}
    assert c.post("/api/student/activate",headers=h,json=payload).status_code==403
    assert c.post("/api/auth/password",headers=h,json={"old_password":"TestStudent123!","new_password":"NewStudent123!"}).status_code==200
    assert c.post("/api/student/activate",headers=h,json=payload).status_code==403
    payload["birth_year"]=2008;payload["consent_version"]="old"
    assert c.post("/api/student/activate",headers=h,json=payload).status_code==409
    payload["consent_version"]=cfg["agreement_version"]
    assert c.post("/api/student/activate",headers=h,json=payload).status_code==200
    admin=headers(login(c))
    assert c.patch("/api/management/settings",headers=admin,json={"agreement_version":"draft-2"}).status_code==200
    assert c.get("/api/questions",headers=h).status_code==403
    assert c.post("/api/student/consent",headers=h,json={"version":"draft-2"}).status_code==200
    assert c.get("/api/questions",headers=h).status_code==200


def test_server_scoring_idempotency_and_wrong_streak(c):
    h=headers(activate(c));q=c.get("/api/questions?subject_id=math",headers=h).json()[0]
    wrong=next(x["key"] for x in q["options"] if x["key"] not in q["answer"])
    item=record(q,[wrong]);item["correct"]=True
    response=c.post("/api/student/records/batch",headers=h,json={"records":[item]})
    assert response.status_code==200,response.text
    assert response.json()["results"][0]["correct"] is False
    duplicate=c.post("/api/student/records/batch",headers=h,json={"records":[item]})
    assert duplicate.json()["duplicates"]==1
    changed={**item,"selected":q["answer"]}
    assert c.post("/api/student/records/batch",headers=h,json={"records":[changed]}).status_code==409
    assert len(c.get("/api/student/wrong",headers=h).json())==1
    for _ in range(2):
        assert c.post("/api/student/records/batch",headers=h,json={"records":[record(q)]}).status_code==200
    assert c.get("/api/student/wrong",headers=h).json()==[]
    stats=c.get("/api/student/dashboard",headers=h).json()["stats"]
    assert stats["answered"]==3 and stats["correct"]==2


def test_teacher_idor_roster_redaction_and_visibility_gate(c):
    teacher=headers(login(c,"teacher"));admin=headers(login(c))
    own=c.get("/api/management/classes",headers=teacher).json()[0]
    roster=c.get("/api/management/users",headers=teacher).json()
    assert "birth_year" not in roster[0] and "consent_version" not in roster[0] and "target" not in roster[0]
    members=c.get("/api/management/classes/"+own["id"]+"/members",headers=teacher).json()
    mid=members[0]["membership_id"]
    assert c.patch("/api/management/memberships/"+mid,headers=teacher,json={"status":"active"}).status_code==409
    other=c.post("/api/management/users",headers=admin,json={"username":"teacher2","name":"其他教师","role":"teacher","password":"TeacherOther123!"}).json()
    cls=c.post("/api/management/classes",headers=admin,json={"name":"其他班级","subject_group_id":"group-mechanics","term":"2027","teacher_id":other["id"]}).json()
    assert c.get("/api/management/classes/"+cls["id"]+"/members",headers=teacher).status_code==403
    assert c.post("/api/management/users",headers=teacher,json={"username":"badrole","name":"越权","role":"admin","password":"BadRole12345!","class_id":own["id"]}).status_code==403
    assert c.post("/api/management/users",headers=teacher,json={"username":"badclass","name":"越权","role":"student","password":"BadRole12345!","class_id":cls["id"]}).status_code==403
    student_h=headers(activate(c))
    assert c.post("/api/student/classes/"+own["id"]+"/confirm",headers=student_h,json={"accepted":False,"class_name":"小王"}).status_code==422
    assert c.post("/api/student/classes/"+own["id"]+"/confirm",headers=student_h,json={"accepted":True,"class_name":"小王"}).json()["status"]=="active"


def test_bounded_account_candidate_search_keeps_role_and_teacher_scope(c):
    admin = headers(login(c))
    teacher = headers(login(c, "teacher"))
    assert len(c.get("/api/management/users?limit=1", headers=admin).json()) == 1
    teachers = c.get("/api/management/users?role=teacher&limit=50", headers=admin).json()
    assert teachers and all(item["role"] == "teacher" for item in teachers)
    students = c.get("/api/management/users?role=student&q=student&limit=50", headers=teacher).json()
    assert students and all(item["role"] == "student" for item in students)
    assert all("birth_year" not in item and "last_login_at" not in item for item in students)
    assert c.get("/api/management/users?role=admin&limit=50", headers=teacher).json() == []
    for limit in (0, 1001):
        assert c.get(f"/api/management/users?limit={limit}", headers=admin).status_code == 422


def test_direct_admin_publish_and_immutable_version(c):
    author=headers(login(c));reviewer=headers(login(c,"reviewer"));h=headers(activate(c))
    q=c.post("/api/management/questions",headers=author,json=question_payload()).json()
    assert c.post("/api/management/questions/"+q["id"]+"/review",headers=author,json={"approve":True}).status_code==410
    assert c.post("/api/management/questions/"+q["id"]+"/review",headers=reviewer,json={"approve":True}).status_code==410
    release=c.post("/api/management/bank/publish",headers=author).json()
    available=c.get("/api/questions?subject_id=math",headers=h).json()
    snapshot=next(x for x in available if x["id"]==q["id"])
    assert snapshot["version"]==release["version"]
    payload={**question_payload(),"answer":["B"],"status":"draft"}
    assert c.put("/api/management/questions/"+q["id"],headers=author,json=payload).status_code==200
    c.post("/api/management/bank/publish",headers=author)
    item=record(snapshot)
    scored=c.post("/api/student/records/batch",headers=h,json={"records":[item]})
    assert scored.status_code==200,scored.text
    assert scored.json()["results"][0]["correct"] is True
    retry=c.post("/api/student/records/batch",headers=h,json={"records":[item]})
    assert retry.json()["duplicates"]==1
    package=c.get("/api/bank/package?subject_id=math",headers=h).json()
    import hashlib
    assert hashlib.sha256(api.canonical(package["questions"]).encode()).hexdigest()==package["checksum"]


def test_import_all_or_none(c):
    h=headers(login(c))
    payload={"rows":[{"username":"newstudent","name":"新学生","password":"NewStudent123!"},{"username":"student","name":"重复","password":"NewStudent123!"}]}
    response=c.post("/api/management/users/import",headers=h,json=payload)
    assert response.status_code==200,response.text
    assert response.json()["created"]==0
    assert c.get("/api/management/users?q=newstudent",headers=h).json()==[]
    payload["rows"].pop()
    assert c.post("/api/management/users/import",headers=h,json=payload).json()["created"]==1


def test_deletion_execution_and_audit_immutable(c):
    tokens=activate(c);h=headers(tokens);admin_h=headers(login(c))
    q=c.get("/api/questions",headers=h).json()[0]
    c.post("/api/student/records/batch",headers=h,json={"records":[record(q)]})
    request=c.post("/api/student/deletion",headers=h,json={"confirm":True})
    assert request.status_code==200
    with api.db() as conn:
        conn.execute("UPDATE deletions SET execute_at=? WHERE user_id=?",(api.iso(api.now()-timedelta(seconds=1)),tokens["user"]["id"]))
    response=c.post("/api/management/deletions/execute",headers=admin_h)
    assert response.json()["executed"]==1
    assert c.get("/api/auth/me",headers=h).status_code==401
    with api.db() as conn:
        user=api.one(conn,"SELECT * FROM users WHERE id=?",(tokens["user"]["id"],))
        assert user["name"]=="已注销用户" and user["birth_year"] is None and not user["enabled"]
        assert conn.execute("SELECT COUNT(*) FROM records WHERE user_id=?",(user["id"],)).fetchone()[0]==0
        with pytest.raises(sqlite3.IntegrityError):conn.execute("DELETE FROM audit")


def test_password_length_device_revocation_and_login_limit(c):
    first=login(c);second=login(c);h=headers(first)
    assert not api.check_password("测"*23+"Ab1suffix",api.password_hash("测"*23+"Ab1"))
    assert c.post("/api/auth/password",headers=h,json={"old_password":"TestAdmin123!","new_password":"AnotherAdmin123!"}).status_code==200
    assert c.get("/api/auth/me",headers=headers(second)).status_code==401
    for _ in range(5):assert c.post("/api/auth/login",json={"username":"nonexistent","password":"Wrong123456"}).status_code==401
    assert c.post("/api/auth/login",json={"username":"nonexistent","password":"Wrong123456"}).status_code==429


def test_group_reference_and_archived_readonly(c):
    h=headers(login(c));t=headers(login(c,"teacher"));cls=c.get("/api/management/classes",headers=t).json()[0]
    assert c.patch("/api/management/groups/group-mechanics",headers=h,json={"subject_ids":["math"]}).status_code==409
    assert c.patch("/api/management/groups/group-mechanics",headers=h,json={"enabled":False}).status_code==409
    assert c.patch("/api/management/classes/"+cls["id"],headers=t,json={"archived":True}).status_code==200
    assert c.patch("/api/management/groups/group-mechanics",headers=h,json={"enabled":False}).status_code==200
    assert c.post("/api/management/classes",headers=t,json={"name":"新班","subject_group_id":"group-mechanics","term":"2027"}).status_code==422
    assert c.post("/api/management/users",headers=t,json={"username":"archivedstudent","name":"学生","role":"student","password":"Student12345!","class_id":cls["id"]}).status_code==409


def test_offline_out_of_order_and_mark_last_write(c):
    h=headers(activate(c));q=c.get("/api/questions?subject_id=math",headers=h).json()[0]
    wrong=next(x["key"] for x in q["options"] if x["key"] not in q["answer"])
    base=api.now()-timedelta(minutes=5)
    old_wrong=record(q,[wrong]);old_wrong["answered_at"]=api.iso(base)
    newer=[record(q),record(q)]
    for index,item in enumerate(newer,1):item["answered_at"]=api.iso(base+timedelta(seconds=index))
    assert c.post("/api/student/records/batch",headers=h,json={"records":newer}).status_code==200
    assert c.post("/api/student/records/batch",headers=h,json={"records":[old_wrong]}).status_code==200
    assert c.get("/api/student/wrong",headers=h).json()==[]
    endpoint="/api/student/marks/"+q["id"]
    assert c.put(endpoint,headers=h,json={"kind":"favorite","active":False,"updated_at":api.iso(base+timedelta(seconds=4))}).status_code==200
    assert c.put(endpoint,headers=h,json={"kind":"favorite","active":True,"updated_at":api.iso(base)}).status_code==200
    assert c.get("/api/student/marks?kind=favorite",headers=h).json()==[]


def test_device_limit_revokes_oldest_session_and_logout_refresh(c):
    first=login(c);h=headers(first)
    assert c.patch("/api/management/settings",headers=h,json={"device_limit":1}).status_code==200
    second=login(c)
    assert c.get("/api/auth/me",headers=h).status_code==401
    assert c.post("/api/auth/logout",headers=headers(second),json={"refresh_token":second["refresh_token"]}).status_code==200
    assert c.post("/api/auth/refresh",json={"refresh_token":second["refresh_token"]}).status_code==401


@pytest.mark.parametrize('environment', ['development', 'production'])
@pytest.mark.parametrize('legacy_secret', [None, 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 'invalid-legacy-secret'])
def test_admin_password_only_ignores_legacy_totp_in_all_environments(c, monkeypatch, environment, legacy_secret):
    monkeypatch.setattr(api, 'APP_ENV', environment)
    if legacy_secret is None:
        monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    else:
        monkeypatch.setenv('ADMIN_TOTP_SECRET', legacy_secret)
    # Initialization and login do not read an old secret, including malformed
    # values retained in an existing deployment's environment.
    api.initialize()
    first = login(c)
    assert c.get('/api/auth/me', headers=headers(first)).status_code == 200
    old_client = c.post('/api/auth/login', json={
        'username': 'admin', 'password': 'TestAdmin123!', 'otp': 'invalid-unused-code'})
    assert old_client.status_code == 200, old_client.text
    wrong = c.post('/api/auth/login', json={'username': 'admin', 'password': 'WrongPassword123!'})
    missing = c.post('/api/auth/login', json={'username': 'not-existing', 'password': 'WrongPassword123!'})
    assert wrong.status_code == missing.status_code == 401
    assert wrong.json() == missing.json() == {'detail': '账号或密码不正确'}
    assert c.get('/api/health').json()['version'] == api.VERSION
    with api.db() as conn:
        admin = api.one(conn, "SELECT * FROM users WHERE username='admin'")
        assert admin['password_hash'].startswith('$2') and api.check_password('TestAdmin123!', admin['password_hash'])
        assert conn.execute("SELECT COUNT(*) FROM audit WHERE action='auth.login' AND actor=?", (admin['id'],)).fetchone()[0] == 2
        assert conn.execute("SELECT COUNT(*) FROM audit WHERE action='auth.login.failed'").fetchone()[0] == 2


@pytest.mark.parametrize('legacy_secret', [None, 'unused-old-secret'])
def test_fresh_production_initializes_without_totp_and_keeps_password_gate(tmp_path, monkeypatch, legacy_secret):
    monkeypatch.setattr(api, 'DB_PATH', str(tmp_path / 'password-only-production.db'))
    monkeypatch.setattr(api, 'APP_ENV', 'production')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.setenv('BOOTSTRAP_ADMIN_PASSWORD', 'ProductionFixture123!')
    if legacy_secret is None:
        monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    else:
        monkeypatch.setenv('ADMIN_TOTP_SECRET', legacy_secret)
    api.initialize()
    client = Client()
    tokens = login(client, 'admin', 'ProductionFixture123!')
    assert client.get('/api/auth/me', headers=headers(tokens)).status_code == 200
    # Removing the second factor does not waive mandatory first password change.
    assert client.get('/api/management/dashboard', headers=headers(tokens)).status_code == 403
    with api.db() as conn:
        assert [row['username'] for row in api.rows(conn, 'SELECT username FROM users')] == ['admin']
        assert api.settings(conn)['app_latest_version'] == api.DEFAULT_SETTINGS['app_latest_version']


@pytest.mark.parametrize('environment', ['development', 'production'])
def test_password_only_admin_still_locks_after_wrong_passwords(c, monkeypatch, environment):
    monkeypatch.setattr(api, 'APP_ENV', environment)
    monkeypatch.setenv('ADMIN_TOTP_SECRET', 'ignored-retired-secret')
    current = login(c)
    assert c.patch('/api/management/settings', headers=headers(current), json={'login_failure_limit': 3}).status_code == 200
    for _ in range(3):
        failed = c.post('/api/auth/login', json={'username': 'admin', 'password': 'WrongPassword123!', 'otp': 'unused'})
        assert failed.status_code == 401 and failed.json() == {'detail': '账号或密码不正确'}
    assert c.post('/api/auth/login', json={'username': 'admin', 'password': 'TestAdmin123!'}).status_code == 429
    # A login lock does not silently alter or revoke the existing valid session.
    assert c.get('/api/auth/me', headers=headers(current)).status_code == 200


@pytest.mark.parametrize('field,value', [('enabled', 0), ('deleted_at', '2026-11-03T00:00:00Z')])
def test_password_only_does_not_admit_disabled_or_deleted_admin(c, field, value):
    with api.db() as conn:
        conn.execute('UPDATE users SET ' + field + '=? WHERE username=?', (value, 'admin'))
    rejected = c.post('/api/auth/login', json={'username': 'admin', 'password': 'TestAdmin123!'})
    assert rejected.status_code == 401 and rejected.json() == {'detail': '账号或密码不正确'}


def test_malformed_ids_are_rejected_without_server_error(c):
    h=headers(login(c))
    bad=question_payload();bad["subject_id"]={"unexpected":"object"}
    assert c.post("/api/management/questions",headers=h,json=bad).status_code==422
    assert c.post("/api/management/classes",headers=h,json={"name":"班级","term":"2027","teacher_id":[],"subject_group_id":"group-mechanics"}).status_code==422
    assert c.patch("/api/management/groups/group-mechanics",headers=h,json={"enabled":"false"}).status_code==422


def test_deletion_worker_recovers_from_transient_failure(c,monkeypatch,caplog):
    from contextlib import contextmanager
    state={"ticks":0,"attempts":0,"executed":0}
    async def tick(_):
        state["ticks"]+=1
        if state["ticks"]>2:raise asyncio.CancelledError()
    @contextmanager
    def flaky_db():
        state["attempts"]+=1
        if state["attempts"]==1:raise sqlite3.OperationalError("private student value must not be logged")
        yield None
    def executed(_):state["executed"]+=1
    monkeypatch.setattr(api.asyncio,"sleep",tick)
    monkeypatch.setattr(api,"db",flaky_db)
    monkeypatch.setattr(api,"execute_deletions",executed)
    with pytest.raises(asyncio.CancelledError):asyncio.run(api.deletion_worker())
    assert state["attempts"]==2 and state["executed"]==1
    assert "OperationalError" in caplog.text and "private student value" not in caplog.text
