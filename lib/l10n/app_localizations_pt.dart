// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class AppLocalizationsPt extends AppLocalizations {
  AppLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get tagline => 'TOQUE NO RITMO';

  @override
  String get addSong => 'ADICIONAR MÚSICA';

  @override
  String get songName => 'Nome da música';

  @override
  String get songNameHint => 'Digite o título da música';

  @override
  String get chooseAudio => 'Escolher áudio';

  @override
  String get cancel => 'CANCELAR';

  @override
  String get add => 'ADICIONAR';

  @override
  String get addYourSong => 'Adicionar arquivo local';

  @override
  String get howToPlay => 'Como jogar';

  @override
  String get noSongsYet => 'NENHUMA MÚSICA';

  @override
  String get noSongsHint => 'Adicione seus arquivos de áudio para começar!';

  @override
  String bestScoreShort(int score) {
    return 'RECORDE: $score';
  }

  @override
  String get customArtist => 'Arquivo local';

  @override
  String get settingsTitle => 'CONFIGURAÇÕES';

  @override
  String get hapticsSection => 'VIBRAÇÃO';

  @override
  String get hapticFeedback => 'Vibrar ao tocar';

  @override
  String get themeSection => 'TEMA';

  @override
  String get languageSection => 'IDIOMA';

  @override
  String get systemDefault => 'Idioma do aparelho';

  @override
  String get langEnglish => 'English';

  @override
  String get langItalian => 'Italiano';

  @override
  String get resetHighScores => 'ZERAR RECORDES';

  @override
  String get resetScoresTitle => 'Zerar recordes?';

  @override
  String get resetScoresMessage =>
      'Deseja apagar todos os recordes e estrelas salvos?';

  @override
  String get reset => 'ZERAR';

  @override
  String get themeNameClean => 'Claro';

  @override
  String get themeNameDark => 'Escuro';

  @override
  String get themeNameAmoled => 'Escuro AMOLED';

  @override
  String get themeNameForest => 'Floresta';

  @override
  String get themeNameOcean => 'Oceano';

  @override
  String get themeNameSunset => 'Pôr do sol';

  @override
  String get paused => 'PAUSADO';

  @override
  String get resume => 'CONTINUAR';

  @override
  String get home => 'BIBLIOTECA';

  @override
  String get songCompleted => 'MÚSICA CONCLUÍDA!';

  @override
  String get outOfRhythm => 'FORA DO RITMO!';

  @override
  String get score => 'Pontos';

  @override
  String get bestScore => 'Recorde';

  @override
  String get playAgain => 'JOGAR NOVAMENTE';

  @override
  String get tryAgain => 'TENTAR NOVAMENTE';

  @override
  String get start => 'COMEÇAR';

  @override
  String get qualityPerfect => 'PERFEITO!';

  @override
  String get qualityGreat => 'ÓTIMO!';

  @override
  String get qualityGood => 'BOM';

  @override
  String get qualityMiss => 'ERRO!';

  @override
  String comboLabel(int combo) {
    return 'COMBO ${combo}x';
  }

  @override
  String get howToPlayTitle => 'COMO JOGAR';

  @override
  String get singleTapTitle => 'PEÇAS SIMPLES';

  @override
  String get singleTapSubtitle =>
      'Toque em cada peça quando ela chegar à linha inferior.';

  @override
  String get singleTapPoint1 =>
      'Toque quando a peça chegar à linha de julgamento.';

  @override
  String get singleTapPoint2 =>
      'Quanto mais perto do centro, maior a chance de um PERFEITO!';

  @override
  String get singleTapPoint3 => 'Um toque acerta a peça imediatamente.';

  @override
  String get holdTilesTitle => 'PEÇAS LONGAS';

  @override
  String get holdTilesSubtitle =>
      'São marcadas por um círculo e uma linha reta.';

  @override
  String get holdTilesPoint1 =>
      'Toque no círculo ao chegar à linha e continue segurando.';

  @override
  String get holdTilesPoint2 =>
      'Segurar acumula pontos extras e aumenta o combo.';

  @override
  String get holdTilesPoint3 =>
      'Soltar antes não encerra a partida: um toque já vale como acerto!';

  @override
  String get avoidMistakesTitle => 'EVITE ERROS';

  @override
  String get avoidMistakesSubtitle => 'Mantenha a sequência da música.';

  @override
  String get avoidMistakesPoint1 =>
      'Não toque em uma coluna vazia sem uma peça passando.';

  @override
  String get avoidMistakesPoint2 =>
      'Não deixe uma peça passar pelo fim da tela sem tocar nela.';

  @override
  String get avoidMistakesPoint3 =>
      'Use vários dedos para músicas rápidas e peças duplas.';

  @override
  String get judgmentLine => 'LINHA DE JULGAMENTO';

  @override
  String get tap => 'TOQUE';

  @override
  String get chargingCombo => 'ACUMULANDO COMBO';

  @override
  String get missTriggerTitle => 'FIM DA PARTIDA';

  @override
  String get missTriggerText =>
      'Tocar em um espaço vazio ou deixar uma peça passar encerra a partida imediatamente.';

  @override
  String get gotItLetsPlay => 'ENTENDI, VAMOS JOGAR!';
}
