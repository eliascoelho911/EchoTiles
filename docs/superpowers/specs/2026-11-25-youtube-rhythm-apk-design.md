# Protótipo Android de piano tiles com importação do YouTube

Data: 25/11/2026. Estado: escopo revisto pelo usuário, com prioridade explícita para as recomendações oficiais do yt-dlp e validação empírica do download.

## O que o usuário confirmou

- Fazer um fork de https://github.com/sidhant947/EchoTiles e integrar um backend de importação por link de música ou playlist do YouTube.
- Usar yt-dlp com a documentação oficial e as recomendações atuais dos mantenedores para YouTube como base principal. Consultar os docs e o ai-memory do curso-ingles como evidência complementar.
- Depois de estabelecer a base recomendada, experimentar, diagnosticar falhas e ajustar o método até obter uma boa taxa de sucesso medida em downloads reais.
- Gerar as teclas a partir das batidas e dos ataques do áudio completo, reproduzindo a gravação original durante a partida.
- Preservar o piano tiles tradicional: tela vertical, exatamente quatro colunas e a jogabilidade do EchoTiles.
- Entregar um APK instalável no Android. O servidor remoto Umbrel, sem GUI, executa o backend.
- Trabalhar em paralelo com subagentes gpt-6.1-sol, esforço max, usando subagent-driven-development, revisão por tarefa e revisão final.

## Caminho escolhido e dimensão

É uma integração entre o aplicativo existente e um backend novo. O Flutter e o alvo Android já presentes no EchoTiles são a base do aplicativo. O backend Python recebe os links, baixa o áudio, analisa o ritmo e publica um mapa temporal para cada música. O Android carrega o áudio e esse mapa antes da partida.

Esse caminho corresponde ao fork e à integração de backend pedidos. Analisar no telefone aumentaria o processamento e a instalação no aparelho; um aplicativo web seria outra entrega. A escolha confirmada é APK com processamento no servidor. A biblioteca será pessoal, acessível pela rede local segura descrita pelo usuário.

## Experiência no aplicativo

1. Na biblioteca, o usuário configura uma vez o endereço do servidor e verifica a conexão.
2. O botão de importação aceita um link de vídeo ou playlist. Se o link contiver vídeo e playlist, o usuário escolhe qual importar, evitando incluir uma coleção por acidente.
3. A tela apresenta etapas compreensíveis: na fila, baixando, preparando áudio, analisando e pronta. Uma playlist conserva sua ordem e exibe o resultado de cada faixa. As faixas prontas podem ser jogadas enquanto as demais são processadas.
4. Cada faixa pronta mostra título, canal/artista informado pela origem e duração. O usuário escolhe uma faixa para jogar.
5. Antes de começar, o APK obtém o mapa e coloca o áudio selecionado em cache local. A partida começa depois do preparo e de uma breve contagem visual; a introdução e os silêncios da música são mantidos.
6. As peças descem em quatro colunas. Tocar em uma peça válida a remove e pontua; tocar vazio ou deixar uma peça passar encerra a partida, conforme o EchoTiles. Feedback, combo, temas e controles de toque/multitoque existentes são preservados.
7. Pausar, sair da tela ou mandar o app para segundo plano pausa a música e o jogo juntos. Reiniciar a fase usa novamente o mesmo mapa.

Novos fluxos e mensagens serão em português. A adaptação mantém o desenho e o palco do EchoTiles. A configuração do servidor é uma tela pequena de conexão, com endereço editável e teste de disponibilidade.

## Download e análise no servidor

