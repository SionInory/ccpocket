import 'dart:convert';

import 'package:ccpocket/services/netbird_tunnel_service.dart';
import 'package:flutter_test/flutter_test.dart';

String _proxyUrl(
  String origin, {
  String scheme = 'ws',
  String path = '',
  String? query,
}) {
  final token = base64Url
      .encode(utf8.encode(origin))
      .replaceAll('=', '');
  return Uri(
    scheme: scheme,
    host: '127.0.0.1',
    port: 4567,
    path: '/t/$token$path',
    query: query,
  ).toString();
}

void main() {
  test('requires management, signal, and proxy to report connected', () {
    const snapshot = NetbirdTunnelSnapshot(
      state: NetbirdTunnelState.connected,
      proxyPort: 4567,
      managementConnected: true,
      signalConnected: false,
    );

    expect(snapshot.isConnected, isFalse);
    expect(snapshot.copyWith(signalConnected: true).isConnected, isTrue);
  });

  test('decodes a WebSocket proxy URL to its original URL', () {
    final proxyUrl = _proxyUrl(
      'https://bridge.example.com:8443',
      path: '/ws',
      query: 'token=secret',
    );

    expect(
      NetbirdTunnelService.originalUrlOf(proxyUrl),
      'wss://bridge.example.com:8443/ws?token=secret',
    );
  });

  test('decodes an HTTP proxy URL to its original URL', () {
    final proxyUrl = _proxyUrl(
      'http://192.168.1.20:8765',
      scheme: 'http',
    );

    expect(
      NetbirdTunnelService.originalUrlOf(proxyUrl),
      'http://192.168.1.20:8765',
    );
  });
}
