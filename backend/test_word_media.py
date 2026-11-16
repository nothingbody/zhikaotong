"""Original media is retained, document-bound and never fabricated."""
import base64
import binascii
import hashlib
import io
import json
import zipfile
import struct
import zlib
from pathlib import Path
from xml.etree import ElementTree as ET

from . import word_media as media


ROOT = Path(__file__).resolve().parents[1]

def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)


PNG = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 6, 0, 0, 0)) + png_chunk(b'IDAT', zlib.compress(b'\x00\xff\xff\xff\xff')) + png_chunk(b'IEND', b'')


def node(identifier):
    return ET.fromstring('<object xmlns:v="urn:schemas-microsoft-com:vml" xmlns:r="' + media.R + '"><v:shape><v:imagedata r:id="' + identifier + '"/></v:shape></object>')


def minimal_doc(image=PNG, target='media/figure.png', external=False):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as archive:
        archive.writestr('word/document.xml', '<document/>')
        archive.writestr('word/_rels/document.xml.rels', '<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="' + target + '"' + (' TargetMode="External"' if external else '') + '/></Relationships>')
        archive.writestr('word/media/figure.png', image)
    return output.getvalue()








def test_unrelated_png_is_self_contained_but_external_and_traversal_are_unresolved():
    context = media.load_word_media(minimal_doc())
    token = context.render_element(node('rId1'))
    assert token and context.media_for_text(token)
    assert media.load_word_media(minimal_doc(external=True)).render_element(node('rId1')) is None
    assert media.load_word_media(minimal_doc(target='../media/figure.png')).render_element(node('rId1')) is None


def test_corrupt_or_oversized_image_is_not_treated_as_resolved():
    assert media.load_word_media(minimal_doc(PNG[:25])).render_element(node('rId1')) is None
    damaged = PNG[:-8] + bytes([PNG[-8] ^ 1]) + PNG[-7:]
    assert media.load_word_media(minimal_doc(damaged)).render_element(node('rId1')) is None




def test_synthetic_source_bound_cache_is_verified_and_tampering_blocks_answers(tmp_path, monkeypatch):
    raw = minimal_doc()
    digest = hashlib.sha256(PNG).hexdigest()
    cached = digest + '.png'
    manifest = {
        'document_sha256': hashlib.sha256(raw).hexdigest(),
        'images': {'word/media/figure.png': {
            'source_sha256': digest, 'file': cached, 'sha256': digest}},
        'answer_transcriptions': {'1': {
            'answer': 'synthetic answer', 'source_images': ['word/media/figure.png']}}
    }
    (tmp_path / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
    (tmp_path / cached).write_bytes(PNG)
    monkeypatch.setattr(media, 'ASSET_ROOT', tmp_path)
    context = media.load_word_media(raw)
    assert context._bound is not None
    assert context.render_element(node('rId1'))
    assert context.answer_override(1) == 'synthetic answer'
    (tmp_path / cached).write_bytes(b'tampered')
    changed = media.load_word_media(raw)
    assert changed.render_element(node('rId1')) is None
    assert changed.answer_override(1) is None
    unbound = media.load_word_media(raw + b'changed')
    assert unbound._bound is None
    assert unbound.answer_override(1) is None
