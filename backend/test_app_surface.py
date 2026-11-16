"""The phone gateway cannot expose or mutate private administrator sessions."""
from .test_api import c, activate, headers, login


APP = {'X-Zhikaotong-Surface': 'app'}


def test_app_login_rejects_admin_without_issuing_or_revoking_private_session(c):
    session = login(c)
    for password in ('TestAdmin123!', 'wrong-password'):
        response = c.post('/api/auth/login', headers=APP, json={'username': 'admin', 'password': password})
        assert response.status_code == 403
    assert c.get('/api/auth/me', headers=headers(session)).status_code == 200
    from . import app
    with app.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM sessions WHERE user_id=? AND revoked=0', (session['user']['id'],)).fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM login_limits WHERE key='user:admin'").fetchone()[0] == 0


def test_private_admin_access_and_refresh_cannot_be_used_via_mobile_surface(c):
    session = login(c)
    restricted = {**headers(session), **APP}
    for path in ('/api/auth/me', '/api/management/users', '/api/management/classes', '/api/teaching/catalog'):
        assert c.get(path, headers=restricted).status_code == 403
    denied = c.post('/api/auth/refresh', headers=APP, json={'refresh_token': session['refresh_token']})
    assert denied.status_code == 403
    assert c.get('/api/auth/me', headers=headers(session)).status_code == 200
    rotated = c.post('/api/auth/refresh', json={'refresh_token': session['refresh_token']})
    assert rotated.status_code == 200
    assert c.get('/api/management/users', headers=headers(rotated.json())).status_code == 200


def test_replayed_private_admin_refresh_on_mobile_cannot_revoke_rotated_session(c):
    original = login(c)
    rotated = c.post('/api/auth/refresh', json={'refresh_token': original['refresh_token']})
    assert rotated.status_code == 200
    denied = c.post('/api/auth/refresh', headers=APP, json={'refresh_token': original['refresh_token']})
    assert denied.status_code == 403
    assert c.get('/api/auth/me', headers=headers(rotated.json())).status_code == 200
    private_replay = c.post('/api/auth/refresh', json={'refresh_token': original['refresh_token']})
    assert private_replay.status_code == 401
    assert c.get('/api/auth/me', headers=headers(rotated.json())).status_code == 401


def test_student_and_teacher_mobile_login_refresh_and_role_boundaries(c):
    for name in ('student', 'teacher'):
        response = c.post('/api/auth/login', headers=APP, json={'username': name, 'password': 'Test' + name.title() + '123!'})
        assert response.status_code == 200
        session = response.json()
        assert session['user']['role'] == name
        assert c.get('/api/auth/me', headers={**headers(session), **APP}).status_code == 200
        refreshed = c.post('/api/auth/refresh', headers=APP, json={'refresh_token': session['refresh_token']})
        assert refreshed.status_code == 200
        current = {**headers(refreshed.json()), **APP}
        if name == 'teacher':
            assert c.get('/api/management/classes', headers=current).status_code == 200
            assert c.get('/api/teaching/catalog', headers=current).status_code == 200
            assert c.get('/api/management/settings', headers=current).status_code == 403
        assert c.post('/api/auth/logout', headers=current, json={'refresh_token': refreshed.json()['refresh_token']}).status_code == 200


def test_activated_mobile_student_keeps_school_practice_and_private_admin_unchanged(c):
    student = activate(c)
    current = {**headers(student), **APP}
    assert c.get('/api/questions?subject_id=math', headers=current).status_code == 200
    assert c.get('/api/student/assignments', headers=current).status_code == 200
    assert c.post('/api/management/questions', headers=current, json={}).status_code == 403
    assert c.get('/api/management/settings', headers=headers(login(c))).status_code == 200
