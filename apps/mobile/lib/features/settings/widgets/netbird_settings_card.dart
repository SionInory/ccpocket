import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/netbird_tunnel_service.dart';
import 'settings_tiles.dart';

typedef _NetbirdConfig = ({
  String managementUrl,
  String deviceName,
  String? setupKey,
});

class NetbirdSettingsCard extends StatelessWidget {
  const NetbirdSettingsCard({super.key, required this.service});

  final NetbirdTunnelService service;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final l = AppLocalizations.of(context);
        final cs = Theme.of(context).colorScheme;
        final snapshot = service.snapshot;
        final enabled = service.isEnabled;
        final hasConfiguration = service.managementUrl.isNotEmpty;
        final error = snapshot.error;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              key: const ValueKey('netbird_enabled_switch'),
              secondary: const SettingsLeadingIcon(Icons.vpn_lock_rounded),
              title: Text(l.netbirdTitle),
              subtitle: Text(_statusLabel(l, snapshot, enabled)),
              value: enabled,
              onChanged: (value) {
                unawaited(_setEnabled(context, enabled: value));
              },
            ),
            if (enabled || hasConfiguration)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hasConfiguration)
                      Row(
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 16,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              service.managementUrl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    if (snapshot.isConnected && snapshot.peerCount > 0) ...[
                      if (hasConfiguration) const SizedBox(height: 6),
                      Text(
                        l.netbirdPeerSummary(
                          snapshot.connectedPeers,
                          snapshot.peerCount,
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (error != null && error.isNotEmpty) ...[
                      if (hasConfiguration) const SizedBox(height: 6),
                      Text(
                        error,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: cs.error),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (enabled &&
                            !snapshot.isConnected &&
                            hasConfiguration &&
                            service.hasSetupKey)
                          FilledButton.tonalIcon(
                            key: const ValueKey('netbird_retry_button'),
                            onPressed: () {
                              unawaited(_retry(context));
                            },
                            icon: const Icon(Icons.refresh, size: 18),
                            label: Text(l.netbirdRetry),
                          ),
                        OutlinedButton.icon(
                          key: const ValueKey('netbird_edit_button'),
                          onPressed: () {
                            unawaited(_editConfiguration(context));
                          },
                          icon: const Icon(Icons.tune, size: 18),
                          label: Text(l.netbirdEditConfig),
                        ),
                        if (hasConfiguration && service.hasSetupKey)
                          TextButton.icon(
                            key: const ValueKey('netbird_clear_login_button'),
                            onPressed: () {
                              unawaited(_clearLogin(context));
                            },
                            icon: const Icon(Icons.logout, size: 18),
                            label: Text(l.netbirdClearLogin),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  String _statusLabel(
    AppLocalizations l,
    NetbirdTunnelSnapshot snapshot,
    bool enabled,
  ) {
    if (!enabled) return l.netbirdStatusDisabled;
    return switch (snapshot.state) {
      NetbirdTunnelState.connected => l.netbirdStatusConnected,
      NetbirdTunnelState.starting ||
      NetbirdTunnelState.connecting ||
      NetbirdTunnelState.disabled => l.netbirdStatusStarting,
      NetbirdTunnelState.error => l.netbirdStatusError,
      NetbirdTunnelState.unsupported => l.netbirdStatusUnsupported,
    };
  }

  Future<void> _setEnabled(
    BuildContext context, {
    required bool enabled,
  }) async {
    if (!enabled) {
      try {
        await service.disable();
      } catch (error) {
        _showError(context, error);
      }
      return;
    }

    final l = AppLocalizations.of(context);
    if (service.managementUrl.isEmpty || !service.hasSetupKey) {
      final saved = await _configure(
        context,
        requireSetupKey: !service.hasSetupKey,
        submitLabel: l.netbirdSaveAndEnable,
      );
      if (!saved || !context.mounted) return;
    }
    try {
      await service.enable();
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<void> _editConfiguration(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final saved = await _configure(
      context,
      requireSetupKey: !service.hasSetupKey,
      submitLabel: l.save,
    );
    if (!saved || !context.mounted || !service.isEnabled) return;
    try {
      await service.enable();
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<bool> _configure(
    BuildContext context, {
    required bool requireSetupKey,
    required String submitLabel,
  }) async {
    final values = await showDialog<_NetbirdConfig>(
      context: context,
      builder: (_) => _NetbirdConfigDialog(
        service: service,
        requireSetupKey: requireSetupKey,
        submitLabel: submitLabel,
      ),
    );
    if (values == null || !context.mounted) return false;
    try {
      await service.saveConfiguration(
        managementUrl: values.managementUrl,
        deviceName: values.deviceName,
      );
      final setupKey = values.setupKey;
      if (setupKey != null && setupKey.isNotEmpty) {
        await service.saveSetupKey(setupKey);
      }
      if (context.mounted) {
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.netbirdConfigSaved)));
      }
      return true;
    } catch (error) {
      _showError(context, error);
      return false;
    }
  }

  Future<void> _retry(BuildContext context) async {
    try {
      await service.retry();
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<void> _clearLogin(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.netbirdClearLoginTitle),
        content: Text(l.netbirdClearLoginBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.netbirdClearLogin),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await service.clearLogin();
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.netbirdCleared)));
    } catch (error) {
      _showError(context, error);
    }
  }

  void _showError(BuildContext context, Object error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

class _NetbirdConfigDialog extends StatefulWidget {
  const _NetbirdConfigDialog({
    required this.service,
    required this.requireSetupKey,
    required this.submitLabel,
  });

  final NetbirdTunnelService service;
  final bool requireSetupKey;
  final String submitLabel;

  @override
  State<_NetbirdConfigDialog> createState() => _NetbirdConfigDialogState();
}

class _NetbirdConfigDialogState extends State<_NetbirdConfigDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _managementController;
  late final TextEditingController _deviceController;
  final _setupKeyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _managementController = TextEditingController(
      text: widget.service.managementUrl,
    );
    _deviceController = TextEditingController(
      text: widget.service.deviceName,
    );
  }

  @override
  void dispose() {
    _managementController.dispose();
    _deviceController.dispose();
    _setupKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.netbirdSetupTitle),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.netbirdSetupDescription),
                const SizedBox(height: 16),
                TextFormField(
                  key: const ValueKey('netbird_management_url_field'),
                  controller: _managementController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l.netbirdManagementUrl,
                    hintText: l.netbirdManagementUrlHint,
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? l.netbirdManagementUrlRequired
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('netbird_setup_key_field'),
                  controller: _setupKeyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l.netbirdSetupKey,
                    hintText: widget.service.hasSetupKey
                        ? l.netbirdSetupKeyKeepHint
                        : null,
                  ),
                  validator: (value) =>
                      widget.requireSetupKey &&
                          (value == null || value.trim().isEmpty)
                      ? l.netbirdSetupKeyRequired
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('netbird_device_name_field'),
                  controller: _deviceController,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: l.netbirdDeviceName,
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? l.netbirdDeviceNameRequired
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('netbird_config_save_button'),
          onPressed: _submit,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    final setupKey = _setupKeyController.text.trim();
    Navigator.pop<_NetbirdConfig>(context, (
      managementUrl: _managementController.text.trim(),
      deviceName: _deviceController.text.trim(),
      setupKey: setupKey.isEmpty ? null : setupKey,
    ));
  }
}
