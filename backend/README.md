# Servidor do EchoTiles

Biblioteca persistente, fila sequencial de importações do YouTube e mapas de ritmo
para o APK. O servidor roda em Linux/Umbrel sem interface gráfica. A API permanece
disponível enquanto um processo worker separado resolve fontes, baixa e analisa áudio.

Requer `uv`, Python 3.12 e os executáveis `ffmpeg` e `ffprobe` no PATH. O lock inclui
FastAPI, librosa 0.11.0 e os componentes oficiais do download validados neste servidor:
`yt-dlp==2026.11.24.232653.dev0` e `yt-dlp-ejs==0.8.0`. Para YouTube, configure também
um runtime JavaScript compatível; o ambiente validado usa Deno 2.9.8.

```bash
uv sync --project backend --python 3.12 --locked
export PIANO_JS_RUNTIME="deno:/home/dev/piano-tiles-youtube/.runtime/youtube-tools/bin/deno"
uv run --project backend echotiles-backend serve --host 0.0.0.0 --port 8765
```

`serve` supervisiona o processo HTTP e um único worker. O worker usa um lock
exclusivo por biblioteca e transações SQLite para reservar importações. O comando
`echotiles-backend worker` também está disponível para supervisão externa. Após
interrupção, o worker recupera itens em andamento e mantém as faixas já publicadas.
Não execute duas cópias de `serve` sobre a mesma biblioteca.

Configure no APK a origem HTTP do servidor na rede local, por exemplo
`http://192.168.1.10:8765`. `GET /api/health` retorna a versão do schema.
Os endpoints, estados e valores JSON são definidos no contrato
[`youtube-v1.md`](../docs/contracts/youtube-v1.md).

| Variável | Padrão | Uso |
| --- | --- | --- |
| `PIANO_DATA_DIR` | `~/.local/share/echotiles` | SQLite, mídia e staging persistentes |
| `PIANO_MAX_PLAYLIST_ITEMS` | `50` | Máximo de entradas, incluindo indisponíveis |
| `PIANO_MAX_DURATION_SECONDS` | `900` | Duração máxima por faixa |
| `PIANO_CACHE_LIMIT_BYTES` | `2147483648` | Quota compartilhada por mídia, mapas e staging |
| `PIANO_YT_DLP` | Python atual + `-m yt_dlp` | Comando local, separado em argumentos sem shell |
| `PIANO_JS_RUNTIME` | vazio | Runtime do yt-dlp, por exemplo `deno:/caminho/deno` |

Também é possível reutilizar o ambiente de ferramentas do servidor:

```bash
export PIANO_YT_DLP="/home/dev/piano-tiles-youtube/.runtime/youtube-tools/venv/bin/python -m yt_dlp"
```

Essas configurações são locais. O HTTP recebe apenas URL e escolha de vídeo/playlist.
Nenhum comando, flag, caminho de arquivo ou stderr é recebido ou publicado pela API.
Auto com vídeo e playlist no mesmo link escolhe o vídeo; `kind=playlist` escolhe a lista.

O download ocorre em diretório exclusivo e em processo isolado. O encerramento inclui
os descendentes comprovados, mesmo que yt-dlp/ffmpeg abram sessões próprias. A quota é verificada
durante transferência/conversão, a cada até 50 ms, e antes da publicação. Pode ocorrer
uma ultrapassagem transitória entre a escrita e a próxima sondagem; a operação é
interrompida e o staging é removido. A quota cobre o cache; o banco SQLite e seus
metadados são separados. Não há remoção automática de faixas íntegras para abrir espaço.

A faixa recebe `ready` somente após o áudio M4A e o mapa serem publicados juntos,
com hash, tamanho e duração correspondentes. A duração canônica é
`round(ffprobe format.duration * 1000)` do M4A final. Cache ausente ou corrompido é
invalidado e precisa ser baixado novamente. Playlists parciais conservam seus itens prontos.

`rhythm-v1` detecta ataques espectrais no playback completo com librosa, conserva
introduções e pausas, e usa quatro colunas determinísticas. O espaçamento entre grupos
de teclas é de pelo menos 180 ms, com taps e duplas seletivas de no máximo dois contatos.
O schema aceita holds válidos; o perfil atual gera taps. A estimativa de BPM é informativa.
Este protótipo não faz transcrição de notas e a qualidade do mapa varia com a gravação.

Testes locais sem acesso ao YouTube:

```bash
uv run --project backend pytest backend/tests -q
uv run --project backend ruff check backend/src backend/tests
uv run --project backend ruff format --check backend/src backend/tests
```

As fixtures de áudio são geradas em diretórios temporários. Os testes injetam o
downloader na interface pública; mídia, credenciais, caches e arquivos de execução
não pertencem ao Git. A instalação e execução mantêm a licença e os créditos do projeto.

Referências de implementação: [FileResponse e Range](https://fastapi.tiangolo.com/reference/responses/),
[detecção de ataques do librosa](https://librosa.org/doc/latest/generated/librosa.onset.onset_detect.html)
e [componentes EJS oficiais do yt-dlp](https://github.com/yt-dlp/yt-dlp/wiki/EJS).
