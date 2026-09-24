#!/usr/bin/env bash
#
# Construye (y opcionalmente publica) la imagen de contenedor de Lambda
# desde WSL, con el MISMO Dockerfile que usa el pipeline.
#
# Sirve para sembrar la primera imagen en ECR: una funcion Lambda de tipo
# Image no se puede crear si el repositorio esta vacio, y el pipeline valida
# que la funcion exista antes de desplegar. Es el arranque del huevo y la
# gallina.
#
# Uso:
#   ./aws/build-lambda-image.sh [TAG]
#
#   NATIVE=false ./aws/build-lambda-image.sh          # imagen JVM
#   PUSH=true ECR_ACCOUNT=123456789012 ./aws/build-lambda-image.sh v1
#
# Para usar el mirror interno en vez de los registros publicos:
#   BUILDER_IMAGE=<mirror>/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-21 \
#   RUNTIME_IMAGE_NATIVE=<mirror>/lambda/provided:al2023 \
#   ./aws/build-lambda-image.sh
#
set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-poc-quarkus-hello}"
TAG="${1:-local}"

# true  -> -Pnative, imagen sobre provided.al2023
# false -> JVM, imagen sobre la base de Lambda para Java
NATIVE="${NATIVE:-true}"

# Mismos nombres de ARG que declara el Dockerfile de la raiz. Antes este
# script pasaba RUNTIME_IMAGE (sin sufijo), que el Dockerfile no declara: el
# --build-arg se ignoraba en silencio y siempre se usaba la imagen por
# defecto.
BUILDER_IMAGE="${BUILDER_IMAGE:-quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-21}"
RUNTIME_IMAGE_NATIVE="${RUNTIME_IMAGE_NATIVE:-public.ecr.aws/lambda/provided:al2023}"
RUNTIME_IMAGE_JVM="${RUNTIME_IMAGE_JVM:-public.ecr.aws/lambda/java:21}"

# Publicacion opcional a ECR
PUSH="${PUSH:-true}"
ECR_ACCOUNT="${ECR_ACCOUNT:-641564158323}"
ECR_REGION="${ECR_REGION:-us-east-1}"

# Situarse en la raiz del proyecto sin importar desde donde se invoque
cd "$(dirname "$0")/.."

# El Dockerfile vive en la RAIZ del repositorio, misma convencion que ECS y
# Batch. Los src/main/docker/Dockerfile.* que genera Quarkus no se usan.
DOCKERFILE="Dockerfile"

echo "==> Configuracion"
echo "    Dockerfile : $DOCKERFILE"
echo "    Imagen     : ${IMAGE_NAME}:${TAG}"
echo "    NATIVE     : $NATIVE"
if [ "$NATIVE" = "true" ]; then
  echo "    Runtime    : $RUNTIME_IMAGE_NATIVE"
else
  echo "    Runtime    : $RUNTIME_IMAGE_JVM"
fi
echo "    Builder    : $BUILDER_IMAGE"

echo "==> Prerequisitos"
command -v podman >/dev/null 2>&1 || { echo "    ERROR: podman no esta instalado"; exit 1; }
echo "    podman: $(podman --version)"

if [ ! -f "$DOCKERFILE" ]; then
  echo "    ERROR: no existe '$DOCKERFILE' en $(pwd)"
  echo "    El Dockerfile debe estar en la raiz del repositorio."
  exit 1
fi
echo "    Dockerfile encontrado"

# Solo se comprueban los registros que esta corrida va a usar de verdad.
if [ "$NATIVE" = "true" ]; then
  RUNTIME_IN_USE="$RUNTIME_IMAGE_NATIVE"
else
  RUNTIME_IN_USE="$RUNTIME_IMAGE_JVM"
fi

echo "==> Salida hacia los registros de imagenes"
for reg in "${BUILDER_IMAGE%%/*}" "${RUNTIME_IN_USE%%/*}"; do
  if curl -s -o /dev/null -m 15 "https://${reg}/"; then
    echo "    ok: ${reg}"
  else
    echo "    ERROR: WSL no alcanza ${reg}"
    echo
    echo "    Opciones:"
    echo "      1. En PowerShell: wsl --shutdown   y reintentar"
    echo "      2. Apuntar BUILDER_IMAGE / RUNTIME_IMAGE_NATIVE al mirror interno"
    exit 1
  fi
done

if [ "$NATIVE" = "true" ]; then
  echo "==> Memoria (native-image necesita ~3 GB)"
  free -h | awk '/^Mem:/ {print "    disponible: " $7}'
