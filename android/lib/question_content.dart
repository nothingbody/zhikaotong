import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

final _imageMarker = RegExp(r'\{\{img:([^{}\s]*)\}\}');
final _digest = RegExp(r'^[0-9a-f]{64}$');
const _maximumImageBytes = 1024 * 1024;
const _maximumPixels = 16 * 1024 * 1024;
const _maximumCacheBytes = 12 * 1024 * 1024;

class _VerifiedImage {
  final String encoded, mime;
  final Uint8List bytes;
  final int width, height;
  const _VerifiedImage(
    this.encoded,
    this.mime,
    this.bytes,
    this.width,
    this.height,
  );
}

final _verifiedImages = LinkedHashMap<String, _VerifiedImage>();
int _cacheBytes = 0;

(int, int)? _dimensions(Uint8List bytes, String mime) {
  if (mime == 'image/png') {
    if (bytes.length < 24 ||
        bytes[0] != 137 ||
        String.fromCharCodes(bytes.sublist(1, 4)) != 'PNG' ||
        bytes[4] != 13 ||
        bytes[5] != 10 ||
        bytes[6] != 26 ||
        bytes[7] != 10 ||
        String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    return (data.getUint32(16), data.getUint32(20));
  }
  if (mime != 'image/jpeg' ||
      bytes.length < 4 ||
      bytes[0] != 255 ||
      bytes[1] != 216) {
    return null;
  }
  var offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset] != 255) return null;
    while (offset < bytes.length && bytes[offset] == 255) {
      offset++;
    }
    if (offset >= bytes.length) return null;
    final marker = bytes[offset++];
    if (marker == 217 || marker == 218) return null;
    if (marker == 216 || marker == 1 || (marker >= 208 && marker <= 215))
      continue;
    if (offset + 2 > bytes.length) return null;
    final length = bytes[offset] * 256 + bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) return null;
    if (const {
      192,
      193,
      194,
      195,
      197,
      198,
      199,
      201,
      202,
      203,
      205,
      206,
      207,
    }.contains(marker)) {
      if (length < 7) return null;
      return (
        bytes[offset + 5] * 256 + bytes[offset + 6],
        bytes[offset + 3] * 256 + bytes[offset + 4],
      );
    }
    offset += length;
  }
  return null;
}

_VerifiedImage? _readImage(Map<String, dynamic> question, String hash) {
  if (!_digest.hasMatch(hash)) return null;
  final media = question['media'];
  if (media is! Map || media[hash] is! Map) return null;
  final item = media[hash] as Map;
  final encoded = item['data'], mime = item['mime'];
  final width = item['width'], height = item['height'];
  if (encoded is! String ||
      encoded.length > (_maximumImageBytes + 2) ~/ 3 * 4 ||
      !const {'image/png', 'image/jpeg'}.contains(mime) ||
      width is! int ||
      height is! int ||
      width <= 0 ||
      height <= 0 ||
      width > 8192 ||
      height > 8192 ||
      width * height > _maximumPixels) {
    return null;
  }
  final cached = _verifiedImages.remove(hash);
  if (cached != null) {
    _verifiedImages[hash] = cached;
    if (cached.encoded == encoded &&
        cached.mime == mime &&
        cached.width == width &&
        cached.height == height)
      return cached;
  }
  try {
    final bytes = base64Decode(encoded);
    if (bytes.isEmpty ||
        bytes.length > _maximumImageBytes ||
        sha256.convert(bytes).toString() != hash ||
        _dimensions(bytes, mime) != (width, height)) {
      return null;
    }
    final image = _VerifiedImage(encoded, mime, bytes, width, height);
    final replaced = _verifiedImages.remove(hash);
    if (replaced != null) _cacheBytes -= replaced.bytes.length;
    _verifiedImages[hash] = image;
    _cacheBytes += bytes.length;
    while (_cacheBytes > _maximumCacheBytes && _verifiedImages.length > 1) {
      final removed = _verifiedImages.remove(_verifiedImages.keys.first)!;
      _cacheBytes -= removed.bytes.length;
    }
    return image;
  } catch (_) {
    return null;
  }
}

