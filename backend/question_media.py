"""Self-contained raster source media shared by online and offline question views."""
import base64
import binascii
import hashlib
import re
import struct
import zlib


MEDIA_MARKER = re.compile(r'\{\{img:([a-f0-9]{64})\}\}')
MAX_IMAGE_BYTES = 1_000_000
MAX_QUESTION_BYTES = 1_400_000


def raster_size(raw, mime):
    if mime == 'image/png':
        if len(raw) < 33 or not raw.startswith(b'\x89PNG\r\n\x1a\n') or raw[12:16] != b'IHDR':
            raise ValueError('图片不是有效的PNG')
        offset, image_data, ended = 8, False, False
        while offset + 12 <= len(raw):
            length = int.from_bytes(raw[offset:offset + 4], 'big')
            end = offset + 12 + length
            if end > len(raw):
                break
            kind = raw[offset + 4:offset + 8]
            payload = raw[offset + 8:offset + 8 + length]
            checksum = int.from_bytes(raw[offset + 8 + length:end], 'big')
            if zlib.crc32(kind + payload) & 0xffffffff != checksum:
                raise ValueError('PNG数据校验失败')
            if offset == 8 and (kind != b'IHDR' or length != 13):
                raise ValueError('PNG头结构无效')
            image_data |= kind == b'IDAT' and length > 0
            offset = end
            if kind == b'IEND':
                ended = length == 0 and offset == len(raw)
                break
        if not ended or not image_data:
            raise ValueError('PNG图片内容不完整')
        return struct.unpack('>II', raw[16:24])
    if mime != 'image/jpeg' or not raw.startswith(b'\xff\xd8\xff') or not raw.endswith(b'\xff\xd9'):
        raise ValueError('图片须为PNG或JPEG')
    offset = 2
    while offset < len(raw):
        if raw[offset] != 255:
            raise ValueError('JPEG结构无效')
        while offset < len(raw) and raw[offset] == 255:
            offset += 1
        if offset >= len(raw):
            break
        marker = raw[offset]
        offset += 1
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            continue
        if offset + 2 > len(raw):
            break
        length = int.from_bytes(raw[offset:offset + 2], 'big')
        if length < 2 or offset + length > len(raw):
            break
        if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} and length >= 7:
            return int.from_bytes(raw[offset + 5:offset + 7], 'big'), int.from_bytes(raw[offset + 3:offset + 5], 'big')
        offset += length
    raise ValueError('JPEG缺少尺寸信息')


def referenced_media(question, include_explanation=True):
    texts = [question.get('stem', '')]
    options = question.get('options', [])
    if isinstance(options,list):
        texts.extend(option.get('text', '') for option in options if isinstance(option, dict))
    if include_explanation:
        texts.append(question.get('explanation', ''))
    return {match.group(1) for text in texts if isinstance(text, str) for match in MEDIA_MARKER.finditer(text)}


def validate_media(question):
    media = question.get('media', {})
    if not isinstance(media, dict) or len(media) > 64:
        raise ValueError('题图数据格式或数量无效')
    options = question.get('options', [])
    if not isinstance(options,list):
        raise ValueError('选项格式无效')
    texts = [question.get('stem', ''), question.get('explanation', ''), *(option.get('text', '') for option in options if isinstance(option, dict))]
    for text in texts:
        if isinstance(text, str) and text.count('{{img:') != len(MEDIA_MARKER.findall(text)):
            raise ValueError('题图引用格式无效')
    required = referenced_media(question)
    if required - set(media):
        raise ValueError('题目引用的原图缺失，不能发布不完整题目')
    clean, total = {}, 0
    for digest in required:
        item = media[digest]
        if not isinstance(item, dict) or item.get('mime') not in ('image/png', 'image/jpeg') or not isinstance(item.get('data'), str):
            raise ValueError('题图须为PNG或JPEG原图数据')
        if len(item['data']) > (MAX_IMAGE_BYTES + 2) // 3 * 4:
            raise ValueError('单张题图不能超过1MB')
        try:
            raw = base64.b64decode(item['data'], validate=True)
        except (ValueError, binascii.Error):
            raise ValueError('题图编码无效') from None
        if not raw or len(raw) > MAX_IMAGE_BYTES or hashlib.sha256(raw).hexdigest() != digest:
            raise ValueError('题图校验失败')
        width, height = raster_size(raw, item['mime'])
        if not 1 <= width <= 8192 or not 1 <= height <= 8192 or width * height > 16_000_000:
            raise ValueError('题图尺寸无效')
        total += len(raw)
        if total > MAX_QUESTION_BYTES:
            raise ValueError('单题图片总量过大')
        clean[digest] = {'mime': item['mime'], 'data': item['data'], 'width': width, 'height': height}
    # Do not retain unrelated source/answer images in a question payload.
    return clean


def visible_media(question, include_explanation=True):
    available = question.get('media', {})
    return {key: available[key] for key in referenced_media(question, include_explanation) if key in available}