fi

echo "==> Construyendo ${IMAGE_NAME}:${TAG} (varios minutos si NATIVE=true)"
# Se pasan los mismos --build-arg y --pull que el pipeline
# (.pipelines/templates/java-aws-lambda/stages/stage-podman-build-push-lambda.yml)
# para que el build local y el del pipeline sean equivalentes.
#
# --pull=always: OJO, --no-cache NO vuelve a bajar la imagen base. Desactiva
# la cache de capas, pero si provided:al2023 ya esta en el agente usa esa
# copia local, que puede tener meses. Los parches de seguridad del sistema
# operativo de la base solo entran con --pull.
podman build \
  --build-arg "NATIVE=${NATIVE}" \
  --build-arg "BUILDER_IMAGE=${BUILDER_IMAGE}" \
  --build-arg "RUNTIME_IMAGE_NATIVE=${RUNTIME_IMAGE_NATIVE}" \
  --build-arg "RUNTIME_IMAGE_JVM=${RUNTIME_IMAGE_JVM}" \
  --pull=always \
  -f "${DOCKERFILE}" \
  -t "${IMAGE_NAME}:${TAG}" \
  .

echo "==> Listo"
podman images --filter "reference=${IMAGE_NAME}:${TAG}" \
  --format "    {{.Repository}}:{{.Tag}}  {{.Size}}"

