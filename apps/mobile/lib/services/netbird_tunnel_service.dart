import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/logger.dart';
import '../utils/platform_helper.dart';

enum NetbirdTunnelState {
  disabled,
  starting,
  connecting,
  connected,
  error,
  unsupported,
}

class NetbirdTunnelSnapshot {
  const NetbirdTunnelSnapshot({
    this.state = NetbirdTunnelState.disabled,
    this.error,
    this.proxyPort = 0,
    this.managementConnected = false,
    this.signalConnected = false,
    this.peerCount = 0,
    this.connectedPeers = 0,
  });

  final NetbirdTunnelState state;
  final String? error;
  final int proxyPort;
  final bool managementConnected;
  final bool signalConnected;
  final int peerCount;
  final int connectedPeers;

  bool get isConnected =>
      state == NetbirdTunnelState.connected &&
      proxyPort > 0 &&
      managementConnected &&
      signalConnected;

  NetbirdTunnelSnapshot copyWith({
    NetbirdTunnelState? state,
    String? error,
    bool clearError = false,
    int? proxyPort,
    bool? managementConnected,
    bool? signalConnected,
    int? peerCount,
    int? connectedPeers,
  }) {
    return NetbirdTunnelSnapshot(
      state: state ?? this.state,
      error: clearError ? null : (error ?? this.error),
      proxyPort: proxyPort ?? this.proxyPort,
      managementConnected:
          managementConnected ?? this.managementConnected,
      signalConnected: signalConnected ?? this.signalConnected,
      peerCount: peerCount ?? this.peerCount,
      connectedPeers: connectedPeers ?? this.connectedPeers,
    );
  }
}

class NetbirdTunnelException implements Exception {
  const NetbirdTunnelException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NetbirdSetupKeyRequired extends NetbirdTunnelException {
  const NetbirdSetupKeyRequired() : super('请先输入 Setup Key');
}

/// App-wide Netbird tunnel. The native side owns one userspace Netbird client
/// and exposes a loopback reverse proxy for Bridge HTTP/WebSocket traffic.
class NetbirdTunnelService extends ChangeNotifier {
  NetbirdTunnelService(
    this._prefs,
    this._secureStorage, {
    MethodChannel? channel,
    bool? supported,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _supported = supported ?? isAndroidPlatform;

  static const _channelName = 'ccpocket/netbird';
  static const _keyEnabled = 'netbird_enabled';
  static const _keyManagementUrl = 'netbird_management_url';
  static const _keyDeviceName = 'netbird_device_name';
  static const _secureSetupKey = 'netbird_setup_key';
  static const defaultDeviceName = 'ccpocket-android';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secureStorage;
  final MethodChannel _channel;
  final bool _supported;

  NetbirdTunnelSnapshot _snapshot = const NetbirdTunnelSnapshot();
  bool _enabled = false;
  bool _setupKeyPresent = false;
  bool _initialized = false;
  bool _nativeRunning = false;
  String _managementUrl = '';
  String _deviceName = defaultDeviceName;
  Future<void>? _startFuture;
  Timer? _statusTimer;

  NetbirdTunnelSnapshot get snapshot => _snapshot;
  bool get isEnabled => _enabled;
  bool get isConnected => _enabled && _snapshot.isConnected;
  bool get isSupported => _supported;
  bool get hasSetupKey => _setupKeyPresent;
  String get managementUrl => _managementUrl;
  String get deviceName => _deviceName;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _enabled = _prefs.getBool(_keyEnabled) ?? false;
    _managementUrl = _prefs.getString(_keyManagementUrl) ?? '';
    _deviceName =
        _prefs.getString(_keyDeviceName) ?? defaultDeviceName;
    _setupKeyPresent =
        (await _readSetupKey())?.isNotEmpty == true;

    if (!_supported) {
      _setSnapshot(
        const NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.unsupported,
        ),
      );
      return;
    }
    if (!_enabled) {
      _setSnapshot(const NetbirdTunnelSnapshot());
      return;
    }
    if (!_setupKeyPresent) {
      _setSnapshot(
        const NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.error,
          error: '缺少 Setup Key，请在 Netbird 设置中重新输入',
        ),
      );
      return;
    }
    unawaited(
      _start().catchError((Object error) {
        logger.warning('[netbird] startup failed: $error');
      }),
    );
  }

