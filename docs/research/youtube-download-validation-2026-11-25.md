# Validação do downloader YouTube — 2026-11-25

Este relatório separa downloads reais, testes locais com ferramenta substituta e reutilização de cache. O alvo inicial é pelo menos 90% de sucesso em dez vídeos públicos elegíveis distintos, mais uma playlist pequena. Cada download de rede obtém a gravação completa; nenhum resultado simulado entra na taxa empírica.

## Fontes e decisão inicial

Fontes oficiais consultadas em 2026-11-25, conferidas com Context7 (`/yt-dlp/yt-dlp-wiki`, consulta de EJS, Deno, clientes padrão e PO Tokens):

- [README / atualização e dependências](https://github.com/yt-dlp/yt-dlp#update): os mantenedores recomendam o canal nightly para uso regular, disponível como pacote Python pré-release. O grupo `default` instala as dependências recomendadas, incluindo EJS; FFmpeg e ffprobe são executáveis externos. Nesta execução usei Python em ambiente exclusivo do protótipo.
- [Guia EJS](https://github.com/yt-dlp/yt-dlp/wiki/EJS): Deno é a primeira opção recomendada e habilitada por padrão; o mínimo documentado é 2.3.0. Node >=22 é alternativa suportada, habilitada explicitamente. Os scripts EJS foram instalados junto do yt-dlp com o grupo `default`; não houve download dinâmico de scripts como fallback.
- [Extrator YouTube](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#youtube): começar pelos clientes padrão. Quando eles falham e o diagnóstico aponta necessidade de PO Token, o guia sugere `mweb` com token. Conteúdo que exige conta é uma condição diferente de vídeo público.
- [Guia PO Token](https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide): providers podem fornecer tokens por vídeo, e `mweb` exige token para GVS. O guia lista providers mantidos por membros da comunidade, sem garantia universal. A seleção ou instalação de um provider deve responder a uma falha concreta; o método com clientes padrão funcionou nesta máquina.
- [Instalação do Deno](https://docs.deno.com/runtime/getting_started/installation/) e [release oficial 2.9.8](https://github.com/denoland/deno/releases/tag/v2.9.8): binário Linux x86-64 instalado em diretório próprio, sem alterar ferramentas do curso-ingles.

A pesquisa histórica `/tmp/piano-tiles-course-download-research.md` foi lida como evidência secundária: fila única, intervalos, orçamento finito de retries, staging, sondagem e hash foram princípios aproveitados. Nenhum login, cookie, segredo, venv ou código do curso-ingles foi usado ou alterado.

## Ambiente reproduzível

| Componente | Valor efetivamente utilizado |
| --- | --- |
| Host | Linux remoto, sem GUI; acesso direto à rede desta máquina |
| Python do piloto | `/usr/bin/python3`, 3.13.5 |
| Venv exclusivo | `/home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv` |
| yt-dlp no instalador Python | `2026.11.24.232653.dev0` |
| `yt-dlp --version` | `2026.11.24.232653` |
| yt-dlp-ejs | `0.8.0` |
| Deno | `2.9.8`, binário oficial Linux x86-64 |
| FFmpeg / ffprobe | `7.1.3-0+deb13u1` em `/usr/bin` |
| Cookies / conta / provider | Nenhum |
| Cliente forçado | Nenhum; clientes padrão do nightly |

Instalação feita com `uv venv --python /usr/bin/python3 /home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv`, seguida de `uv pip install --python .../venv/bin/python --prerelease allow 'yt-dlp[default]' pytest`. Para reproduzir a mesma versão no ambiente do backend:

```sh
uv pip install --python /caminho/do/backend/.venv/bin/python 'yt-dlp[default]==2026.11.24.232653.dev0' 'yt-dlp-ejs==0.8.0'
```

O Deno veio de `https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-unknown-linux-gnu.zip`; somente o executável `deno` foi extraído para `/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno`. Não foi instalado em um projeto de terceiros.

A configuração consumida pela tarefa 2 é:

```python
DownloadConfig(
    command=("/caminho/do/backend/.venv/bin/python", "-m", "yt_dlp"),
    js_runtime="deno:/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno",
)
```

Portanto `PIANO_JS_RUNTIME=deno:/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno`. O valor desse ambiente é interpretado pela configuração da API, que está fora desta tarefa.

## Política implementada

`resolve` aceita apenas URLs públicas reconhecidas de hosts exatos YouTube/youtu.be e canonicaliza o endereço antes do subprocesso. Uma URL com vídeo e lista continua um vídeo nos modos `auto` e `video`. Só o modo explícito `playlist` escolhe a lista. A enumeração é plana e termina em `max_playlist_items + 1`; o item extra detecta excesso sem enumerar a lista inteira. Entradas privadas, excluídas e ausentes permanecem na ordem como referências indisponíveis quando o extrator as expõe.

Cada chamada usa argumentos em vetor, sem shell, `--ignore-config`, cache do extrator desabilitado, socket de 30 s, dois retries de HTTP/fragmento, um de extração e espera exponencial de 1 a 30 s. A transferência tem um fragmento concorrente, pausas de 5–10 s antes do download e 0,75 s entre requisições de extração. O harness adiciona 5 s entre itens. Um lock serializa transferências no processo; o worker da API possui sua própria fila única. Nenhum retry externo ilimitado foi introduzido.

O orçamento de 1.200 s cobre consulta, transferência, conversão e sondagem de cada `download`. Metadados sem duração finita, lives em andamento/aguardando processamento e duração acima de 900 s são recusados. `--max-filesize` limita a fonte a 128 MiB; fonte e resultado também são medidos no disco antes de serem aceitos. A quota global de 2 GiB pertence ao worker da API, não a este módulo.

O yt-dlp baixa `bestaudio/best` para um subdiretório temporário exclusivo e informa o caminho final local por JSON. O código exige que o caminho esteja no staging, que haja áudio e que sua duração seja consistente com o conteúdo anunciado. A tolerância contra truncamento é o maior entre 2 s e 2% dos metadados, pois o YouTube arredonda durações; isso não prova identidade acústica ou integridade de cada pacote. FFmpeg decodifica a gravação completa e produz AAC a 192 kbit/s em M4A, com `-xerror`, sem recorte temporal e sem remoção de silêncios. Uma falha de conversão não publica arquivo pronto.

O arquivo convertido é sondado novamente: áudio AAC, contêiner MP4, tamanho positivo e duração finita. A duração canônica é `round(float(ffprobe.format.duration) * 1000)`, alinhada com a análise da tarefa 2. SHA-256, tamanho e `fsync` precedem a publicação no staging do chamador. Somente esse M4A final é oferecido para análise e reprodução.

Cada helper inicia uma sessão de processo própria. Em timeout o downloader mata o grupo do helper e faz `wait`. A tarefa 2 foi avisada de que matar apenas o grupo do worker não cobre esses helpers; a supervisão externa precisa encerrar a árvore de descendentes para interrupções por quota.

## Rodadas de diagnóstico

1. **Hipótese inicial: nightly + EJS + Deno e clientes padrão bastam.** O ID histórico `BaW_jenozKc` retornou “This video is unavailable” antes da transferência. Isso diagnostica indisponibilidade daquele candidato, sem prova de falha do runtime. A exclusão é registrada abaixo.
2. **Uma variável alterada: usar vídeo público disponível.** `jNQXAC9IVRw` foi transferido integralmente; o log mostra execução do solver `[jsc:deno]`, formato 251 e conversão bem-sucedida. ffprobe confirmou AAC em MP4, 19.012 s, 461.596 bytes, SHA-256 `f07f4534323c1ad3357c86072257a95ed48d4b02c47d13c48c51d5f2f4da6966`. É conteúdo falado e serve de diagnóstico, sem compor a amostra musical principal.
3. **Uma variável alterada: conteúdo musical.** `J---aiyznGQ` também completou no mesmo preset. M4A em `/home/dev/piano-tiles-youtube/.runtime/youtube-validation/music-baseline/J---aiyznGQ.m4a`, 54.469 s e 1.314.116 bytes. O caminho foi comunicado ao controlador para análise real.
4. **Mesmo método pela interface implementada.** Dez músicas distintas foram enfileiradas pelo harness. Os resultados individuais abaixo vêm dos arquivos finais produzidos pelo módulo, sem cache.
5. **Mesmo método para playlist explícita.** A lista pequena de exercícios de piano é enumerada e seus itens processados em ordem, após a fila principal.

O procedimento parou após a amostra requerida e a playlist, pois nenhum erro dos clientes padrão justificou trocar cliente, runtime ou instalar provider. Não se alega sucesso do fallback `mweb`/PO Token ou de Node, já que não foram usados.

## Comandos do piloto

```sh
cd /home/dev/piano-tiles-youtube/.worktrees/downloader
PYTHONPATH=backend/src /home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv/bin/python \
  backend/tools/validate_youtube_downloads.py \
  --output-dir /home/dev/piano-tiles-youtube/.runtime/youtube-validation/principal \
  --js-runtime deno:/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno \
  --label default-clients-nightly --gap-seconds 5
```

Para playlist sem repetir a amostra padrão, foi fornecido um arquivo JSON contendo `[]` em `--urls-file` e a URL em `--playlist`. O harness aceita também uma lista de URLs fornecida pelo operador. `--extra-arg` permite avaliar um fallback documentado mantendo a interface Python; valores arbitrários dessas opções são omitidos do ledger público. `--attempts` aceita no máximo três tentativas externas e só repete erros marcados como recuperáveis. Cache só é consultado com `--reuse-cache`; cada reutilização exige novo hash, tamanho, AAC/MP4 e duração e fica identificada como `transfer=cache`, sem aumentar a taxa de novas transferências.

Os ledgers JSON ficam em `.runtime/youtube-validation`, com permissão 0600 e diretórios de mídia 0700. As saídas públicas incluem apenas URLs públicas canônicas, metadados selecionados, tempos, tamanho e hash; não incluem URLs assinadas de CDN, tokens, cookies ou stderr bruto. Os logs diagnósticos anteriores e metadados brutos permanecem no diretório privado fora do Git.

## Resultado empírico

A meta inicial foi atingida com o nightly `2026.11.24.232653` e a mesma configuração padrão em todas as URLs das duas tabelas. Amostra principal: **10/10 vídeos públicos elegíveis distintos, 100% na primeira chamada e 100% após recuperação**. Foram dez transferências novas, nenhum cache, nenhum vídeo excluído nessa amostra e nenhuma chamada externa adicional de recuperação. As durações finais variam de 54.469 a 359.452 ms; há dez canais distintos e 57.341.315 bytes finais. A campanha começou em `2026-11-25T22:13:37.427897+00:00` e terminou em `2026-11-25T22:19:35.921767+00:00`.

| Vídeo público | Título / canal | Duração (ms) | Bytes | SHA-256 do M4A final | Tempo da chamada (s) |
| --- | --- | ---: | ---: | --- | ---: |
| [J---aiyznGQ](https://www.youtube.com/watch?v=J---aiyznGQ) | Keyboard Cat! - THE ORIGINAL! / Keyboard Cat! | 54469 | 1314116 | `ffc9a022bddb8dc2177456d3602cba1c00b2e94388339b9f63e0b8b8e1e293bb` | 25.317 |
| [9bZkp7q19f0](https://www.youtube.com/watch?v=9bZkp7q19f0) | PSY - GANGNAM STYLE(강남스타일) M/V / officialpsy | 252222 | 6164081 | `e0cb7a99c93f46fde40fa8e42c8e9c7822178d132260eede2027f4700d1af404` | 29.018 |
| [kJQP7kiw5Fk](https://www.youtube.com/watch?v=kJQP7kiw5Fk) | Luis Fonsi - Despacito ft. Daddy Yankee / Luis Fonsi | 281514 | 6805718 | `51054680826141c6b7730fb101a0e2c01a35f87a659f889f9aa4375c9f16623b` | 28.552 |
| [fJ9rUzIMcZQ](https://www.youtube.com/watch?v=fJ9rUzIMcZQ) | Queen – Bohemian Rhapsody (Official Video Remastered) / Queen Official | 359452 | 8645627 | `9df658849da3461352d2e80adbb78a44e7cb101ba27529eed349fa9d10b37b84` | 44.994 |
| [y6120QOlsfU](https://www.youtube.com/watch?v=y6120QOlsfU) | Darude - Sandstorm / Darude | 232288 | 5668314 | `3a760a259a7b7047e27f6fec592912777353df3052787252fa2c13478fb12853` | 31.064 |
| [dQw4w9WgXcQ](https://www.youtube.com/watch?v=dQw4w9WgXcQ) | Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster) / Rick Astley | 213050 | 5246952 | `1082d34f843744d4bd9e1216a4cf5d68eceab2f5d1a4014f8f9bf3c02f44f1cd` | 29.29 |
| [OPf0YbXqDm0](https://www.youtube.com/watch?v=OPf0YbXqDm0) | Mark Ronson - Uptown Funk (Official Video) ft. Bruno Mars / Mark Ronson | 270403 | 6774339 | `63f89687ec23bf38987cbd3ce21db931a2cb771187a0158b363a50b6c0561f62` | 31.565 |
| [RgKAFK5djSk](https://www.youtube.com/watch?v=RgKAFK5djSk) | Wiz Khalifa - See You Again ft. Charlie Puth [Official Video] Furious 7 Soundtrack / Wiz Khalifa | 237373 | 5642777 | `9f983a89605ab80c0f866eed603110620d279cf8cedb93781dec7dbdf5a1bff3` | 36.28 |
| [7cFkae0j_Ns](https://www.youtube.com/watch?v=7cFkae0j_Ns) | Scott Joplin - The Entertainer / chocotiger | 258909 | 6246620 | `c77db43fa590eb0b3cb673e5bd2cf61c50afe809939a23af400a2b17c5563f44` | 28.385 |
| [ND2rMET4MVw](https://www.youtube.com/watch?v=ND2rMET4MVw) | Scott Joplin - The Entertainer (1916) / the1920sand30s | 199803 | 4832771 | `a1ce80b3807f632019ca76186cedf4964b3dcc32c9c82bce6bd4305b053e29ff` | 28.833 |

### Playlist pequena

[Piano Scales](https://www.youtube.com/playlist?list=PLfx1ds3x7RKI), do canal Piano with Willy, retornou cinco itens na execução. A contagem da busca pública era anterior; a enumeração real é a usada no relatório. **1/1 playlist resolvida e 5/5 itens transferidos e validados na ordem**, todos novos e completos, primeira chamada 100%, após recuperação 100%, sem cache, falhas ou exclusões. A execução começou em `2026-11-25T22:19:45.107607+00:00` e terminou em `2026-11-25T22:21:54.021854+00:00`.

| Vídeo público | Título / canal | Duração (ms) | Bytes | SHA-256 do M4A final | Tempo da chamada (s) |
| --- | --- | ---: | ---: | --- | ---: |
| [CzBe1ClZvB8](https://www.youtube.com/watch?v=CzBe1ClZvB8) | E melodic minor scale \| Two octave \| HS \| 80 bpm / Piano with Willy | 33095 | 795905 | `c3e6bc65bb4aa29ae5d3b1a584eadb38f814680763412ab3d1a0214eb5cd8c7a` | 19.283 |
| [zQFZsLsat6s](https://www.youtube.com/watch?v=zQFZsLsat6s) | D melodic minor scale \| Two octave \| HS \| 80 bpm / Piano with Willy | 30100 | 724756 | `5af1af0687a8464a05ccb02d7371f649a4d8eecb8637c08c144f355929688c8b` | 22.505 |
| [kNNE3WAZ-v0](https://www.youtube.com/watch?v=kNNE3WAZ-v0) | E harmonic minor scale \| Two octaves \| Hands separate \| @ 80bpm / Piano with Willy | 29984 | 724441 | `c1c9ef193cf652356f300ff477f69c65097b01f8b9b2c6a6e0db248bb2317251` | 19.44 |
| [KZThtt0L2_Q](https://www.youtube.com/watch?v=KZThtt0L2_Q) | C Major Scale - Formula Pattern / Piano with Willy | 28591 | 686818 | `fe4803ca48ee1d1246a521defdf59a423ce301672bc516bdeb137fb3ffd67a32` | 19.983 |
| [gvMt4qHK7-c](https://www.youtube.com/watch?v=gvMt4qHK7-c) | Have you practiced your piano scales today? / Piano with Willy | 37484 | 901032 | `696bd15015c2a1b41ef1129e59e1041680a574fa0e15df978c7b5560af17a5e4` | 19.73 |

As duas campanhas somam **15/15 vídeos musicais distintos elegíveis completos**, primeira chamada 15/15 e após recuperação 15/15, zero falhas e zero cache. O vídeo falado diagnóstico não faz parte desse número. A segunda transferência de Keyboard Cat na amostra principal foi nova, mas seu baseline anterior não foi somado como outro vídeo distinto. O ID histórico [`BaW_jenozKc`](https://www.youtube.com/watch?v=BaW_jenozKc) é uma exclusão separada por indisponibilidade confirmada antes da transferência, não uma falha apagada da amostra. Não houve vídeo inicialmente elegível retirado por falha transitória.

Ledgers reproduzíveis: `/home/dev/piano-tiles-youtube/.runtime/youtube-validation/principal/attempts.json` e `/home/dev/piano-tiles-youtube/.runtime/youtube-validation/playlist/attempts.json`. Cada um preserva as URLs, a versão, a configuração, o horário, o resultado e o caminho local de cada arquivo. Uma rechecagem independente de hash, bytes, AAC/MP4 e duração coincidiu para os quinze arquivos finais. O ledger inicial não reconhecia a vírgula na primeira linha de `deno --version` e registrou esse campo como não identificado; o comando independente confirmou 2.9.8 e o parser foi corrigido antes da playlist, cujo ledger mostra a versão completa. Nenhum resultado de transferência foi alterado por isso.

O comando exato da playlist foi:

```sh
PYTHONPATH=backend/src /home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv/bin/python \
  backend/tools/validate_youtube_downloads.py \
  --urls-file /home/dev/piano-tiles-youtube/.runtime/youtube-validation/empty-urls.json \
  --playlist 'https://www.youtube.com/playlist?list=PLfx1ds3x7RKI' \
  --output-dir /home/dev/piano-tiles-youtube/.runtime/youtube-validation/playlist \
  --js-runtime deno:/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno \
  --label playlist-default-clients-nightly --gap-seconds 5
```

A playlist histórica [JODA15](https://www.youtube.com/playlist?list=PL6IaIsEjSbf96XFRuNccS_RuEXwNdsoEu) foi apenas enumerada durante a seleção (quatro referências), sem transferências. A escolha final favoreceu exercícios de piano curtos e públicos. Nenhum vídeo da lista exploratória foi contado como download.


## TDD e verificações locais

A interface pública definida no contrato foi a fronteira dos testes. A CLI substituta foi usada somente nos testes locais de falhas previsíveis; FFmpeg e ffprobe reais verificam conversão, ausência de áudio e completude. Esses testes não contam como acesso ao YouTube.

- Primeiro red: importação falhou porque o módulo ainda não existia. O slice de URLs e canonicalização passou com 9 testes.
- Playlist explícita e `max+1`: 2 falhas por comportamento ainda ausente; após implementação, 11 testes passaram.
- Erros estruturados e timeout: 4 falhas significativas; após implementação, 16 testes passaram.
- Transferência/preparação: 10 falhas por método ausente; após implementação, 26 testes passaram. Incluem privado sem subprocesso, duração ausente/infinita/excessiva, lives, mídia sem áudio, conversão falha, arquivo truncado e M4A com tamanho/hash reais.
- Teste do harness confirma que falha inicial seguida de recuperação mantém um único vídeo no denominador, primeira tentativa 0/1 e recuperação 1/1, e uma URL alternativa para o mesmo vídeo reutiliza o cache sem aumentar a taxa de transferências novas. Foi necessário corrigir o stub para não confundir a consulta `--version` com a primeira consulta de metadados.
- Resultado final: 27 testes locais passaram; Ruff e `git diff --check` passaram. Nenhum teste exige conectividade de rede.

```sh
PYTHONPATH=backend/src /home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv/bin/python \
  -m pytest backend/tests/test_downloader.py -q
uvx ruff check backend/src/echotiles_backend/downloader.py \
  backend/tests/test_downloader.py backend/tools/validate_youtube_downloads.py
git diff --check
```

## Limites da conclusão

A amostra é pequena, de conveniência e executada uma vez neste host/IP/data. Reúne música pop, rock, eletrônica, piano e um trecho musical curto; não mede uma população aleatória do catálogo nem estabilidade futura. A consulta do guia oficial e a presença de Deno/EJS não garantem aceitação de todo vídeo ou IP. Não houve medição de indetectabilidade.

A primeira tentativa de cada vídeo pode conter os retries internos finitos do yt-dlp. “Após recuperação” se refere a chamadas externas adicionais; uma transferência do cache nunca é contada como nova. Não houve investigação de privados, membros, restrições etárias, DRM, regiões ou vídeos acima do limite como se fossem downloads públicos elegíveis.

A conversão AAC pode alterar amostras e qualidade acústica; conserva a gravação integral e usa o mesmo arquivo final para mapa e reprodução. Nenhuma mídia de teste ou cache entra no APK/repositório por esta tarefa. A disponibilidade pública de uma URL não comprova licença para redistribuição.