- Python, FastAPI, SQLite e arquivos em diretório próprio do protótipo. Um worker separado processa uma faixa por vez, mantendo a API disponível durante a análise. Não é necessário broker externo para essa primeira versão.
- Entrada restrita a URLs reconhecidas do YouTube. O processo yt-dlp recebe argumentos em lista, com destinos e opções definidos pelo servidor.
- Escolher instalação, versão/canal, dependências EJS, runtime JavaScript, clientes e formatos conforme as recomendações oficiais atuais do yt-dlp para YouTube. Instalar uma cópia própria do protótipo quando necessário e registrar as versões efetivamente testadas. FFmpeg/ffprobe e runtimes compatíveis existentes podem ser reutilizados por caminhos configuráveis.
- A prioridade das decisões de download é: recomendações oficiais do yt-dlp para YouTube; resultados reproduzíveis dos testes neste servidor; aprendizados aplicáveis do curso-ingles. Confrontar práticas do curso com essa base antes de adotá-las. Suas credenciais, sessões e opções específicas do Vimeo pertencem àquele projeto.
- Começar com vídeos públicos sem autenticação. Falhas de login, indisponibilidade e limites de requisição ficam visíveis no item; recusas persistentes encerram a tentativa, sem repetição ilimitada. Não há promessa de indetectabilidade.
- Extrair a gravação completa para M4A/AAC compatível com Android. A duração e o SHA-256 vêm desse arquivo final. A análise é feita sobre a mesma mídia que o aparelho reproduzirá, sem cortes ou alteração de velocidade.
- Calcular ataques e pulso da mixagem completa com librosa. Os ataques fortes dão os tempos principais; o pulso auxilia a densidade. Os timestamps conservam pausas e mudanças locais do áudio. BPM é metadado, não um substituto para os tempos detectados.
- Transformar os candidatos em um mapa determinístico de quatro colunas, limitando eventos muito próximos e contatos simultâneos. As peças representam ritmo, sem pretensão de transcrever alturas musicais ou separar instrumentos.
- Usar o perfil padrão na primeira entrega. O gerador prioriza peças simples e pode criar duplas nos ataques fortes; o motor mantém suporte às peças longas já existentes. A musicalidade precisa ser verificada ouvindo uma amostra jogável.
- Publicar uma faixa somente quando mídia e mapa estiverem validados. Duplicatas reutilizam o resultado correspondente ao vídeo, ao áudio e à versão do gerador. Uma falha não remove os resultados prontos de uma playlist.
- Persistir a biblioteca e o progresso. Após reinício, itens em processamento voltam a um estado recuperável. Downloads parciais não aparecem como faixas prontas.

Limites iniciais propostos, configuráveis no servidor: 50 entradas por playlist, 15 minutos por faixa e 2 GiB de mídia em cache. Uma entrada acima do limite recebe explicação; a coleção nunca é truncada silenciosamente. Não apagar automaticamente faixas prontas para abrir espaço. Remover temporários de tentativas encerradas e recusar novas mídias quando atingir a quota.

### Como escolher e comprovar o método de download

1. Ler README, guia EJS, wiki do extrator YouTube e guia de PO Token oficiais e registrar a data da consulta. Começar pela configuração recomendada e pelos clientes padrão da versão utilizada; aplicar alternativas documentadas quando o diagnóstico indicar necessidade.
2. Fazer um primeiro download completo e validá-lo com ffprobe. Se falhar, classificar o erro antes de mudar a configuração: instalação/runtime, resolução de formatos, token exigido, falha HTTP transitória, limite de requisições ou indisponibilidade da origem.
3. Experimentar uma mudança relevante por vez, com tentativas espaçadas e orçamento limitado por item. Registrar a hipótese, versão, configuração, resultado e decisão. As variações úteis passam a compor uma estratégia documentada; configurações que apenas repetem uma recusa não viram um fallback permanente.
4. Depois de um caminho funcional, medir em pelo menos dez vídeos públicos distintos e elegíveis e em uma playlist pequena. Usar faixas de origens e durações variadas; manter no denominador todos os itens inicialmente elegíveis que falharem. Relatar separadamente itens restritos/indisponíveis, acertos de cache, sucesso na primeira tentativa e sucesso após recuperação.
5. Adotar inicialmente como alvo de engenharia pelo menos 90% de sucesso entre os vídeos elegíveis dessa amostra. Esse alvo e a amostra são critérios operacionais escolhidos para o protótipo, sem promessa estatística sobre todo o YouTube. Se não atingir o alvo, continuar a investigação e repetir os casos que sustentam a comparação, respeitando os limites do serviço.
6. Só descrever o método como validado quando houver arquivos reais completos e inspecionados. Registrar qualquer impedimento externo que impossibilite a validação; os testes com processos simulados verificam o software, não a taxa de sucesso do YouTube.

