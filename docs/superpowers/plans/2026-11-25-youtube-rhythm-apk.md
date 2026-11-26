# Plano de implementação do APK com fases geradas do YouTube

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. O usuário pediu execução paralela com gpt-6.1-sol, esforço max; usar worktrees separados e contrato fixo para tarefas independentes. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Entregar um fork do EchoTiles, backend de importação/análise e APK Android instalável com quatro colunas sincronizadas ao áudio original.

**Architecture:** O downloader segue recomendações oficiais atuais do yt-dlp e mede o sucesso com mídia real. Um worker Python produz áudio e mapa temporal, persistidos com a biblioteca em SQLite. O Flutter importa faixas por HTTP, prepara mídia local e projeta as teclas a partir do relógio do áudio.

**Tech Stack:** Flutter/Dart, Android SDK/Java 17+, Python 3.13, FastAPI, SQLite, librosa, yt-dlp/EJS/runtime JS e FFmpeg.

**Spec:** `docs/superpowers/specs/2026-11-25-youtube-rhythm-apk-design.md`.

## Global Constraints

- Entregar um APK instalável no Android. O servidor remoto Umbrel, sem GUI, executa o backend.
- Preservar o piano tiles tradicional: tela vertical, exatamente quatro colunas e a jogabilidade do EchoTiles.
- Gerar as teclas a partir das batidas e dos ataques do áudio completo, reproduzindo a gravação original durante a partida.
- A prioridade das decisões de download é: recomendações oficiais do yt-dlp para YouTube; resultados reproduzíveis dos testes neste servidor; aprendizados aplicáveis do curso-ingles.
- Trabalhar em paralelo com subagentes gpt-6.1-sol, esforço max, usando subagent-driven-development, revisão por tarefa e revisão final.
- No máximo três subagentes ativos além do controlador; cada implementação em worktree próprio e apenas nos arquivos atribuídos. Nenhum trabalhador cria subagentes.
- Preservar licença/créditos. Credenciais, cookies, keystores, logs sensíveis, mídia de testes, caches, SDK e arquivos de execução ficam fora do Git.
- Novos fluxos e mensagens serão em português. Limites configuráveis: 50 entradas, 900 s por faixa, 2 GiB de cache no servidor, 256 MiB no APK.
- O contrato vinculante entre tarefas é `docs/contracts/youtube-v1.md`; alterações exigem coordenação com o controlador e os consumidores.
- Se algum HTML de apoio for entregue, ele será servido por túnel, conforme a instrução do usuário.

## Review Focus

- Playlist com vídeo privado ou entrada sem ID conserva ordem e resultados prontos: tarefa 2, `test_partial_playlist_keeps_ready_items`.
- URL contendo vídeo e playlist não importa coleção por acidente: tarefas 1/3, testes de resolução e escolha de modo.
- Cache parcial, quota e reinício não produzem uma faixa pronta sem mídia/mapa válidos: tarefa 2, testes de publicação e recuperação.
- Introdução silenciosa, frames perdidos e pause/resume não deslocam os ataques musicais: tarefas 2/3, fixtures controladas e relógio falso.
- Sucesso de download exige arquivo completo validado, e a medição distingue cache e novas transferências: tarefa 1, relatório empírico e testes de retorno inválido.

## Organização e integração

Os paths descritos abaixo são relativos ao worktree de cada tarefa. As tarefas 1, 2 e 3 podem começar da mesma base. A tarefa 4 começa quando houver vaga e o SDK fornecido pela tarefa 3 estiver utilizável. Cada agente registra commits próprios; o controlador revisa os diffs base..head e integra os commits sequencialmente. Baseline upstream: `856ecc87f1d851ebf7123f7f900a371be5bc4809`, conferido novamente antes da execução. A ausência inicial de testes é registrada, sem inventar evidência de aprovação.

### Task 1: downloader YouTube e validação empírica

**Files:** Create `backend/src/echotiles_backend/downloader.py`, `backend/tests/test_downloader.py`, `backend/tools/validate_youtube_downloads.py`, `docs/research/youtube-download-validation-2026-11-25.md`. Não modificar pyproject, API, worker ou código Flutter nesta tarefa.

**Interfaces:** Consome o contrato `docs/contracts/youtube-v1.md` e as fontes oficiais. Produz exatamente as dataclasses e métodos síncronos da interface Python documentada. A tarefa 2 importa esse módulo; o progresso usa apenas as etapas documentadas.

