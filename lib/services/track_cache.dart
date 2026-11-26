import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/beatmap.dart';
import '../models/youtube_models.dart';
import 'import_api.dart';

class PreparedTrack {
  final File audioFile;
  final Beatmap chart;
  const PreparedTrack(this.audioFile, this.chart);
}

/// Only verified media is published. Staging and eviction share one serial queue.
class TrackCache {
  static const defaultMaxBytes = 256 * 1024 * 1024;
  static Future<TrackCache>? _applicationCache;

  final Directory root;
  final http.Client _client;
  final int maxBytes;
  Future<void> _tail = Future.value();

  TrackCache(this.root, {http.Client? client, this.maxBytes = defaultMaxBytes})
    : _client = client ?? http.Client();

  static Future<TrackCache> forApp() => _applicationCache ??= () async {
    final directory = await getApplicationCacheDirectory();
    return TrackCache(Directory('${directory.path}/youtube-v1'));
  }();

  Future<PreparedTrack> prepare(YoutubeTrack track, String server) {
    final operation = _tail.then((_) => _prepare(track, server));
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<List<File>> _files() async {
    if (!await root.exists()) return [];
    return root
        .list(followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
  }

  Future<int> sizeBytes() async {
    var total = 0;
    for (final file in await _files()) {
      total += await file.length();
    }
    return total;
  }

  Future<bool> _validAudio(File audio, YoutubeTrack track) async {
    if (!await audio.exists() || await audio.length() != track.audioBytes) {
      return false;
    }
    return (await sha256.bind(audio.openRead()).first).toString() ==
        track.audioSha256;
  }

  Future<void> _makeRoom(int incoming, Set<String> protected) async {
    final files = (await _files())
        .where((f) => !protected.contains(f.path))
        .toList();
    final modified = <String, DateTime>{};
    for (final file in files) {
      modified[file.path] = await file.lastModified();
    }
    files.sort((a, b) => modified[a.path]!.compareTo(modified[b.path]!));
    var total = await sizeBytes();
    for (final file in files) {
      if (total + incoming <= maxBytes) break;
      if (!await file.exists()) continue;
      final name = file.uri.pathSegments.last;
      final group = name.length >= 64 ? name.substring(0, 64) : name;
      for (final victim in files.where(
        (f) => f.uri.pathSegments.last.startsWith(group),
      )) {
        if (await victim.exists()) {
          total -= await victim.length();
          await victim.delete();
        }
      }
    }
    if (total + incoming > maxBytes) {
      throw const ImportApiException(
        'disk_quota',
        'Esta faixa excede o cache de áudio disponível no aparelho.',
      );
    }
  }

  Future<PreparedTrack> _prepare(YoutubeTrack track, String server) async {
    if (track.audioBytes > maxBytes) {
      throw const ImportApiException(
        'disk_quota',
        'Esta faixa excede o limite de 256 MiB do aparelho.',
      );
    }
    await root.create(recursive: true);
    for (final file in await _files()) {
      if (file.path.endsWith('.part')) await file.delete();
    }
    final api = ImportApi(server, client: _client);
    final audio = File('${root.path}/${track.audioSha256}.m4a');
    final chartKey = sha256
        .convert(utf8.encode('${track.id}/${track.chartId}'))
        .toString();
    final chartFile = File('${root.path}/${track.audioSha256}-$chartKey.json');
    final audioReady = await _validAudio(audio, track);
    if (!audioReady && await audio.exists()) await audio.delete();

    Map<String, dynamic>? rawChart;
    Beatmap? chart;
    if (await chartFile.exists()) {
      try {
        if (await chartFile.length() > 16 * 1024 * 1024) {
          throw const FormatException();
        }
        rawChart =
            jsonDecode(await chartFile.readAsString()) as Map<String, dynamic>;
        chart = Beatmap.fromJson(rawChart, track: track);
      } catch (_) {
        await chartFile.delete();
        rawChart = null;
      }
    }
    rawChart ??= await api.chartJson(track);
    chart ??= Beatmap.fromJson(rawChart, track: track);
    final chartBytes = utf8.encode(jsonEncode(rawChart));
    final chartExists = await chartFile.exists();
    await _makeRoom(
      (audioReady ? 0 : track.audioBytes) +
          (chartExists ? 0 : chartBytes.length),
      {audio.path, chartFile.path},
    );

    final audioPart = File('${audio.path}.part');
    final chartPart = File('${chartFile.path}.part');
    try {
      if (!audioReady) {
        final request = http.Request('GET', api.mediaUri(track.audioUrl))
          ..followRedirects = false;
        final response = await _client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200 ||
            (response.contentLength != null &&
                response.contentLength != track.audioBytes)) {
          await response.stream.listen((_) {}).cancel();
          throw const ImportApiException(
            'download_failed',
            'O áudio recebido está incompleto. Tente baixar a faixa novamente.',
            retryable: true,
          );
        }
        final output = await audioPart.open(mode: FileMode.write);
        try {
          var received = 0;
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 30),
          )) {
            received += chunk.length;
            if (received > track.audioBytes) {
              throw const ImportApiException(
                'cache_integrity',
                'O tamanho do áudio não corresponde ao mapa.',
              );
            }
            await output.writeFrom(chunk);
          }
          await output.flush();
        } finally {
          await output.close();
        }
        if (!await _validAudio(audioPart, track)) {
          throw const ImportApiException(
            'cache_integrity',
            'O áudio não passou na verificação de integridade. Tente novamente.',
            retryable: true,
          );
        }
        await audioPart.rename(audio.path);
      }
      if (!chartExists) {
        await chartPart.writeAsBytes(chartBytes, flush: true);
        await chartPart.rename(chartFile.path);
      }
      final now = DateTime.now();
      await audio.setLastModified(now);
      await chartFile.setLastModified(now);
      return PreparedTrack(audio, chart);
    } on ImportApiException {
      rethrow;
    } catch (_) {
      throw const ImportApiException(
        'download_failed',
        'Não foi possível preparar o áudio local. Verifique a rede e o espaço disponível.',
        retryable: true,
      );
    } finally {
      for (final partial in [audioPart, chartPart]) {
        if (await partial.exists()) await partial.delete();
      }
    }
  }
}