  Future<void> saveConfiguration({
    required String managementUrl,
    required String deviceName,
  }) async {
    final normalizedUrl = _normalizeManagementUrl(managementUrl);
    final normalizedName = deviceName.trim();
    if (normalizedUrl.isEmpty) {
      throw const NetbirdTunnelException('Management URL 不能为空');
    }
    if (normalizedName.isEmpty) {
      throw const NetbirdTunnelException('设备名不能为空');
    }
    _managementUrl = normalizedUrl;
    _deviceName = normalizedName;
    await _prefs.setString(_keyManagementUrl, normalizedUrl);
    await _prefs.setString(_keyDeviceName, normalizedName);
    notifyListeners();
  }

  Future<void> saveSetupKey(String setupKey) async {
    final value = setupKey.trim();
    if (value.isEmpty) {
      throw const NetbirdTunnelException('Setup Key 不能为空');
    }
    await _secureStorage.write(key: _secureSetupKey, value: value);
    _setupKeyPresent = true;
    notifyListeners();
  }

  Future<void> enable() async {
    _ensureSupported();
    if (_managementUrl.isEmpty) {
      throw const NetbirdTunnelException('请先填写 Management URL');
    }
    if (!_setupKeyPresent) {
      throw const NetbirdSetupKeyRequired();
    }
    _enabled = true;
    await _prefs.setBool(_keyEnabled, true);
    notifyListeners();
    await _start(restart: _nativeRunning);
  }

  Future<void> disable() async {
    _enabled = false;
    await _prefs.setBool(_keyEnabled, false);
    _stopPolling();
    await _invokeVoid('stop');
    _nativeRunning = false;
    _setSnapshot(const NetbirdTunnelSnapshot());
  }

  Future<void> retry() async {
    _ensureSupported();
    if (!_enabled) return;
    if (!_setupKeyPresent) {
      throw const NetbirdSetupKeyRequired();
    }
    await _start(restart: _nativeRunning);
  }

  Future<void> clearLogin() async {
    _ensureSupported();
    _enabled = false;
    await _prefs.setBool(_keyEnabled, false);
    _stopPolling();
    try {
      await _invokeVoid('clearLogin');
    } finally {
      await _secureStorage.delete(key: _secureSetupKey);
      _setupKeyPresent = false;
      _nativeRunning = false;
      _setSnapshot(const NetbirdTunnelSnapshot());
    }
  }

  Future<void> handleAppResumed() async {
    if (!_enabled || !_supported) return;
    if (_snapshot.isConnected) {
      await _readStatus();
      return;
    }
    if (_setupKeyPresent) {
      try {
        await retry();
      } catch (error) {
        logger.warning('[netbird] resume reconnect failed: $error');
      }
    }
  }

  Future<void> _start({bool restart = false}) async {
    final running = _startFuture;
    if (running != null) {
      await running;
      return;
    }
    final future = _startOnce(restart: restart);
    _startFuture = future;
    try {
      await future;
    } finally {
      if (identical(_startFuture, future)) {
        _startFuture = null;
      }
    }
  }

