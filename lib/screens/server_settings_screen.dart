import 'package:flutter/material.dart';

import '../models/app_theme.dart';
import '../services/import_api.dart';
import '../services/storage_service.dart';

class ServerSettingsScreen extends StatefulWidget {
  final AppThemeData appTheme;
  const ServerSettingsScreen({super.key, required this.appTheme});

  @override
  State<ServerSettingsScreen> createState() => _ServerSettingsScreenState();
}

class _ServerSettingsScreenState extends State<ServerSettingsScreen> {
  late final TextEditingController _address;
  bool _busy = false;
  String? _message;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _address = TextEditingController(text: StorageService.getServerUrl());
  }

  Future<void> _testAndSave() async {
    setState(() {
      _busy = true;
      _message = null;
      _connected = false;
    });
    ImportApi? api;
    try {
      api = ImportApi(_address.text);
      await api.health();
      await StorageService.setServerUrl(api.origin.toString());
      if (mounted) {
        setState(() {
          _connected = true;
          _message = 'Conexão confirmada. Endereço salvo.';
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _message = error.message.toString());
    } on ImportApiException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } finally {
      api?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.appTheme;
    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(title: const Text('Servidor de músicas')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Conecte ao servidor na sua rede',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Use o endereço do servidor Umbrel, incluindo a porta. O celular precisa conseguir acessá-lo.',
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _address,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Endereço do servidor',
                hintText: 'http://192.168.1.2:8000',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) {
                if (!_busy) _testAndSave();
              },
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _testAndSave,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_rounded),
              label: Text(_busy ? 'Conectando…' : 'Testar conexão e salvar'),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(
                  _message!,
                  style: TextStyle(
                    color: _connected ? theme.playBg : theme.textPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