# ── Publicacion opcional a ECR ──────────────────────────────────
if [ "$PUSH" = "true" ]; then
  if [ -z "$ECR_ACCOUNT" ]; then
    echo
    echo "ERROR: PUSH=true requiere ECR_ACCOUNT=<account id del registry>"
    exit 1
  fi
  command -v aws >/dev/null 2>&1 || { echo "ERROR: aws cli no esta instalado"; exit 1; }

  ECR_URI="${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com/${IMAGE_NAME}"

  # ── Quien soy ────────────────────────────────────────────────
  # Primero la identidad: es el diagnostico mas barato y el que mas veces
  # explica un "no existe". WSL tiene su propia configuracion de aws cli,
  # separada de la de Windows, asi que puede estar sin credenciales o
  # apuntando a otra cuenta.
  echo
  echo "==> Identidad de AWS en WSL"
  set +e
  WHOAMI=$(aws sts get-caller-identity --output json 2>&1)
  WHOAMI_RC=$?
  set -e
  if [ $WHOAMI_RC -ne 0 ]; then
    echo "    ERROR: aws cli no pudo identificarse. AWS respondio:"
    echo "    $WHOAMI"
    echo
    echo "    Causas tipicas en WSL:"
    echo "      - no hay credenciales configuradas AQUI (son distintas de las de Windows)"
    echo "      - la sesion SSO expiro: 'aws sso login --profile <perfil>'"
    echo "      - falta exportar AWS_PROFILE"
    exit 1
  fi
  CALLER_ACCOUNT=$(echo "$WHOAMI" | grep -o '"Account"[^,]*' | cut -d'"' -f4)
  echo "    Cuenta : ${CALLER_ACCOUNT:-<no parseada>}"
  echo "    ARN    : $(echo "$WHOAMI" | grep -o '"Arn"[^,}]*' | cut -d'"' -f4)"
  if [ -n "$CALLER_ACCOUNT" ] && [ "$CALLER_ACCOUNT" != "$ECR_ACCOUNT" ]; then
    echo
    echo "    AVISO: estas autenticado en $CALLER_ACCOUNT pero ECR_ACCOUNT=$ECR_ACCOUNT."
    echo "    Si el repositorio vive en $ECR_ACCOUNT, hace falta acceso cross-account."
  fi

  # ── El repositorio ──────────────────────────────────────────
  # El script no crea el repositorio (es infraestructura), pero tampoco
  # asume que un fallo signifique "no existe": se muestra el error de AWS y
  # se traduce, porque las causas son muy distintas entre si.
  echo
  echo "==> Validando acceso al repositorio ECR"
  if [ "${SKIP_ECR_CHECK:-false}" = "true" ]; then
    echo "    SKIP_ECR_CHECK=true: se omite. El push dira si hay problema."
  else
    set +e
    ECR_OUT=$(aws ecr describe-repositories \
      --registry-id "$ECR_ACCOUNT" \
      --repository-names "$IMAGE_NAME" \
      --region "$ECR_REGION" \
      --query 'repositories[0].repositoryUri' --output text 2>&1)
    ECR_RC=$?
    set -e

    if [ $ECR_RC -eq 0 ]; then
      echo "    ok: $ECR_OUT"
    else
      echo "    No se pudo confirmar el repositorio. AWS respondio:"
      echo
      echo "      $ECR_OUT"
      echo
      case "$ECR_OUT" in
        *RepositoryNotFound*)
          echo "    DIAGNOSTICO: el repositorio '${IMAGE_NAME}' realmente no existe"
          echo "    en ${ECR_ACCOUNT}/${ECR_REGION}. Crealo antes de publicar"
          echo "    (ver aws/POC-LAMBDA-ECR.md paso 2). Revisa tambien que la"
          echo "    REGION sea la correcta: un repo con el mismo nombre en otra"
          echo "    region no cuenta."
          ;;
        *ExpiredToken*|*TokenRefreshRequired*)
          echo "    DIAGNOSTICO: las credenciales expiraron."
          echo "    Renova la sesion: aws sso login --profile <perfil>"
          ;;
        *"Unable to locate credentials"*|*NoCredential*)
          echo "    DIAGNOSTICO: aws cli en WSL no tiene credenciales."
          echo "    Son INDEPENDIENTES de las de Windows: WSL busca en ~/.aws"
          echo "    del usuario de Linux, no en el de Windows."
          echo
          echo "    Lo mas simple, sin duplicar credenciales en disco:"
          echo "      export AWS_CONFIG_FILE=/mnt/c/Users/\$USER/.aws/config"
          echo "      export AWS_SHARED_CREDENTIALS_FILE=/mnt/c/Users/\$USER/.aws/credentials"
          echo "      export AWS_PROFILE=<perfil de la cuenta ${ECR_ACCOUNT}>"
          echo
          echo "    Verifica con: aws sts get-caller-identity"
          ;;
        *AccessDenied*|*"not authorized"*|*UnrecognizedClient*|*InvalidClientTokenId*)
          echo "    DIAGNOSTICO: la identidad no tiene ecr:DescribeRepositories"
          echo "    sobre ese repositorio, o las llaves no son validas."
          echo
          echo "    OJO: describir y publicar son acciones DISTINTAS. Es posible"
          echo "    que SI puedas hacer push. Para saltar esta verificacion:"
          echo "      SKIP_ECR_CHECK=true PUSH=true ./aws/build-lambda-image.sh ${TAG}"
          ;;
        *)
          echo "    Revisa el error de arriba. Para saltar esta verificacion:"
          echo "      SKIP_ECR_CHECK=true PUSH=true ./aws/build-lambda-image.sh ${TAG}"
          ;;
      esac
      exit 1
    fi
  fi

  echo "==> Login a ECR (el token vale 12 horas)"
  aws ecr get-login-password --region "$ECR_REGION" \
    | podman login --username AWS --password-stdin "$ECR_URI"

  echo "==> Tag y push: ${ECR_URI}:${TAG}"
  podman tag "${IMAGE_NAME}:${TAG}" "${ECR_URI}:${TAG}"
  podman push "${ECR_URI}:${TAG}"

  echo
  echo "Imagen publicada: ${ECR_URI}:${TAG}"
  echo
  echo "RECORDATORIO: publicar NO despliega nada. La funcion cambia solo"
  echo "cuando corre update-function-code (lo hace el pipeline)."
  echo
  echo "Para crear la funcion por primera vez desde esta imagen:"
  echo "  aws lambda create-function \\"
  echo "    --function-name ${IMAGE_NAME}-img \\"
  echo "    --package-type Image \\"
  echo "    --code ImageUri=${ECR_URI}:${TAG} \\"
  echo "    --role arn:aws:iam::<cuenta-funcion>:role/<rol-ejecucion> \\"
  echo "    --architectures x86_64 --timeout 30 --memory-size 256 \\"
  echo "    --region ${ECR_REGION}"
  exit 0
fi

cat <<EOF

Probarla con el Runtime Interface Emulator que trae la imagen base:

  podman run --rm -p 9000:8080 ${IMAGE_NAME}:${TAG}

y en otra terminal:

  curl -sX POST "http://localhost:9000/2015-03-31/functions/function/invocations" \\
       -d @aws/event-apigw-rest-v1.json

Debe responder un AwsProxyResponse con "body":"Hello World".

Para publicarla en ECR:

  PUSH=true ECR_ACCOUNT=<account id> ./aws/build-lambda-image.sh ${TAG}
EOF
