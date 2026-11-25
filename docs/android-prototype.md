# EchoTiles YouTube no Android

O APK de protótipo usa `com.sidhant.echotiles.youtubeprototype`, aparece como **EchoTiles YouTube** e requer Android 7.0/API 24 ou posterior. A atividade e o namespace originais do EchoTiles são preservados. O aplicativo usa a API na rede local do servidor Umbrel; o telefone precisa alcançar esse servidor.

## Iniciar a API no servidor

Na raiz do repositório integrado:

```bash
uv run --project backend echotiles-backend serve --host 0.0.0.0 --port 8765
```

No APK, abra a biblioteca do YouTube e informe a origem do servidor, por exemplo `http://192.168.1.22:8765`, sem acrescentar `/api`. O endereço é editável no aplicativo: use o IP atual ou um nome DNS acessível pelo telefone. `localhost` e `127.0.0.1` no telefone apontam para o próprio telefone. Confira a conexão em `http://192.168.1.22:8765/api/health`: a resposta esperada contém `"status":"ok"` e `"schemaVersion":1`.

A API foi projetada para a LAN segura deste protótipo. Mantenha a porta 8765 acessível apenas à rede local. A permissão `INTERNET` está no manifesto principal e também vale para release.

O arquivo `android/app/src/main/res/xml/network_security_config.xml` permite HTTP para o endereço editável. Essa opção vale para qualquer destino HTTP usado pelo aplicativo; a configuração Android não limita faixas privadas por CIDR. Use somente a origem LAN esperada. HTTPS continua a validar certificados com as autoridades do sistema; não há aceite universal de certificados nem exceção TLS. Um servidor com certificado próprio precisa de configuração de confiança específica. [Referência Android sobre configuração de rede](https://developer.android.com/privacy-and-security/security-config).

## Gerar o APK integrado

Use o código final integrado das tarefas Android, Flutter e backend. Um APK compilado antes dessa integração serve apenas para validar o empacotamento e não é a entrega funcional do YouTube.

```bash
FLUTTER_ROOT=/home/dev/.local/opt/flutter-youtube-prototype/flutter \
ANDROID_SDK_ROOT=/home/dev/Android/Sdk \
JAVA_HOME=/home/dev/.sdkman/candidates/java/17.0.13-tem \
ECHOTILES_SERVER_URL=http://192.168.1.22:8765 \
tools/build_android_apk.sh
```

O script exige o lockfile revisado, executa `flutter pub get --enforce-lockfile` e produz um APK release universal para `armeabi-v7a`, `arm64-v8a` e `x86_64`. Ele verifica assinatura, alinhamento, applicationId, rótulo, permissão de rede e minSdk antes de copiar a saída para:

- `dist/echotiles-youtube-prototype.apk`: o APK efetivamente gerado pelo código atual.
- `dist/echotiles-youtube-prototype.apk.sha256`: hash para conferir a transferência.
- `dist/echotiles-youtube-prototype.apk.validation.txt`: commit, metadados e certificado usados nessa compilação.

Esses artefatos, o SDK, caches e keystores ficam fora do Git. O build usa por padrão heap Gradle de 2 GiB e dois workers, adequado ao home server compartilhado. Não é necessário limpar caches de outros projetos.

O empacotamento foi ajustado para Flutter 3.50.1/Dart 3.14.0, AGP 9.1.1, Gradle 9.3.1, Kotlin 2.4.0 e JDK 17. O patch do AGP corrige a versão 9.1.0 upstream rejeitada pelo Flutter; Gradle 9.3.1 é compatível com AGP 9.1.1. [Tabela oficial de compatibilidade](https://developer.android.com/build/releases/agp-9-1-0-release-notes).

`tools/build_android_apk.sh --help` lista as opções. `ECHOTILES_SERVER_URL` é opcional e vira `--dart-define=ECHOTILES_SERVER_URL=...` no build: define a origem inicial, que permanece editável no app. Nenhum IP fica fixo no script. `FLUTTER_BIN` pode apontar para outro executável Flutter compatível, `ANDROID_BUILD_TOOLS_VERSION` escolhe uma versão instalada, `ECHOTILES_APK_OUTPUT_DIR` muda a saída e `ECHOTILES_BUILD_NAME`/`ECHOTILES_BUILD_NUMBER` controlam a versão. O SDK Android deve ter `platform-tools`, `cmdline-tools/latest`, plataformas, build-tools e NDK exigidos pelo Flutter, com as licenças aceitas. A primeira compilação pode baixar dependências. [Referência Flutter para builds Android](https://docs.flutter.dev/deployment/android).

## Assinatura do protótipo

Sem `android/key.properties`, o release usa explicitamente a assinatura **debug local do Android**. Isso gera um APK instalável para teste, com o código release e o identificador exclusivo do protótipo. Não é uma assinatura de distribuição nem usa a chave privada do projeto upstream. Preserve a chave debug local se precisar atualizar a instalação com novos builds; outra máquina pode gerar um certificado diferente. O certificado e sua impressão SHA-256 aparecem no arquivo de validação. A mesma versão de ferramentas, lockfile e chave permitem repetir o processo; não se promete igualdade de bytes entre máquinas e horários.

Quando houver uma keystore legitimamente fornecida, mantenha-a fora do Git e configure `android/key.properties` ou `ECHOTILES_KEY_PROPERTIES` com um caminho absoluto para um arquivo privado contendo:

```properties
storeFile=/caminho/privado/assinatura.jks
storePassword=SENHA_PRIVADA
keyAlias=ALIAS_DA_CHAVE
keyPassword=SENHA_PRIVADA
```

Use um caminho absoluto em `storeFile`; o caminho relativo histórico continua sendo resolvido a partir de `android/app`. Restrinja o arquivo a seu usuário (`chmod 600`). O script não imprime essas propriedades. Arquivo informado inexistente, propriedades incompletas ou keystore inexistente causam erro claro, sem fallback silencioso. Nunca publique keystore, senhas ou o arquivo privado de propriedades. [Referência Android sobre assinatura e atualização](https://developer.android.com/studio/publish/app-signing).

## Instalar no telefone

Copie **o APK de `dist/` gerado depois da integração** para o telefone por um meio da sua escolha. Confira o SHA-256, abra o arquivo no Android e permita que o aplicativo de arquivos ou navegador escolhido instale apps dessa origem quando o sistema solicitar. Instale e abra **EchoTiles YouTube**, configure a origem LAN e confira a conexão antes de importar uma faixa ou playlist.

Se você já usa ADB e autorizar a instalação, execute manualmente na máquina que tem acesso ao telefone:

```bash
adb devices -l
adb install -r dist/echotiles-youtube-prototype.apk
```

Atualizações com `adb install -r` exigem o mesmo pacote e certificado. Se o certificado mudou, gere novamente com a chave anterior ou remova a instalação antiga por decisão própria, sabendo que isso apaga os dados locais. O identificador distinto permite coexistir com o EchoTiles original.

## Limites da validação

O build e as ferramentas Android validam o artefato sem instalar ou operar um telefone. A validação em aparelho ainda deve confirmar conectividade LAN, download/cache, reprodução do áudio completo, tela vertical de quatro colunas e sincronização das notas. Sem essa execução, latência de áudio, desempenho, comportamento do sistema e instalação física permanecem não verificados. O servidor deve permanecer disponível para novas importações; os limites e erros do YouTube são tratados pelo backend.
