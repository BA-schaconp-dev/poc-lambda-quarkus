####
# Imagen de contenedor para AWS Lambda (Quarkus + quarkus-amazon-lambda-rest)
#
# Este es EL Dockerfile del servicio y vive en la RAIZ del repositorio, misma
# convencion que ECS y Batch. Los src/main/docker/Dockerfile.* que genera
# Quarkus por defecto no se usan.
#
# El modo lo decide el ARG NATIVE, que llega como --build-arg:
#
#   NATIVE=true   -> compila con -Pnative, imagen sobre provided.al2023.
#                    Arranque en frio ~200-400 ms, 256 MB alcanzan.
#   NATIVE=false  -> compila JVM, imagen sobre la base de Lambda para Java.
#                    Arranque en frio ~3 s, usar 1024 MB.
#
# Quien pasa ese --build-arg:
#   - el pipeline, desde el parametro `native` del orquestador
#     (.pipelines/templates/java-aws-lambda/stages/stage-podman-build-push-lambda.yml)
#   - ./aws/build-lambda-image.sh para el build local
#
# Build local (WSL/podman), sin pipeline:
#   ./aws/build-lambda-image.sh              # native
#   NATIVE=false ./aws/build-lambda-image.sh # JVM
#
# Prueba local con el Runtime Interface Emulator que trae la imagen base:
#   podman run --rm -p 9000:8080 poc-quarkus-hello:local
#   curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" \
#        -d @aws/event-apigw-rest-v1.json
#
# En red corporativa sin salida a los registros publicos, apunta las bases
# al mirror interno sin editar este archivo:
#   --build-arg BUILDER_IMAGE=<mirror>/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-21
#   --build-arg RUNTIME_IMAGE_NATIVE=<mirror>/lambda/provided:al2023
####

# ARG global (antes del primer FROM) para poder usarlo en el FROM final.
ARG NATIVE=true

ARG BUILDER_IMAGE=quay.io/quarkus/ubi9-quarkus-mandrel-builder-image:jdk-21
ARG RUNTIME_IMAGE_NATIVE=public.ecr.aws/lambda/provided:al2023
ARG RUNTIME_IMAGE_JVM=public.ecr.aws/lambda/java:21

# ---------------------------------------------------------------------
# Etapa 1: compilar (native o JVM segun NATIVE)
# ---------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS build

# Re-declarado para traer el ARG global al scope de esta etapa.
# JAVA_VERSION, APP_NAME y MAVEN_* se declaran solo para consumir los
# --build-arg que envia el pipeline sin que podman los reporte como no usados.
ARG NATIVE
ARG JAVA_VERSION=21
ARG APP_NAME=rest-service
ARG MAVEN_USERNAME
ARG MAVEN_PASSWORD

USER root
WORKDIR /code

COPY mvnw ./mvnw
COPY .mvn ./.mvn
COPY pom.xml ./
COPY src ./src
RUN chmod +x ./mvnw && chown -R quarkus:quarkus /code

USER quarkus

# NOTA: aqui habia un paso previo
#   RUN ./mvnw -B -ntp dependency:go-offline || true
# para precalentar una capa de dependencias. Se quito a proposito:
#
#   1. El pipeline construye con --no-cache, asi que esa capa NUNCA se
#      reutiliza: solo lograba descargar todo dos veces.
#   2. El "|| true" lo volvia una garantia vacia: si fallaba, se ignoraba.
#   3. Con Quarkus no resuelve las dependencias de la fase de augmentation,
#      asi que el package siguiente descargaba mas de todos modos.
#
# Efecto secundario util: dejaba de verse como un cuelgue. Con un ~/.m2 vacio
# ese paso tardaba varios minutos resolviendo la extension quarkus-maven-plugin
# y el quarkus-bom, y como lleva -ntp (sin progreso de descarga) parecia
# congelado en "Scanning for projects...".
#
# Si algun dia se quiere cachear dependencias de verdad, el goal correcto es
# 'quarkus:go-offline' (si contempla la augmentation), y sin "|| true" para que
# un fallo se vea. Para iterar en local conviene mas montar el ~/.m2 del host.