/// Renders Word text and its original local images in the source order.
/// Image bytes live in the downloaded question JSON; this widget makes no HTTP calls.
class QuestionContent extends StatelessWidget {
  final Map<String, dynamic> question;
  final String text;
  final TextStyle? style;
  final bool selectable;
  const QuestionContent({
    super.key,
    required this.question,
    required this.text,
    this.style,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    final matches = _imageMarker.allMatches(text).toList();
    if (matches.isEmpty) {
      return selectable
          ? SelectableText(text, style: style)
          : Text(text, style: style);
    }
    final effectiveStyle = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 48;
        final spans = <InlineSpan>[];
        var cursor = 0;
        for (final match in matches.take(128)) {
          if (match.start > cursor)
            spans.add(TextSpan(text: text.substring(cursor, match.start)));
          final hash = match[1]!;
          final verified = _readImage(question, hash);
          final blockImage = verified != null && verified.height > 180;
          if (blockImage &&
              spans.isNotEmpty &&
              (spans.last is! TextSpan ||
                  !((spans.last as TextSpan).text ?? '').endsWith('\n'))) {
            spans.add(const TextSpan(text: '\n'));
          }
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: verified == null
                  ? const _MissingImage()
                  : _QuestionImage(
                      key: ValueKey('question-image-$hash'),
                      image: verified,
                      maxWidth: math.max(1, availableWidth - 4),
                    ),
            ),
          );
          if (blockImage &&
              match.end < text.length &&
              text[match.end] != '\n') {
            spans.add(const TextSpan(text: '\n'));
          }
          cursor = match.end;
        }
        if (matches.length > 128) {
          spans.add(
            const WidgetSpan(child: _MissingImage(message: '题目图片过多，请联系管理员核对')),
          );
        } else if (cursor < text.length) {
          spans.add(TextSpan(text: text.substring(cursor)));
        }
        final content = TextSpan(style: effectiveStyle, children: spans);
        return selectable ? SelectableText.rich(content) : Text.rich(content);
      },
    );
  }
}

class _MissingImage extends StatelessWidget {
  final String message;
  const _MissingImage({this.message = '图片缺失或校验失败，请联网刷新题库'});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
    child: Text(
      '⚠ $message',
      style: const TextStyle(
        color: Color(0xFFB42318),
        fontSize: 13,
        height: 1.5,
      ),
    ),
  );
}

class _QuestionImage extends StatelessWidget {
  final _VerifiedImage image;
  final double maxWidth;
  const _QuestionImage({
    super.key,
    required this.image,
    required this.maxWidth,
  });
  @override
  Widget build(BuildContext context) {
    // Word rasterized formulas commonly use twice a screen's logical pixel scale.
    // Fit the complete image; tap-to-zoom retains the original pixels.
    var width = math.min(maxWidth, math.max(24.0, image.width / 2));
    var height = width * image.height / image.width;
    if (height > 400) {
      width *= 400 / height;
      height = 400;
    }
    if (height < 20) {
      height = 20;
    }
    return Semantics(
      button: true,
      label: '题目图片，点按放大',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _OriginalImagePage(image: image),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
          child: Image.memory(
            image.bytes,
            width: width,
            height: height,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, trace) => const _MissingImage(),
          ),
        ),
      ),
    );
  }
}

class _OriginalImagePage extends StatelessWidget {
  final _VerifiedImage image;
  const _OriginalImagePage({required this.image});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('原图'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      leading: IconButton(
        tooltip: '关闭图片',
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
    ),
    body: SafeArea(
      child: InteractiveViewer(
        minScale: 1,
        maxScale: 8,
        child: Center(
          child: Image.memory(
            image.bytes,
            fit: BoxFit.contain,
            errorBuilder: (context, error, trace) => const _MissingImage(),
          ),
        ),
      ),
    ),
  );
}
