import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_theme.dart';
import '../models/game_models.dart';
import '../models/youtube_models.dart';
import '../services/import_api.dart';
import '../services/storage_service.dart';
import 'game_screen.dart';
import 'server_settings_screen.dart';
import 'track_subtitle.dart';

class YoutubeImportScreen extends StatefulWidget {
  final AppThemeData appTheme;
  final ImportApi Function(String)? createApi;
  const YoutubeImportScreen({
    super.key,
    required this.appTheme,
    this.createApi,
  });
  @override
  State<YoutubeImportScreen> createState() => _YoutubeImportScreenState();
}

class _YoutubeImportScreenState extends State<YoutubeImportScreen>
    with WidgetsBindingObserver {
  final _url = TextEditingController();
  ImportApi? _api;
  List<ImportJob> _jobs = [];
  List<YoutubeTrack> _tracks = [];
  Timer? _poll;
  bool _active = true;
  bool _resumed = true;
  ImportApi? _refreshingApi;
  bool _submitting = false;
  bool _loading = false;
  String? _error;
  YoutubeLink? _link;
  ImportKind _kind = ImportKind.auto;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _connect();
  }

  void _connect() {
    _poll?.cancel();
    _api?.close();
    _api = null;
    final server = StorageService.getServerUrl();
    if (server.isEmpty) {
      _api = null;
      return;
    }
    try {
      _api = widget.createApi?.call(server) ?? ImportApi(server);
      _loading = true;
      _refresh();
    } on FormatException {
      _error = 'Configure um endereço válido para o servidor.';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _poll?.cancel();
    if (_resumed && _active) _refresh();
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_active && _resumed && _jobs.any((j) => !j.isFinished)) {
      _poll = Timer(const Duration(seconds: 2), _refresh);
    }
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null ||
        !_active ||
        !_resumed ||
        _refreshingApi == api ||
        !mounted) {
      return;
    }
    _refreshingApi = api;
    try {
      final result = await Future.wait<Object>([
        api.listImports(),
        api.listTracks(),
      ]);
      if (!mounted || api != _api) return;
      final jobs = result[0] as List<ImportJob>;
      final tracks = result[1] as List<YoutubeTrack>;
      await StorageService.mergeYoutubeTracks(tracks, api.origin.toString());
      if (!mounted || api != _api) return;
      setState(() {
        _jobs = jobs;
        _tracks = tracks;
        _error = null;
      });
    } on ImportApiException catch (error) {
      if (mounted && api == _api) setState(() => _error = error.message);
    } catch (_) {
      if (mounted && api == _api) {
        setState(
          () => _error = 'Não foi possível atualizar a biblioteca no aparelho. Tente novamente.',
        );
      }
    } finally {
      if (_refreshingApi == api) _refreshingApi = null;
      if (mounted && api == _api) {
        setState(() => _loading = false);
        _schedulePoll();
      }
    }
  }

  Future<void> _configure() async {
    _active = false;
    _poll?.cancel();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerSettingsScreen(appTheme: widget.appTheme),
      ),
    );
    if (!mounted) return;
    _active = true;
    setState(() {
      _jobs = [];
      _tracks = [];
      _error = null;
    });
    _connect();
    setState(() {});
  }

  Future<void> _submit() async {
    final api = _api;
    if (api == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final job = await api.createImport(_url.text, kind: _kind);
      if (!mounted || api != _api) return;
      setState(() {
        _jobs = [job, ..._jobs.where((j) => j.id != job.id)];
      });
      await _refresh();
      _schedulePoll();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
    } on ImportApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _play(YoutubeTrack track) async {
    final api = _api;
    if (api == null || !_active) return;
    _active = false;
    _poll?.cancel();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GameScreen(
          song: SongItem.youtube(track, api.origin.toString()),
          appTheme: widget.appTheme,
        ),
      ),
    );
    if (!mounted) return;
    _active = true;
    _refresh();
  }

  @override
  void dispose() {
    _active = false;
    _poll?.cancel();
    _api?.close();
    _url.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  String _status(String value) => switch (value) {
    'queued' => 'Na fila',
    'resolving' => 'Lendo a lista',
    'running' => 'Importando',
    'completed' => 'Concluída',
    'partial' => 'Concluída com falhas',
    'failed' => 'Falhou',
    'downloading' => 'Baixando áudio',
    'preparing_audio' => 'Preparando áudio',
    'analyzing' => 'Detectando batidas e ataques',
    'ready' => 'Pronta',
    _ => value,
  };

  @override
  Widget build(BuildContext context) {
    final theme = widget.appTheme;
    return Scaffold(
      backgroundColor: theme.background,
      appBar: AppBar(
        title: const Text('Importar do YouTube'),
        actions: [
          IconButton(
            onPressed: _configure,
            tooltip: 'Configurar servidor',
            icon: const Icon(Icons.dns_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(20),
            children: [
              if (_api == null) ...[
                const Text(
                  'Configure o servidor para importar músicas e playlists.',
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _configure,
                  child: const Text('Configurar servidor'),
                ),
              ] else ...[
                Text(
                  'Toque a gravação original',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Cole um vídeo ou uma playlist. O servidor prepara o áudio e as peças a partir das batidas e dos ataques.',
                  style: TextStyle(color: theme.textMuted),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _url,
                  enabled: !_submitting,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Link do YouTube',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    YoutubeLink? parsed;
                    try {
                      parsed = YoutubeLink.parse(value);
                    } on FormatException {
                      /* Validate on submit. */
                    }
                    setState(() {
                      _link = parsed;
                      _kind = parsed?.suggestedKind ?? ImportKind.auto;
                    });
                  },
                ),
                if (_link?.needsChoice ?? false) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Este link contém um vídeo e uma playlist. Escolha o que importar:',
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ImportKind>(
                    segments: const [
                      ButtonSegment(
                        value: ImportKind.video,
                        label: Text('Só este vídeo'),
                      ),
                      ButtonSegment(
                        value: ImportKind.playlist,
                        label: Text('Playlist inteira'),
                      ),
                    ],
                    selected: {_kind},
                    onSelectionChanged: _submitting
                        ? null
                        : (value) => setState(() => _kind = value.single),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_link_rounded),
                  label: Text(_submitting ? 'Enviando…' : 'Importar'),
                ),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_error!, style: TextStyle(color: theme.textPrimary)),
                      if (_api != null)
                        TextButton(
                          onPressed: _refresh,
                          child: const Text('Tentar atualizar novamente'),
                        ),
                    ],
                  ),
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_jobs.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Fila de importação',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                for (final job in _jobs)
                  Card(
                    color: theme.cardBg,
                    margin: const EdgeInsets.only(top: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _status(job.status),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          Text(
                            '${job.readyItems} pronta(s) · ${job.failedItems} falha(s)'
                            '${job.totalItems == null ? '' : ' · ${job.totalItems} no total'}',
                          ),
                          if (job.error != null) Text(job.error!.message),
                          for (final item in job.items)
                            Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.title ?? 'Faixa ${item.index + 1}'),
                                  Text(
                                    item.error?.message ?? _status(item.status),
                                    style: TextStyle(color: theme.textMuted),
                                  ),
                                  if (item.status != 'ready' &&
                                      item.status != 'failed')
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: LinearProgressIndicator(
                                        value: item.progress,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (_tracks.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  'Prontas para jogar',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'As faixas prontas já aparecem na sua biblioteca. O áudio será verificado no aparelho antes de começar.',
                  style: TextStyle(color: theme.textMuted),
                ),
                for (final track in _tracks)
                  Card(
                    color: theme.cardBg,
                    child: ListTile(
                      title: Text(track.title),
                      subtitle: Text(trackSubtitle(track)),
                      trailing: const Icon(Icons.play_arrow_rounded),
                      onTap: () => _play(track),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