- [ ] Ler README, EJS, extrator YouTube e guia PO Token oficiais. Consultar Context7 para documentação atual. Registrar fonte/data e resolver dependências em ambiente próprio do protótipo, sem alterar curso-ingles. Deno é a recomendação inicial dos mantenedores; Node habilitado explicitamente é alternativa suportada. Escolher a versão/nightly conforme documentação e registrar o valor real.
- [ ] Escrever testes para URL inválida e domínio impostor, vídeo com list em auto/video, playlist em modo explícito, limite max+1, item privado, processo falho, timeout, duração excessiva, áudio ausente e tamanho/hash reais. Rodar antes da implementação e verificar falhas significativas.
- [ ] Implementar a interface do contrato, subprocessos sem shell, metadados/playlist limitados, uma transferência por vez, pausas documentadas, retries finitos e diagnóstico estruturado. Produzir M4A/AAC com gravação completa e ffprobe/hash, usando staging exclusivo e sem sucesso em conversão falha. O arquivo final servido é a base da análise.
- [ ] Criar harness executável que registre tentativas/configuração e valide arquivos sem guardar tokens/URLs assinadas na saída pública. Permitir apontar uma lista de URLs e diferenciar transferência nova de cache. Começar pelos clientes padrão; aplicar fallback documentado e motivado pelos erros, inclusive provider de PO Token quando necessário e viável.
- [ ] Fazer download completo inicial; ajustar uma hipótese por rodada até funcionar. Depois exercitar pelo menos dez vídeos públicos elegíveis distintos e uma playlist pequena, com fila espaçada. Medir primeira tentativa e após recuperação, mantendo todos os elegíveis no denominador. Alvo inicial: >=90% na amostra. Se falhar, continuar investigação fundamentada, sem repetir recusas indefinidamente ou alegar sucesso simulado.
- [ ] Rodar testes com ambiente isolado e `PYTHONPATH=backend/src`. Escrever relatório de hipóteses, resultados por URL/versão, denominadores, configuração escolhida e limitações. Informar à tarefa 2 o caminho/comando de execução e pin de versão. Commitar somente arquivos da tarefa; retornar relatório completo no path fornecido pelo controlador.

### Task 2: biblioteca, análise rítmica, fila e API

**Files:** Create `backend/pyproject.toml`, `backend/uv.lock` quando gerado, `backend/README.md`, `backend/src/echotiles_backend/__init__.py`, `__main__.py`, `config.py`, `models.py`, `storage.py`, `analysis.py`, `worker.py`, `api.py` e testes correspondentes em `backend/tests/`. Não escrever downloader.py, test_downloader.py, tools/validate_youtube_downloads.py, android/, lib/ ou pubspec.

**Interfaces:** Consome o downloader definido no contrato (a implementação chega da tarefa 1; usar dublê injetável nos testes da tarefa 2). Produz os endpoints e JSON exatos do contrato. CLI obrigatória: `uv run --project backend echotiles-backend serve --host 0.0.0.0 --port 8765`, com API e um worker de processamento separado. Configuração por env `PIANO_DATA_DIR`, `PIANO_MAX_PLAYLIST_ITEMS`, `PIANO_MAX_DURATION_SECONDS`, `PIANO_CACHE_LIMIT_BYTES`, `PIANO_YT_DLP`, `PIANO_JS_RUNTIME`; comandos de downloader podem ser configurados sem shell e sem aceitar flags do usuário HTTP.

- [ ] Criar testes iniciais de `POST /api/imports` (202 rápido), consulta de import e track, validação de URL, playlist parcial (`test_partial_playlist_keeps_ready_items`), duplicata, reinício e quota. Usar downloader injetável para não executar rede nos testes. Verificar falha antes de implementar.
- [ ] Implementar SQLite persistente com transações de claim/estado e recuperação de itens interrompidos; processamento sequencial. Registrar itens indisponíveis na ordem. API permanece responsiva durante downloads/análise. Faixa pronta exige arquivo final e mapa publicados de modo consistente. Evitar cache reutilizado sem mídia íntegra e limites ultrapassados durante a transferência/conversão.
- [ ] Implementar `generate_chart(audio_path: Path, track_id: str, audio_sha256: str) -> dict` em analysis.py usando o arquivo de playback. Eventos em ms absolutos, quatro lanes determinísticas, no máximo dois contatos e espaçamento mínimo jogável. Conservar introduções e pausas; evitar preencher silêncio com batidas estimadas. Silêncio sem ataques gera `no_playable_events`.
- [ ] Testar clicks em tempos conhecidos com introdução silenciosa, áudio vazio/silencioso, ataques próximos e determinismo. Asserções incluem quatro lanes, ordem, limites, distância temporal tolerante à resolução do detector e que o primeiro click mantém sua posição absoluta. Perfil padrão usa taps e duplas seletivas; schema permite holds válidos, sem exigir transcrição de notas.
- [ ] Implementar endpoints do contrato, arquivos por IDs próprios e resposta de áudio com Range/Content-Length. Testar leitura parcial, 404, erro sanitizado, charts e hash/duração. Persistir catálogo e estados e manter resultados prontos de importações parciais.
- [ ] Resolver ambiente/dependências com uv, informar ao downloader o ambiente reutilizável, rodar testes próprios e documentar CLI/configuração no README do backend. Commitar arquivos atribuídos e escrever o relatório pedido. Após a integração do downloader, o controlador repetirá somente verificações necessárias dessa ligação e o caminho real de uma importação.

### Task 3: importação e jogo Flutter sincronizado

