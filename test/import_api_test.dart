import 'dart:convert';

import 'package:echotiles/models/youtube_models.dart';
import 'package:echotiles/services/import_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const mixed = 'https://www.youtube.com/watch?v=BaW_jenozKc&list=PLdemo';

  test(
    'a mixed link offers video or playlist and sends the explicit choice',
    () async {
      final link = YoutubeLink.parse(mixed);
      expect(link.needsChoice, isTrue);
      expect(link.suggestedKind, ImportKind.video);
      for (final kind in [ImportKind.video, ImportKind.playlist]) {
        final api = ImportApi(
          'http://192.168.1.2:8000',
          client: MockClient((request) async {
            expect(request.url.path, '/api/imports');
            expect(request.method, 'POST');
            expect(jsonDecode(request.body), {'url': mixed, 'kind': kind.name});
            return http.Response(jsonEncode(jobJson()), 202);
          }),
        );
        final job = await api.createImport(mixed, kind: kind);
        expect(job.status, 'queued');
        expect(job.totalItems, isNull);
      }
    },
  );

  test('accepts video, short and playlist links and rejects other sources', () {
    expect(
      YoutubeLink.parse('https://youtu.be/BaW_jenozKc').suggestedKind,
      ImportKind.video,
    );
    expect(
      YoutubeLink.parse('https://youtube.com/playlist?list=PLdemo')
          .suggestedKind,
      ImportKind.playlist,
    );
    for (final url in [
      'https://evil.test/watch?v=x',
      'file:///audio.mp3',
      'https://youtube.com/',
      'text',
    ]) {
      expect(() => YoutubeLink.parse(url), throwsFormatException);
    }
  });

  test(
    'network errors and server errors have usable Portuguese messages',
    () async {
      final offline = ImportApi(
        'http://server:8000',
        client: MockClient((_) async {
          throw http.ClientException('SECRET upstream https://cdn.test/token');
        }),
      );
      await expectLater(
        offline.health(),
        throwsA(
          isA<ImportApiException>()
              .having((e) => e.code, 'code', 'network')
              .having((e) => e.message, 'message', isNot(contains('SECRET'))),
        ),
      );
      final failed = ImportApi(
        'http://server:8000',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'error': {
                'code': 'access_required',
                'message': 'A faixa exige acesso.',
                'retryable': false,
              },
            }),
            403,
          ),
        ),
      );
      await expectLater(
        failed.createImport(mixed),
        throwsA(
          isA<ImportApiException>().having(
            (e) => e.message,
            'message',
            'A faixa exige acesso.',
          ),
        ),
      );
    },
  );

  test(
    'checks schema at connection test and preserves partial item failures',
    () async {
      final api = ImportApi(
        'http://server:8000',
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(
              request.url.path == '/api/health'
                  ? {'status': 'ok', 'schemaVersion': 2}
                  : {
                      'imports': [
                        {
                          ...jobJson(),
                          'status': 'partial',
                          'failedItems': 1,
                          'items': [
                            {
                              'id': 'item_a',
                              'index': 0,
                              'videoId': null,
                              'title': null,
                              'status': 'failed',
                              'progress': null,
                              'trackId': null,
                              'error': {
                                'code': 'unavailable',
                                'message': 'A faixa está indisponível.',
                                'retryable': false,
                              },
                            },
                          ],
                        },
                      ],
                    },
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      await expectLater(api.health(), throwsA(isA<ImportApiException>()));
      final jobs = await api.listImports();
      expect(
        jobs.single.items.single.error?.message,
        'A faixa está indisponível.',
      );
      expect(jobs.single.isFinished, isTrue);
    },
  );
}

Map<String, dynamic> jobJson() => {
  'id': 'imp_a',
  'sourceUrl': 'https://youtube.com/watch?v=BaW_jenozKc',
  'sourceKind': 'video',
  'status': 'queued',
  'createdAt': '2026-11-25T00:00:00Z',
  'totalItems': null,
  'readyItems': 0,
  'failedItems': 0,
  'error': null,
  'items': [],
};