# container-build=false porque YA estamos dentro de la imagen builder:
# native-image corre aqui mismo, no hay que lanzar otro contenedor.
#
# Ambas ramas dejan el resultado en /code/out para que las etapas de
# runtime copien siempre desde la misma ruta.
#
# El -ntp mantiene el log del pipeline legible, pero oculta el progreso de
# descarga: si un build parece congelado, quitarlo para ver si esta bajando
# dependencias o realmente esta detenido.
# MAVEN_OPTS acota el heap de la JVM de Maven.
#
# Sin esto la JVM de Maven toma su default: 1/4 de la RAM del contenedor, o
# sea ~935MB en un agente de 3.74GB. Y esa JVM NO se libera mientras corre
# native-image: lo forkea y se queda esperando. Sumado al techo de
# native-image, el sistema quedaba al 95% y el agente reportaba
# "Free memory is lower than 5%".
#
# 768m alcanza para la fase de augmentation de Quarkus en esta app. Si algun
# dia da OutOfMemoryError antes de llegar a native-image, subirlo aqui.
RUN set -e; \
  mkdir -p /code/out; \
  if [ "$NATIVE" = "true" ]; then \
  echo ">> Compilando NATIVE (-Pnative)"; \
  MAVEN_OPTS="-Xmx768m" ./mvnw -B package -Pnative -DskipTests \
  -Dquarkus.native.container-build=false; \
  BIN="$(ls target/*-runner 2>/dev/null | head -n1)"; \
  if [ -z "$BIN" ]; then \
  echo "ERROR: no se genero el binario nativo target/*-runner"; \
  ls -la target; exit 1; \
  fi; \
  file "$BIN" || true; \
  cp "$BIN" /code/out/bootstrap; \
  chmod 755 /code/out/bootstrap; \
  else \
  echo ">> Compilando JVM"; \
  ./mvnw -B package -DskipTests; \
  if [ ! -f target/function.zip ]; then \
  echo "ERROR: no se genero target/function.zip"; \
  ls -la target; exit 1; \
  fi; \
  cd /code/out && jar xf /code/target/function.zip; \
  fi

# ---------------------------------------------------------------------
# Etapa 2a: runtime NATIVE  (se selecciona con NATIVE=true)
# ---------------------------------------------------------------------
# provided:al2023 trae el Lambda Runtime API y un entrypoint que ejecuta
# /var/runtime/bootstrap. No lleva JVM: solo corre nuestro binario.
FROM ${RUNTIME_IMAGE_NATIVE} AS runtime-true

# Parches del sistema operativo de la imagen base.
#
# Va ANTES del COPY del binario: primero base, despues parches, despues la
# aplicacion. Es el orden convencional de capas.
#
# POR QUE --releasever=latest, Y NO UN 'dnf update' PELADO:
#   Las imagenes base de Lambda apuntan a un snapshot CONGELADO de los repos
#   de Amazon Linux 2023. Un 'dnf -y update' normal responde "Nothing to do"
#   aunque el parche exista: no lo ve porque no esta en ese snapshot.
#   Verificado contra la base: sin --releasever el openssl se queda en
#   3.5.7-2.amzn2023.0.1; con --releasever=latest sube a .0.2, que es la
#   version que cierra CVE-2026-14456.
#
# POR QUE UN UPDATE COMPLETO Y NO PAQUETES POR NOMBRE:
#   Medido en las dos bases: actualiza 4 paquetes, sin instalar ni quitar
#   ninguno (89 paquetes antes y despues). El delta es minimo y evita tener
#   que editar este archivo en cada CVE nuevo del sistema operativo.
#
# NADA DE --setopt AQUI: el /usr/bin/dnf de estas imagenes es en realidad
#   microdnf, que implementa un subconjunto de dnf y rechaza --setopt
#   ("Invalid boolean value"). Por eso tampoco se usa 'dnf clean all' y se
#   limpia la cache con rm -rf.
#
# CONTRAPARTIDA: dos builds del mismo commit pueden dar imagenes distintas.
# Es la misma no-reproducibilidad que ya introduce --pull=always, y el tag de
# la imagen propia sigue siendo inmutable.
RUN dnf -y --releasever=latest update \
 && rm -rf /var/cache/dnf /var/cache/yum /var/cache/libdnf5

# Quarkus native debe ceder el manejo de senales al runtime de Lambda.
ENV DISABLE_SIGNAL_HANDLERS=true

COPY --from=build /code/out/bootstrap /var/runtime/bootstrap
RUN chmod 755 /var/runtime/bootstrap

# Con runtime `provided` el handler no se usa: el binario es el runtime.
CMD ["not.used.in.provided.runtime"]

# ---------------------------------------------------------------------
# Etapa 2b: runtime JVM  (se selecciona con NATIVE=false)
# ---------------------------------------------------------------------
FROM ${RUNTIME_IMAGE_JVM} AS runtime-false

# Mismos parches del SO que en la etapa nativa. Ver el comentario de
# runtime-true para el detalle del por que.
RUN dnf -y --releasever=latest update \
 && rm -rf /var/cache/dnf /var/cache/yum /var/cache/libdnf5

# Contenido de target/function.zip: clases en la raiz + dependencias en lib/,
# que es el layout que espera /var/task en la base de Lambda para Java.
COPY --from=build /code/out/ ${LAMBDA_TASK_ROOT}/

CMD ["io.quarkus.amazon.lambda.runtime.QuarkusStreamHandler::handleRequest"]

# ---------------------------------------------------------------------
# Etapa final: resuelve a runtime-true o runtime-false
# ---------------------------------------------------------------------
FROM runtime-${NATIVE} AS final