**Files:** Modify `lib/models/game_models.dart`, `lib/services/audio_service.dart`, `song_catalog.dart`, `storage_service.dart`, `lib/screens/home_screen.dart`, `game_screen.dart`, `settings_screen.dart` conforme necessário; create modelos/serviços/telas pequenos para imports, cache, beatmap, timeline e relógio; own `lib/l10n/`, `test/`, `pubspec.yaml`, `pubspec.lock`. Não modificar android/, backend/ ou scripts de build.

**Interfaces:** Consome os endpoints e JSON exatos de `docs/contracts/youtube-v1.md`. O servidor terá endereço configurável no APK e URLs de áudio/chart relativas. Produz a experiência do design e mantém arquivos locais/demo originais funcionais. Cache de áudio selecionado validado por SHA-256 e bytes, publicado atomicamente e limitado a 256 MiB; mapa valida lanes/tempos/hash/duração. Libs HTTP/crypto/path_provider podem ser adicionadas com documentação oficial consultada.

- [ ] Provisionar SDK Flutter compatível com Dart ^3.13.4 e dependências existentes em `/home/dev/.local/opt/flutter-youtube-prototype/` (ou instalação compatível já existente). Conferir a fonte oficial e versão; não usar fork/mirror não verificado. Compartilhar imediatamente o path do SDK com controlador para a tarefa 4. Se download oficial falhar, diagnosticar origem e usar outra via oficial documentada.
- [ ] Rodar analyze/test baseline disponíveis e registrar problemas anteriores. Criar testes de parsing e rejeição de charts inválidos, HTTP da importação, seleção explícita vídeo/lista e falhas de rede com dublês. Testar cache incompleto/corrompido sem tratar como mídia pronta.
- [ ] Integrar botão/tela de importação YouTube, ajuste do servidor com teste de conexão, estados da fila e biblioteca de faixas prontas. Fazer polling apenas enquanto a tela estiver ativa, tratar erros por faixa e importar prontas sem duplicação. Mensagens novas em português e desenho coerente com EchoTiles, sem reformular o jogo.
- [ ] Criar timeline e relógio testáveis com posição absoluta de áudio. Testes: mesma posição em 30/60/120 Hz, frames perdidos, pause/resume e primeiro evento após introdução silenciosa. Preparar fonte local e mapa antes de começar; contagem visual usa tempo negativo. Não iniciar ticker de jogo silencioso após falha de áudio.
- [ ] Integrar mapa no GameScreen preservando quatro colunas verticais, alvo/toque, combo e falha imediata por toque vazio/peça perdida. Preservar suporte existente a duplas/longas e o caminho das faixas locais. Pausa e ciclo de vida Android congelam áudio e timeline juntos. Não criar notas aleatórias depois dos eventos do chart nem dar vitória prematura.
- [ ] Executar format/analyze/test apropriados, ajustar apenas problemas causados ou bloqueadores do escopo e registrar baseline restante. Commitar somente arquivos atribuídos e escrever relatório. Informar dependências/necessidades Android à tarefa 4; não criar reviewer próprio.

### Task 4: APK Android, assinatura e instruções de instalação

**Files:** Own `android/` com mudanças mínimas em app/build.gradle.kts, app/src/main/AndroidManifest.xml e configuração de rede; create `tools/build_android_apk.sh`, `docs/android-prototype.md`. Pode atualizar `.gitignore` apenas coordenando com o controlador. Não modificar pubspec, lib/ ou backend/.

**Interfaces:** Consome o SDK compatível provisionado na tarefa 3 e o Android SDK existente em `/home/dev/Android/Sdk`. Mantém namespace/activity existentes e usa applicationId `com.sidhant.echotiles.youtubeprototype`, rótulo `EchoTiles YouTube`. Produz APK de protótipo assinado, reproduzível e validado; builds de release podem usar assinatura de desenvolvimento explicitamente documentada quando não houver keystore de distribuição, sem exigir segredos do upstream.

- [ ] Ler skill android-cli e instruções locais aplicáveis; conferir Java/SDK/plugins e estado de dispositivos com leituras normais, sem instalar no telefone ou alterar dispositivos do usuário sem pedido. Testar build baseline e identificar a falha de keystore conhecida.
- [ ] Acrescentar INTERNET ao release e permitir HTTP para a LAN do protótipo com configuração documentada; conservar HTTPS funcional. Corrigir configuração Gradle de assinatura ausente com fallback explícito de protótipo e identidade distinta. Conservar compatibilidade com keystore quando fornecido legitimamente.
- [ ] Criar script de build com caminhos/env configuráveis, erro claro, sem segredos em logs. Gerar APK universal quando possível, validando assinatura e applicationId com ferramentas Android. Não publicar SDK/keystore/APK no Git.
- [ ] Documentar instalação, endereço de servidor editável, execução da API, assinatura do protótipo e limitações de teste em aparelho. A instrução final deve apontar o APK real gerado depois da integração, não a compilação de baseline.
- [ ] Verificar Gradle e build no worktree próprio; depois da integração das tarefas 1–3, controlador roda o build final. Commitar somente arquivos atribuídos, registrar checks exatos e retornar relatório. Não instalar APK em dispositivo físico por conta própria.
