import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/beatmap.dart';
import '../models/youtube_models.dart';

class ImportApiException implements Exception {
  final String code;
  final String message;
  final bool retryable;
  const ImportApiException(this.code, this.message, {this.retryable = false});
  @override
  String toString() => message;
}

class ImportApi {
  final Uri origin;
  final http.Client _client;
  final Duration timeout;

  ImportApi(
    String baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : origin = parseOrigin(baseUrl),
       _client = client ?? http.Client();

  static Uri parseOrigin(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException(
        'Informe o endereço do servidor, como http://192.168.1.2:8000.',
      );
    }
    return uri.replace(path: '');
  }

  Uri mediaUri(String path) {
    final target = origin.resolve(path);
    if (target.origin != origin.origin) {
      throw const ImportApiException(
        'invalid_response',
        'O servidor retornou um endereço de mídia inválido.',
      );
    }
    return target;
  }

  Future<Map<String, dynamic>> _json(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    try {
      final request = http.Request(
        body == null ? 'GET' : 'POST',
        mediaUri(path),
      )..followRedirects = false;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      final response = await _client.send(request).timeout(timeout);
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(timeout)) {
        bytes.add(chunk);
        if (bytes.length > 16 * 1024 * 1024) {
          throw const ImportApiException(
            'invalid_response',
            'A resposta do servidor excedeu o limite.',
          );
        }
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final failure = ImportFailure.fromJson(error);
          throw ImportApiException(
            failure.code,
            failure.message,
            retryable: failure.retryable,
          );
        }
        throw const ImportApiException(
          'server',
          'O servidor não pôde concluir a solicitação.',
        );
      }
      return decoded;
    } on ImportApiException {
      rethrow;
    } on FormatException {
      throw const ImportApiException(
        'invalid_response',
        'O servidor enviou uma resposta inválida.',
      );
    } catch (_) {
      throw const ImportApiException(
        'network',
        'Não foi possível conectar ao servidor. Verifique o endereço e a rede.',
        retryable: true,
      );
    }
  }

  Future<T> _parse<T>(
    Future<Map<String, dynamic>> request,
    T Function(Map<String, dynamic>) parse,
  ) async {
    final json = await request;
    try {
      return parse(json);
    } catch (_) {
      throw const ImportApiException(
        'invalid_response',
        'O servidor enviou dados incompatíveis.',
      );
    }
  }

  Future<void> health() async {
    final json = await _json('/api/health');
    if (json['status'] != 'ok' ||
        json['schemaVersion'] is! int ||
        json['schemaVersion'] != 1) {
      throw const ImportApiException(
        'schema',
        'Este servidor não usa o contrato de importação versão 1.',
      );
    }
  }

  Future<ImportJob> createImport(
    String url, {
    ImportKind kind = ImportKind.auto,
  }) {
    YoutubeLink.parse(url);
    return _parse(
      _json('/api/imports', body: {'url': url.trim(), 'kind': kind.name}),
      ImportJob.fromJson,
    );
  }

  Future<List<ImportJob>> listImports() => _parse(
    _json('/api/imports'),
    (json) => (json['imports'] as List)
        .map((j) => ImportJob.fromJson(j as Map<String, dynamic>))
        .toList(),
  );

  Future<List<YoutubeTrack>> listTracks() => _parse(
    _json('/api/tracks'),
    (json) => (json['tracks'] as List)
        .map((j) => YoutubeTrack.fromJson(j as Map<String, dynamic>))
        .toList(),
  );

  Future<Map<String, dynamic>> chartJson(YoutubeTrack track) =>
      _json(track.chartUrl);

  Future<Beatmap> chart(YoutubeTrack track) =>
      _parse(chartJson(track), (json) => Beatmap.fromJson(json, track: track));

  void close() => _client.close();
}
