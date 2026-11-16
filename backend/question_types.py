"""Question validation and grading shared by online practice and imported banks."""
import re


def normalize_fill_answer(value: str) -> str:
    # Keep this identical to the Flutter implementation, without evaluating expressions.
    converted = ''.join(chr(ord(char) - 0xFEE0) if 0xFF01 <= ord(char) <= 0xFF5E else ' ' if char in ('\u3000', '\u00a0') else char for char in value)
    return re.sub(r'\s+', ' ', converted).strip().lower()


def grade_question(question, selected):
    if question['type'] == 'fill':
        answers = question['answer']
        return len(selected) == len(answers) and all(
            normalize_fill_answer(actual) and any(normalize_fill_answer(actual) == normalize_fill_answer(variant) for variant in variants)
            for actual, variants in zip(selected, answers)
        )
    return bool(selected) and set(selected) == set(question['answer'])


class BoundedBodyMiddleware:
    """Bound both Content-Length and streamed bodies before JSON decoding."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        from starlette.responses import JSONResponse
        maximum = 22_000_000 if scope.get('path') == '/api/management/imports/word/preview' else 2_000_000
        headers = dict(scope.get('headers', []))
        length = headers.get(b'content-length')
        if length is not None and (not length.isdigit() or int(length) > maximum):
            return await JSONResponse({'detail': '请求体过大'}, 413)(scope, receive, send)
        events, total = [], 0
        while True:
            event = await receive()
            if event['type'] == 'http.disconnect':
                return
            total += len(event.get('body', b''))
            if total > maximum:
                return await JSONResponse({'detail': '请求体过大'}, 413)(scope, receive, send)
            events.append(event)
            if not event.get('more_body', False):
                break
        index = 0
        async def replay():
            nonlocal index
            if index < len(events):
                event = events[index]
                index += 1
                return event
            return await receive()
        await self.app(scope, replay, send)
