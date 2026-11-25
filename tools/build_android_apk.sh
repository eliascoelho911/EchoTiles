#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf 'Erro: %s\n' "$*" >&2; exit 1; }
trap 'printf "Falha ao gerar ou validar o APK (linha %s).\n" "$LINENO" >&2' ERR

if [[ $# -gt 0 ]]; then
  [[ $# -eq 1 && $1 == --help ]] || fail 'Use --help para consultar a configuração.'
  cat <<'HELP'
Gera um APK release universal e valida assinatura, pacote e metadados.
Uso: tools/build_android_apk.sh
Variáveis opcionais:
  FLUTTER_BIN                    Executável flutter (ou use FLUTTER_ROOT/bin/flutter).
  ANDROID_SDK_ROOT / ANDROID_HOME Diretório do SDK Android.
  JAVA_HOME                      JDK compatível com Gradle.
  ANDROID_BUILD_TOOLS_VERSION     Versão instalada das build-tools.
  ECHOTILES_KEY_PROPERTIES        Arquivo privado de assinatura; prefira caminho absoluto.
  ECHOTILES_APK_OUTPUT_DIR        Saída (padrão: dist/ na raiz do projeto).
  ECHOTILES_BUILD_NAME            versionName opcional.
  ECHOTILES_BUILD_NUMBER          versionCode opcional.
  ECHOTILES_SERVER_URL            Origem inicial da API (permanece editável no app).
Sem key.properties, o release usa a chave debug local para este protótipo.
O script não instala nem abre o app em dispositivos.
HELP
  exit 0
fi

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"
[[ -f pubspec.lock ]] || fail 'pubspec.lock ausente; gere e revise as dependências antes do build.'

flutter_bin=${FLUTTER_BIN:-${FLUTTER_ROOT:+$FLUTTER_ROOT/bin/flutter}}
flutter_bin=${flutter_bin:-flutter}
command -v "$flutter_bin" >/dev/null || fail 'Flutter ausente. Configure FLUTTER_BIN ou FLUTTER_ROOT.'
flutter_bin=$(command -v "$flutter_bin")
export PATH="$(dirname -- "$flutter_bin"):$PATH"

android_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Android/Sdk}}
[[ -d "$android_sdk" ]] || fail 'SDK Android ausente. Configure ANDROID_SDK_ROOT.'
android_sdk=$(cd -- "$android_sdk" && pwd)
export ANDROID_HOME="$android_sdk" ANDROID_SDK_ROOT="$android_sdk"
if [[ -n ${JAVA_HOME:-} ]]; then
  [[ -x "$JAVA_HOME/bin/java" ]] || fail 'JAVA_HOME não contém bin/java executável.'
  export PATH="$JAVA_HOME/bin:$PATH"
fi
command -v java >/dev/null || fail 'Java ausente. Configure JAVA_HOME.'
command -v sha256sum >/dev/null || fail 'sha256sum é necessário para registrar o artefato.'

if [[ -n ${ANDROID_BUILD_TOOLS_VERSION:-} ]]; then
  build_tools="$android_sdk/build-tools/$ANDROID_BUILD_TOOLS_VERSION"
else
  build_tools=''
  while IFS= read -r tools_dir; do
    if [[ -x "$tools_dir/apksigner" && -x "$tools_dir/aapt" && -x "$tools_dir/zipalign" ]]; then
      build_tools=$tools_dir
      break
    fi
  done < <(find "$android_sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -Vr)
fi
for required_tool in apksigner aapt zipalign; do
  [[ -x "$build_tools/$required_tool" ]] || fail "build-tools incompletas: falta $required_tool."
done
apkanalyzer="$android_sdk/cmdline-tools/latest/bin/apkanalyzer"
[[ -x "$apkanalyzer" ]] || fail 'Instale cmdline-tools; falta latest/bin/apkanalyzer no SDK.'

if [[ -n ${ECHOTILES_KEY_PROPERTIES:-} ]]; then
  [[ -f "$ECHOTILES_KEY_PROPERTIES" ]] || fail 'ECHOTILES_KEY_PROPERTIES não aponta para um arquivo.'
  # Gradle resolve caminhos relativos a android/; normalize antes de executá-lo.
  ECHOTILES_KEY_PROPERTIES=$(cd -- "$(dirname -- "$ECHOTILES_KEY_PROPERTIES")" && pwd)/$(basename -- "$ECHOTILES_KEY_PROPERTIES")
  export ECHOTILES_KEY_PROPERTIES
fi
if [[ -n ${ECHOTILES_KEY_PROPERTIES:-} || -e "$project_dir/android/key.properties" ]]; then
  signing_mode='keystore privada configurada'
else
  signing_mode='debug Android local, somente protótipo'
fi
printf 'Assinatura: %s\n' "$signing_mode"

build_args=(build apk --release --no-pub)
if [[ -n ${ECHOTILES_SERVER_URL:-} ]]; then
  build_args+=("--dart-define=ECHOTILES_SERVER_URL=$ECHOTILES_SERVER_URL")
fi
if [[ -n ${ECHOTILES_BUILD_NAME:-} ]]; then
  build_args+=("--build-name=$ECHOTILES_BUILD_NAME")
fi
if [[ -n ${ECHOTILES_BUILD_NUMBER:-} ]]; then
  [[ $ECHOTILES_BUILD_NUMBER =~ ^[1-9][0-9]*$ ]] || fail 'ECHOTILES_BUILD_NUMBER deve ser um inteiro positivo.'
  build_args+=("--build-number=$ECHOTILES_BUILD_NUMBER")
fi

flutter_version=$("$flutter_bin" --version)
printf '%s\n' "$flutter_version"
"$flutter_bin" pub get --enforce-lockfile
"$flutter_bin" "${build_args[@]}"

built_apk="$project_dir/build/app/outputs/flutter-apk/app-release.apk"
[[ -s "$built_apk" ]] || fail 'Flutter concluiu sem gerar build/app/outputs/flutter-apk/app-release.apk.'
application_id=$("$apkanalyzer" manifest application-id "$built_apk")
[[ $application_id == com.sidhant.echotiles.youtubeprototype ]] || fail "applicationId inesperado: $application_id"
badging=$("$build_tools/aapt" dump badging "$built_apk")
[[ $badging == *"application-label:'EchoTiles YouTube'"* ]] || fail 'Rótulo do APK inesperado.'
[[ $badging == *"uses-permission: name='android.permission.INTERNET'"* ]] || fail 'APK sem permissão INTERNET.'
[[ $badging == *"sdkVersion:'24'"* ]] || fail 'minSdk inesperado; esperado API 24.'
native_code=$(printf '%s\n' "$badging" | sed -n '/^native-code:/p')
for abi in armeabi-v7a arm64-v8a x86_64; do
  [[ $native_code == *"'$abi'"* ]] || fail "APK universal sem a arquitetura $abi."
done

signature=$("$build_tools/apksigner" verify --verbose --print-certs "$built_apk")
"$build_tools/zipalign" -c -P 16 4 "$built_apk"

output_dir=${ECHOTILES_APK_OUTPUT_DIR:-$project_dir/dist}
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
output_apk="$output_dir/echotiles-youtube-prototype.apk"
cp -- "$built_apk" "$output_apk"
(
  cd "$output_dir"
  sha256sum echotiles-youtube-prototype.apk > echotiles-youtube-prototype.apk.sha256
)
{
  printf 'Validado em UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Commit: %s\n' "$(git rev-parse HEAD 2>/dev/null || printf 'sem Git')"
  if [[ -n $(git status --porcelain --untracked-files=no 2>/dev/null) ]]; then
    printf 'Fontes rastreadas com alterações locais: sim\n'
  else
    printf 'Fontes rastreadas com alterações locais: não\n'
  fi
  printf 'APK: %s\nBuild-tools: %s\nAssinatura: %s\n' "$output_apk" "$(basename -- "$build_tools")" "$signing_mode"
  printf '%s\n' "$flutter_version" "$badging" "$signature"
} > "$output_apk.validation.txt"
printf '\nAPK validado: %s\nSHA-256: %s\nMetadados: %s\n' \
  "$output_apk" "$output_apk.sha256" "$output_apk.validation.txt"