  Future<void> _startOnce({required bool restart}) async {
    _ensureSupported();
    final setupKey = await _readSetupKey();
    if (setupKey == null || setupKey.isEmpty) {
      _setupKeyPresent = false;
      _setSnapshot(
        const NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.error,
          error: '缺少 Setup Key，请重新输入',
        ),
      );
      throw const NetbirdSetupKeyRequired();
    }
    _setupKeyPresent = true;
    if (_managementUrl.isEmpty) {
      _setSnapshot(
        const NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.error,
          error: '请先填写 Management URL',
        ),
      );
      throw const NetbirdTunnelException('请先填写 Management URL');
    }

    if (restart) {
      await _invokeVoid('stop');
      _nativeRunning = false;
    }

    _setSnapshot(
      _snapshot.copyWith(
        state: NetbirdTunnelState.starting,
        clearError: true,
        proxyPort: 0,
      ),
    );
    _stopPolling();
    try {
      await _channel.invokeMethod<void>('start', {
        'managementUrl': _managementUrl,
        'setupKey': setupKey,
        'deviceName': _deviceName,
      });
      _nativeRunning = true;
      await _readStatus();
      _startPolling();
    } on PlatformException catch (error) {
      _nativeRunning = false;
      _setSnapshot(
        NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.error,
          error: error.message ?? 'Netbird 连接失败',
        ),
      );
      rethrow;
    } catch (error) {
      _nativeRunning = false;
      _setSnapshot(
        NetbirdTunnelSnapshot(
          state: NetbirdTunnelState.error,
          error: '$error',
        ),
      );
      rethrow;
    }
  }

  void _startPolling() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_readStatus());
    });
  }

  void _stopPolling() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  Future<void> _readStatus() async {
    if (!_supported || !_nativeRunning) return;
    try {
      final raw = await _channel.invokeMethod<String>('status');
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final state = switch (decoded['state']) {
        'connected' => NetbirdTunnelState.connected,
        'connecting' => NetbirdTunnelState.connecting,
        'starting' => NetbirdTunnelState.starting,
        'error' => NetbirdTunnelState.error,
        _ => NetbirdTunnelState.disabled,
      };
      final proxyPort =
          (decoded['proxyPort'] as num?)?.toInt() ?? 0;
      final effectiveState =
          state == NetbirdTunnelState.connected &&
              (proxyPort <= 0 ||
                  !(decoded['managementConnected'] as bool? ?? false) ||
                  !(decoded['signalConnected'] as bool? ?? false))
          ? NetbirdTunnelState.connecting
          : state;
      final error = decoded['error'] as String?;
      _setSnapshot(
        NetbirdTunnelSnapshot(
          state: effectiveState,
          error: error == null || error.isEmpty ? null : error,
          proxyPort: proxyPort,
          managementConnected:
              decoded['managementConnected'] as bool? ?? false,
          signalConnected:
              decoded['signalConnected'] as bool? ?? false,
          peerCount: (decoded['peerCount'] as num?)?.toInt() ?? 0,
          connectedPeers:
              (decoded['connectedPeers'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (error) {
      logger.warning('[netbird] status failed: $error');
    }
  }

  Future<void> waitUntilConnected({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_enabled) return;
    _ensureSupported();
    final running = _startFuture;
    if (running != null) {
      try {
        await running;
      } catch (_) {
        // The snapshot below carries the user-facing error.
      }
    }
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isConnected) return;
      if (_snapshot.state == NetbirdTunnelState.error) {
        throw NetbirdTunnelException(
          _snapshot.error ?? 'Netbird 连接失败',
        );
      }
      await _readStatus();
      if (isConnected) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const NetbirdTunnelException('Netbird 连接超时');
  }

  bool shouldUseForUrl(String url) {
    if (!_enabled || !_supported) return false;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return false;
    if (isLocalProxyUrl(url)) return false;
    return !_isLoopbackHost(uri.host);
  }

  bool shouldUseForMachine({required bool hasSshJumpHost}) =>
      _enabled && _supported && !hasSshJumpHost;

  bool isLocalProxyUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.host == '127.0.0.1' &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments.first == 't';
  }

  Future<String> localizeWsUrl(String url) async {
    if (!shouldUseForUrl(url)) return url;
    await waitUntilConnected();
    final localized = _localizeWsUrlSync(url);
    if (localized == null) {
      throw const NetbirdTunnelException('Netbird 隧道未连接');
    }
    return localized;
  }

  Future<String> localizeHttpBaseUrl(String url) async {
    if (!shouldUseForUrl(url)) return url;
    await waitUntilConnected();
    final localized = _localizeHttpBaseUrlSync(url);
    if (localized == null) {
      throw const NetbirdTunnelException('Netbird 隧道未连接');
    }
    return localized;
  }

  String? localizeWsUrlSync(String url) {
    if (!shouldUseForUrl(url)) return url;
    return _localizeWsUrlSync(url);
  }

  String? localizeHttpBaseUrlSync(String url) {
    if (!shouldUseForUrl(url)) return url;
    return _localizeHttpBaseUrlSync(url);
  }

  String? _localizeWsUrlSync(String url) {
    if (!isConnected) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    return _localUri(uri, webSocket: true)?.toString();
  }

  String? _localizeHttpBaseUrlSync(String url) {
    if (!isConnected) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    return _localUri(uri, webSocket: false)?.toString();
  }

  Uri? _localUri(Uri original, {required bool webSocket}) {
    final upstreamScheme = switch (original.scheme) {
      'ws' || 'http' => 'http',
      'wss' || 'https' => 'https',
      _ => null,
    };
    if (upstreamScheme == null || original.host.isEmpty) return null;
    final port = original.hasPort
        ? original.port
        : (upstreamScheme == 'https' ? 443 : 80);
    final targetOrigin = Uri(
      scheme: upstreamScheme,
      host: original.host,
      port: port,
    ).toString();
    final token = base64Url
        .encode(utf8.encode(targetOrigin))
        .replaceAll('=', '');
    return original.replace(
      scheme: webSocket ? 'ws' : 'http',
      host: '127.0.0.1',
      port: _snapshot.proxyPort,
      path: '/t/$token${original.path}',
    );
  }

  /// Decodes the original HTTP origin from a loopback proxy URL.
  static Uri? originalOriginOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host != '127.0.0.1' ||
        uri.pathSegments.length < 2 ||
        uri.pathSegments.first != 't') {
      return null;
    }
    try {
      final token = uri.pathSegments[1];
      final padded = token.padRight(
        token.length + ((4 - token.length % 4) % 4),
        '=',
      );
      final decoded = utf8.decode(base64Url.decode(padded));
      return Uri.tryParse(decoded);
    } catch (_) {
      return null;
    }
  }

  /// Reconstructs the original URL from a loopback proxy URL.
  static String? originalUrlOf(String url) {
    final uri = Uri.tryParse(url);
    final origin = originalOriginOf(url);
    if (uri == null || origin == null) return null;
    final token = uri.pathSegments[1];
    final prefix = '/t/$token';
    final remainder = uri.path.startsWith(prefix)
        ? uri.path.substring(prefix.length)
        : '';
    final scheme = switch (uri.scheme) {
      'ws' || 'wss' => origin.scheme == 'https' ? 'wss' : 'ws',
      _ => origin.scheme,
    };
    return uri
        .replace(
          scheme: scheme,
          host: origin.host,
          port: origin.hasPort ? origin.port : null,
          path: remainder,
        )
        .toString();
  }

  Future<String?> _readSetupKey() async {
    try {
      return await _secureStorage.read(key: _secureSetupKey);
    } catch (error) {
      logger.warning('[netbird] read setup key failed: $error');
      return null;
    }
  }

  Future<void> _invokeVoid(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      if (_supported) rethrow;
    }
  }

  void _ensureSupported() {
    if (!_supported) {
      throw const NetbirdTunnelException('Netbird 仅支持 Android');
    }
  }

  void _setSnapshot(NetbirdTunnelSnapshot snapshot) {
    _snapshot = snapshot;
    notifyListeners();
  }

  static String _normalizeManagementUrl(String value) {
    var url = value.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static bool _isLoopbackHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized == '[::1]' ||
        normalized.startsWith('127.');
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }
}
