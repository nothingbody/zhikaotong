"""Retain source Word pictures and verified previews of legacy equations.

The school document's legacy WMF previews were rasterized without altering their
content. The cache is bound to the exact DOCX and each original image checksum.
Other documents may embed PNG/JPEG directly; unknown WMF remains unresolved.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import io
import json
import re
import struct
import zipfile
from pathlib import Path, PurePosixPath
from xml.etree import ElementTree as ET


ASSET_ROOT = Path(__file__).with_name('word_assets')
MAX_DOCUMENT_BYTES = 20 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 100 * 1024 * 1024
MAX_IMAGE_BYTES = 2 * 1024 * 1024
MAX_IMAGE_SIDE = 4096
MAX_IMAGE_PIXELS = 10_000_000
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
V = 'urn:schemas-microsoft-com:vml'
TOKEN = re.compile(r'\{\{img:([a-f0-9]{64})\}\}')


def _image_info(raw: bytes):
    """Bound dimensions before handing source image bytes to a client decoder."""
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        return None
    if raw.startswith(b'\x89PNG\r\n\x1a\n') and len(raw) >= 33:
        if raw[12:16] != b'IHDR' or raw[8:12] != b'\x00\x00\x00\r':
            return None
        width, height = struct.unpack('>II', raw[16:24])
        index, saw_data, saw_end = 8, False, False
        while index + 12 <= len(raw):
            size = struct.unpack('>I', raw[index:index + 4])[0]
            end = index + 12 + size
            if end > len(raw):
                return None
            chunk = raw[index + 4:index + 8]
            expected = struct.unpack('>I', raw[index + 8 + size:end])[0]
            if binascii.crc32(raw[index + 4:index + 8 + size]) & 0xffffffff != expected:
                return None
            saw_data |= chunk == b'IDAT'
            index = end
            if chunk == b'IEND':
                saw_end = size == 0
                break
        if not saw_data or not saw_end or index != len(raw):
            return None
        mime = 'image/png'
    elif raw.startswith(b'\xff\xd8') and raw.endswith(b'\xff\xd9'):
        index = 2
        width = height = 0
        while index + 4 <= len(raw):
            if raw[index] != 0xff:
                return None
            while index < len(raw) and raw[index] == 0xff:
                index += 1
            if index >= len(raw):
                break
            marker = raw[index]
            index += 1
            if marker in (0xd8, 0xd9) or 0xd0 <= marker <= 0xd7:
                continue
            if index + 2 > len(raw):
                return None
            length = struct.unpack('>H', raw[index:index + 2])[0]
            if length < 2 or index + length > len(raw):
                return None
            if marker in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf):
                if length < 8:
                    return None
                height, width = struct.unpack('>HH', raw[index + 3:index + 7])
                break
            index += length
        mime = 'image/jpeg'
    else:
        return None
    if not (0 < width <= MAX_IMAGE_SIDE and 0 < height <= MAX_IMAGE_SIDE and width * height <= MAX_IMAGE_PIXELS):
        return None
    return mime, width, height


class WordMediaContext:
    def __init__(self, raw: bytes):
        self.document_sha256 = hashlib.sha256(raw).hexdigest()
        self._relations = {}
        self._sources = {}
        self._resolved = {}
        self._assets = {}
        self._bound = None
        try:
            manifest = json.loads((ASSET_ROOT / 'manifest.json').read_text(encoding='utf-8'))
            if isinstance(manifest, dict) and manifest.get('document_sha256') == self.document_sha256:
                self._bound = manifest
        except (OSError, ValueError, TypeError):
            pass
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            members = archive.infolist()
            names = [member.filename for member in members]
            if len(members) > 10000 or len(names) != len(set(names)) or sum(member.file_size for member in members) > MAX_UNCOMPRESSED_BYTES:
                raise ValueError('Word media package exceeds bounds')
            try:
                relations = archive.read('word/_rels/document.xml.rels')
            except KeyError:
                relations = b''
            if len(relations) <= 2 * 1024 * 1024 and b'<!DOCTYPE' not in relations.upper() and b'<!ENTITY' not in relations.upper():
                for relation in ET.fromstring(relations) if relations else []:
                    if relation.get('TargetMode') == 'External' or not relation.get('Type', '').endswith('/image'):
                        continue
                    target = PurePosixPath(relation.get('Target', ''))
                    if target.is_absolute() or '..' in target.parts:
                        continue
                    source = 'word/' + str(target)
                    if source.startswith('word/media/'):
                        self._relations[relation.get('Id')] = source
            for name in set(self._relations.values()):
                try:
                    info = archive.getinfo(name)
                    if info.file_size <= MAX_IMAGE_BYTES:
                        self._sources[name] = archive.read(name)
                except KeyError:
                    continue

    def _resolve(self, source: str):
        if source in self._resolved:
            return self._resolved[source]
        self._resolved[source] = None
        original = self._sources.get(source)
        if original is None:
            return None
        rendered = original
        bound = (self._bound or {}).get('images', {}).get(source)
        if bound:
            if hashlib.sha256(original).hexdigest() != bound.get('source_sha256'):
                return None
            file_name = bound.get('file', '')
            if not re.fullmatch(r'[a-f0-9]{64}\.(?:png|jpg)', file_name):
                return None
            try:
                rendered = (ASSET_ROOT / file_name).read_bytes()
            except OSError:
                return None
            if hashlib.sha256(rendered).hexdigest() != bound.get('sha256'):
                return None
        info = _image_info(rendered)
        if info is None:
            return None
        mime, width, height = info
        digest = hashlib.sha256(rendered).hexdigest()
        self._assets[digest] = {'mime': mime, 'data': base64.b64encode(rendered).decode('ascii'), 'width': width, 'height': height}
        self._resolved[source] = digest
        return digest

    def render_element(self, element):
        identifiers = []
        for child in element.iter():
            if child.tag == '{' + V + '}imagedata':
                identifiers.append(child.get('{' + R + '}id'))
            elif child.tag == '{' + A + '}blip':
                identifiers.append(child.get('{' + R + '}embed'))
        identifiers = list(dict.fromkeys(identifier for identifier in identifiers if identifier))
        if not identifiers:
            return None
        tokens = []
        for identifier in identifiers:
            source = self._relations.get(identifier)
            if not source:
                return None
            # This source figure is anchored to the fill-section heading but is
            # explicitly the following paper5 question15 figure. Relocate it.
            if source in (self._bound or {}).get('relocated_images', {}):
                if self._resolve(source) is None:
                    return None
                continue
            digest = self._resolve(source)
            if digest is None:
                return None
            tokens.append('{{img:' + digest + '}}')
        return ''.join(tokens)

    def media_for_text(self, text):
        return {digest: dict(self._assets[digest]) for digest in dict.fromkeys(TOKEN.findall(text)) if digest in self._assets}

    def figure_tokens_for_question(self, source_index):
        tokens = []
        for source, target_index in (self._bound or {}).get('relocated_images', {}).items():
            if target_index == source_index:
                digest = self._resolve(source)
                if digest is None:
                    return None
                tokens.append('{{img:' + digest + '}}')
        return tokens

    def answer_override(self, source_index):
        # These are direct transcriptions of the supplied answer key, never
        # answers solved or inferred from the question itself.
        entry = (self._bound or {}).get('answer_transcriptions', {}).get(str(source_index))
        if not entry:
            return None
        for source in entry.get('source_images', []):
            if self._resolve(source) is None:
                return None
        return entry['answer']


def load_word_media(raw: bytes):
    if not isinstance(raw, bytes) or not raw or len(raw) > MAX_DOCUMENT_BYTES:
        return None
    try:
        return WordMediaContext(raw)
    except (zipfile.BadZipFile, OSError, ValueError, ET.ParseError, KeyError, RuntimeError, NotImplementedError):
        return None
