import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

// Configuration is fixed at build time; students never enter a server address.
const serviceBaseUrl = String.fromEnvironment(
  'SERVICE_BASE_URL',
  defaultValue: 'https://api.example.invalid:18443',
);
// Empty uses the platform trust store. A private deployment can bundle its own
// public root certificate and name that declared Flutter asset at build time.
const serviceCertificateAsset = String.fromEnvironment('SERVICE_CA_ASSET');

/// Retain normal certificate chain, expiry and hostname verification.
/// Certificate loading and network initialization happen only when [send] runs.
class SchoolServiceClient extends http.BaseClient {
  Future<IOClient>? _initializing;
  IOClient? _transport;
  bool _closed = false;

  Future<IOClient> _initialize() async {
    SecurityContext? context;
    if (serviceCertificateAsset.isNotEmpty) {
      final certificate = await rootBundle.load(serviceCertificateAsset);
      context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(Uint8List.sublistView(certificate));
    }
    if (_closed) throw http.ClientException('客户端已关闭');
    final native = HttpClient(context: context);
    final transport = IOClient(native);
    if (_closed) {
      transport.close();
      throw http.ClientException('客户端已关闭');
    }
    _transport = transport;
    return transport;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('客户端已关闭', request.url);
    final allowed = Uri.parse(serviceBaseUrl);
    if (allowed.scheme != 'https' ||
        allowed.host.isEmpty ||
        allowed.userInfo.isNotEmpty ||
        allowed.path.isNotEmpty ||
        allowed.hasQuery ||
        allowed.hasFragment) {
      throw http.ClientException('服务连接配置无效，请联系管理员');
    }
    if (request.url.scheme != allowed.scheme ||
        request.url.host != allowed.host ||
        request.url.port != allowed.port) {
      throw http.ClientException('服务地址与应用配置不一致', request.url);
    }
    // Do not follow redirects to another origin or to an unencrypted address.
    request.followRedirects = false;
    final transport = await (_initializing ??= _initialize());
    return transport.send(request);
  }

  @override
  void close() {
    _closed = true;
    _transport?.close();
    super.close();
  }
}
