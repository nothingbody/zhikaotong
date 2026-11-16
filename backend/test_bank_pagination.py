"""Remote pages preserve scope, ordering, media, and the exact bulk-selection set."""
import pytest

from . import app as core
from .test_api import c, headers, login


def populate():
    with core.db() as conn:
        seed = core.one(conn, 'SELECT * FROM questions LIMIT 1')
        conn.execute('DELETE FROM questions')
        for number in range(57):
            item = {**seed, 'id': f'page-{number:03d}', 'subject_id': 'math', 'knowledge_id': 'math-basic',
                    'type': 'fill' if number % 3 == 0 else 'single',
                    'stem': f'分页题目 {number:03d}', 'source': '来源-100%_下划线\\原文' if number == 5 else '同一批次原文',
                    'status': 'deleted' if number == 56 else 'offline' if number >= 52 else 'pending' if number == 51 else 'published',
                    'created_at': '2026-11-03T00:00:00Z', 'updated_at': '2026-11-03T00:00:00Z'}
            columns = list(item)
            conn.execute('INSERT INTO questions(' + ','.join(columns) + ') VALUES(' + ','.join('?' for _ in columns) + ')', [item[key] for key in columns])
        other = {**seed, 'id': 'other-subject', 'subject_id': 'english', 'knowledge_id': 'english-basic', 'stem': '另一科来源-100%_下划线\\原文'}
        columns = list(other)
        conn.execute('INSERT INTO questions(' + ','.join(columns) + ') VALUES(' + ','.join('?' for _ in columns) + ')', [other[key] for key in columns])


def test_real_pages_order_clamping_and_projection(c, monkeypatch):
    auth = headers(login(c))
    populate()
    # Loading a single page or counts must never deserialize the whole bank.
    monkeypatch.setattr(core, 'current_bank', lambda *_: pytest.fail('Full bank loaded'))
    pages = [c.get('/api/management/questions/page', headers=auth, params={'subject_id': 'math', 'page': page}).json() for page in (1, 2, 3)]
    assert [len(page['items']) for page in pages] == [20, 20, 16]
    assert all(page['total'] == 56 and page['pages'] == 3 and page['subject_id'] == 'math' for page in pages)
    actual = [item['id'] for page in pages for item in page['items']]
    assert actual == [f'page-{number:03d}' for number in range(55, -1, -1)]
    assert len(set(actual)) == len(actual)
    assert {'authorization', 'status', 'creator_id', 'reviewer_id', 'created_at', 'updated_at', 'version'} <= set(pages[0]['items'][0])
    last = c.get('/api/management/questions/page?subject_id=math&page=999', headers=auth).json()
    assert last['page'] == 3 and last['items'] == pages[-1]['items']
    for endpoint in ('summary', 'classifications'):
        assert c.get('/api/management/bank/' + endpoint, headers=auth).status_code == 200


def test_filters_and_identifier_selection_match_every_page(c):
    auth = headers(login(c))
    populate()
    for filters, expected in [({'status': 'offline'}, 4), ({'status': 'unpublished'}, 1), ({'status': 'published', 'type': 'fill'}, 17), ({'status': 'deleted'}, 1), ({'q': '100%_下划线\\'}, 1), ({'q': '_'}, 1), ({'q': '分页题目 00'}, 10)]:
        params = {'subject_id': 'math', 'page_size': 7, **filters}
        response = c.get('/api/management/questions/page', headers=auth, params=params)
        assert response.status_code == 200, response.text
        page = response.json()
        assert page['total'] == expected
        selected = c.get('/api/management/questions/ids', headers=auth, params={key: value for key, value in params.items() if key != 'page_size'}).json()
        identifiers = []
        for index in range(1, page['pages'] + 1):
            identifiers.extend(item['id'] for item in c.get('/api/management/questions/page', headers=auth, params={**params, 'page': index}).json()['items'])
        assert selected == {'ids': identifiers, 'total': expected, 'subject_id': 'math'}
    empty = c.get('/api/management/questions/page?subject_id=math&q=没有这个题目&page=9', headers=auth).json()
    assert empty['items'] == [] and empty['total'] == 0 and empty['page'] == empty['pages'] == 1


def test_validation_and_admin_only_access(c):
    auth = headers(login(c))
    for endpoint in ('page', 'ids'):
        base = '/api/management/questions/' + endpoint
        assert c.get(base, headers=auth).status_code == 422
        assert c.get(base + '?subject_id=', headers=auth).status_code == 422
        assert c.get(base + '?subject_id=missing', headers=auth).status_code == 404
        for invalid in ('type=essay', 'status=unknown', 'q=' + 'a' * 101):
            assert c.get(base + '?subject_id=math&' + invalid, headers=auth).status_code == 422
        for role in ('teacher', 'student'):
            assert c.get(base + '?subject_id=math', headers=headers(login(c, role))).status_code == 403
        assert c.get(base + '?subject_id=math').status_code == 401
        assert c.get(base + '?subject_id=math', headers={**auth, 'X-Zhikaotong-Surface': 'app'}).status_code == 403
    for invalid in ('page=0', 'page_size=0', 'page_size=101', 'page=1000001'):
        assert c.get('/api/management/questions/page?subject_id=math&' + invalid, headers=auth).status_code == 422


def test_media_is_preserved_only_for_returned_page(c, monkeypatch):
    from .test_question_media import image
    auth = headers(login(c))
    populate()
    # The two-asset fixture has an actual PNG and its verified digest.
    digest, asset = image()
    with core.db() as conn:
        conn.execute('UPDATE questions SET stem=?,media=? WHERE id=?', ('原图 {{img:' + digest + '}}', core.canonical({digest: asset}), 'page-055'))
    monkeypatch.setattr(core, 'current_bank', lambda *_: pytest.fail('Full bank loaded'))
    result = c.get('/api/management/questions/page?subject_id=math&page_size=1', headers=auth).json()
    assert result['items'][0]['media'] == {digest: asset}
    second = c.get('/api/management/questions/page?subject_id=math&page_size=1&page=2', headers=auth).json()
    assert not second['items'][0].get('media')
    identifiers = c.get('/api/management/questions/ids?subject_id=math', headers=auth).json()
    assert set(identifiers) == {'ids', 'total', 'subject_id'}


def test_selection_over_batch_limit_is_explicitly_rejected(c):
    auth = headers(login(c))
    with core.db() as conn:
        seed = core.one(conn, "SELECT * FROM questions WHERE subject_id='math' LIMIT 1")
        columns = list(seed)
        query = 'INSERT INTO questions(' + ','.join(columns) + ') VALUES(' + ','.join('?' for _ in columns) + ')'
        conn.executemany(query, [[('large-' + str(number)) if key == 'id' else seed[key] for key in columns] for number in range(5001)])
    result = c.get('/api/management/questions/ids?subject_id=math', headers=auth)
    assert result.status_code == 422 and '5000' in result.json()['detail']
    page = c.get('/api/management/questions/page?subject_id=math&page_size=100', headers=auth).json()
    assert page['total'] > 5000 and len(page['items']) == 100
