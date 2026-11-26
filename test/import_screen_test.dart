import 'dart:convert';

import 'package:echotiles/models/app_theme.dart';
import 'package:echotiles/screens/youtube_import_screen.dart';
import 'package:echotiles/services/import_api.dart';
import 'package:echotiles/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'import_api_test.dart' show jobJson;

void main() {
  testWidgets(
    'polls active jobs only while the import screen is visible and resumed',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'youtube_server': 'http://server:8000',
      });
      await StorageService.init();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: YoutubeImportScreen(
            appTheme: AppThemes.fromName('amoled'),
            createApi: (url) => ImportApi(
              url,
              client: MockClient((request) async {
                requests++;
                return http.Response(
                  jsonEncode(
                    request.url.path == '/api/imports'
                        ? {
                            'imports': [jobJson()],
                          }
                        : {'tracks': []},
                  ),
                  200,
                );
              }),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      final initial = requests;
      expect(
        find.text('Fila de importação'),
        findsOneWidget,
        reason:
            'requests=$requests lifecycle=${tester.binding.lifecycleState}; '
            '${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).join(' | ')}',
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
      expect(requests, greaterThan(initial));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final beforeBackground = requests;
      await tester.pump(const Duration(seconds: 10));
      expect(requests, beforeBackground);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(requests, greaterThan(beforeBackground));
      await tester.pumpWidget(const SizedBox());
      final beforeLeaving = requests;
      await tester.pump(const Duration(seconds: 10));
      expect(requests, beforeLeaving);
    },
  );
}
