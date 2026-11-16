"""Continuous cursors are bounded, scoped, deterministic and version safe."""
from . import app as core
from .test_api import activate, c, headers, login


def test_stream_batches_cover_pool_once_and_can_start_another_round(c):
    auth = headers(activate(c))
    assert any(subject['id']=='politics' for subject in c.get('/api/subjects',headers=auth).json())
    initial = c.get('/api/questions/continuous', headers=auth, params={'shuffle': True, 'limit': 3}).json()
    assert len(initial['questions']) == 3 and initial['total'] == 10
    collected = [item['id'] for item in initial['questions']]
    current = initial
    while current['has_more']:
        params = {'shuffle': True, 'limit': 3, 'offset': current['next_offset'], 'version': current['version'], 'seed': current['seed'], 'pool_hash': current['pool_hash']}
        response = c.get('/api/questions/continuous', headers=auth, params=params)
        assert response.status_code == 200, response.text
        current = response.json()
        assert c.get('/api/questions/continuous', headers=auth, params=params).json() == current
        collected.extend(item['id'] for item in current['questions'])
    assert len(collected) == len(set(collected)) == initial['total']
    assert current['next_offset'] == current['total']
    next_round = c.get('/api/questions/continuous', headers=auth, params={'shuffle': True, 'version': current['version'], 'pool_hash': current['pool_hash']}).json()
    assert next_round['seed'] != initial['seed'] and next_round['offset'] == 0
    assert all(item['version'] == initial['version'] for item in next_round['questions'])


def test_stream_scope_version_filters_and_empty_pool(c):
    session = activate(c);auth = headers(session)
    first = c.get('/api/questions/continuous?subject_id=math&type=single&difficulty=1&limit=1', headers=auth).json()
    assert first['total'] == 2 and first['questions'][0]['type'] == 'single'
    continuation = {'subject_id': 'math', 'type': 'single', 'difficulty': 1, 'offset': 1, 'version': first['version'], 'seed': first['seed'], 'pool_hash': first['pool_hash']}
    with core.db() as conn:
        core.publish_bank(conn, session['user']['id'])
    assert c.get('/api/questions/continuous', headers=auth, params=continuation).status_code == 409
    fresh = c.get('/api/questions/continuous?subject_id=math&limit=1', headers=auth).json()
    with core.db() as conn:
        conn.execute("UPDATE groups SET subject_ids=? WHERE id='group-mechanics'", (core.canonical(['chinese']),))
    assert c.get('/api/questions/continuous?subject_id=math', headers=auth).status_code == 403
    assert c.get('/api/questions/continuous', headers=auth, params={'version': fresh['version'], 'pool_hash': fresh['pool_hash']}).status_code == 409
    empty = c.get('/api/questions/continuous?type=fill', headers=auth).json()
    assert empty['total'] == empty['next_offset'] == 0 and empty['questions'] == [] and not empty['has_more']


def test_stream_validates_cursor_and_roles(c):
    auth = headers(activate(c))
    for query in ('limit=51', 'offset=-1', 'offset=1', 'mode=wrong', 'type=essay', 'difficulty=0', 'seed=bad', 'pool_hash=nope'):
        assert c.get('/api/questions/continuous?' + query, headers=auth).status_code == 422
    for role in ('teacher', 'admin'):
        assert c.get('/api/questions/continuous', headers=headers(login(c, role))).status_code == 403
    assert c.get('/api/questions/continuous').status_code == 401


def test_stream_keeps_source_images_and_requires_capable_phone(c):
    from .test_question_media import image
    digest, asset = image()
    auth = headers(activate(c))
    with core.db() as conn:
        target = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' ORDER BY id LIMIT 1")
        conn.execute('UPDATE questions SET stem=?,media=? WHERE id=?', ('原图 {{img:' + digest + '}}', core.canonical({digest: asset}), target['id']))
        core.publish_bank(conn, 'fixture')
    assert c.get('/api/questions/continuous?subject_id=math', headers={**auth, 'X-Zhikaotong-Surface': 'app'}).status_code == 426
    response = c.get('/api/questions/continuous?subject_id=math', headers={**auth, 'X-Zhikaotong-Surface': 'app', 'X-Question-Content': 'media-v1'})
    assert response.status_code == 200
    question = next(item for item in response.json()['questions'] if item['id'] == target['id'])
    assert question['media'] == {digest: asset}