Referências principais: [README e instalação](https://github.com/yt-dlp/yt-dlp#installation), [EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS), [extrator YouTube](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#youtube) e [PO Token](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide).

## Mapa e integração entre os componentes

O mapa contém versão do schema, identidade da faixa, hash do áudio, duração em milissegundos, `lanes: 4`, BPM estimado e eventos com `id`, `timeMs`, `lane` e tipo. `lane` é inteiro entre 0 e 3; os tempos são finitos, ordenados e pertencem à duração da mídia. Peças longas, quando presentes, têm duração explícita. Limitar a dois contatos simultâneos e evitar conflitos na mesma coluna.

O backend fornece criação e acompanhamento de importações, biblioteca de faixas prontas, mapa e arquivo de áudio. Uma importação contém itens independentes e ordenados, com estado e erro resumido. O contrato detalhado será fixado no plano antes da implementação paralela do servidor e do APK.

O APK distingue uma faixa remota pronta de um arquivo local já existente. Downloads para o cache do aparelho usam arquivo temporário e só ficam disponíveis depois da conclusão e validação. O cache local terá limite de 256 MiB e poderá ser refeito a partir do servidor. Somente a música escolhida precisa ser transferida para iniciar uma partida.

O movimento das peças passa a ser calculado pelo tempo absoluto do áudio. O ticker do Flutter redesenha a tela; a posição não acumula deslocamentos por frame. O relógio recebe âncoras do player e interpola com tempo monotônico enquanto há reprodução, corrigindo pause/resume. A contagem inicial usa tempo negativo e não desloca os eventos da gravação. O término considera a música e os eventos reais do mapa, sem gerar peças extras depois do áudio.

As músicas e os arquivos locais do EchoTiles continuam disponíveis. O novo fluxo usa o mapa gerado pelo servidor; a gravação é reproduzida na velocidade original. As mudanças de sincronização terão testes próprios, pois a implementação atual usa padrões aleatórios independentes da posição do player.

## Android, servidor e entrega

- Incluir a permissão de internet no APK e permitir a conexão HTTP necessária ao servidor da rede local. Endereços HTTPS também serão aceitos. O endereço do backend é configurável no aplicativo, sem depender de endereço público fixo.
- Construir um APK de protótipo assinado e instalável, com identidade de aplicativo própria para conviver com o EchoTiles original. Documentar a assinatura usada e conservar a chave fora do Git.
- Provisionar Flutter compatível com o projeto e usar o SDK Android existente. Não há necessidade de GUI para compilar. Validar assinatura e metadados do APK produzido.
- Fornecer instruções reproduzíveis para iniciar o backend e configurar o APK, além do arquivo instalável e do código no fork. Preservar a licença e os créditos do EchoTiles e da música de exemplo.
- A API fica acessível na rede local para o telefone. Se algum HTML de apoio for entregue, ele será servido por túnel, conforme a instrução do usuário.
- A implementação do backend e a do cliente podem correr em paralelo depois de fixado o contrato, em áreas isoladas e com integração coordenada; cada uma recebe revisão de escopo e qualidade, seguida de revisão do conjunto.

## Como verificar o protótipo

- Testes do gerador com áudio controlado: ataques em tempos conhecidos, introdução silenciosa, silêncio completo, ataques próximos e variação de ritmo. Verificar tempos, quatro colunas, limites e determinismo. Silêncio sem eventos recebe resultado explícito.
- Testes da fila e API: vídeo único, playlist com entrada indisponível, duplicata, falha de download, reinício e quota. Testes automatizados usam substitutos do processo yt-dlp, sem bombardear o YouTube.
- Testes puros da timeline e do relógio: mesmo tempo produz mesma posição em diferentes taxas de frames; pausa/retomada, frames perdidos, primeira e última nota e falha de áudio têm comportamento definido.
- Flutter analyze/test e build do APK. Testes de toque e multitoque cobrem a regra de falha e a ligação entre faixa importada e mapa.
- O ciclo de downloads reais e a medição descritos acima verificarão o método escolhido, seguidos da importação completa até o mapa e da playlist pequena. O link de preferência do usuário pode ser usado quando informado; a ausência dele não impede selecionar URLs públicas para o teste.
- A precisão percebida no aparelho físico exige instalação e uso no Android. Se não houver dispositivo conectado, entregar o APK compilado e relatar claramente o que foi validado no servidor e o que depende do teste no telefone.

Critério de conclusão: fork com a integração, backend iniciado com instruções de uso, APK instalável produzido, importação e mapa exercitados com evidências reais ou limitação externa documentada, e revisões concluídas. Não apresentar um teste simulado como prova de que o download do YouTube funcionou.

## Evidências consultadas

- EchoTiles, commit `856ecc87f1d851ebf7123f7f900a371be5bc4809`: fontes Flutter/Android, manifesto, áudio, jogo, modelo de músicas, dependências e licença.
- Relatório de leitura do código e documentação oficial: `/tmp/piano-tiles-echotiles-research.md`.
- Código canônico do curso-ingles e wiki compilada do ai-memory, escopo `default` / `eliascoelho911-curso-ingles`. O histórico registra dificuldades e relatos de bloqueio no Vimeo, sem comprovar a causa.
- Relatório com páginas e arquivos consultados e documentação oficial do yt-dlp: `/tmp/piano-tiles-course-download-research.md`.
