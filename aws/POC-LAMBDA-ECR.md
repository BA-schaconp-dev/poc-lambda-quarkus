# POC: Lambda desde imagen de contenedor (Quarkus native + ECR)

Guía **paso a paso** para levantar la función a mano desde la consola de AWS, y recién
después habilitar el pipeline.

El objetivo no es solo que funcione: al hacerlo a mano queda claro qué recurso existe,
quién lo crea y en qué orden. Eso es justo lo que el pipeline **ya no hace** — solo
despliega código y valida que todo lo demás exista, así que lo que crees aquí es lo que
después debe provisionar IaC.

---

## Qué vamos a construir

```
cliente HTTP
     │
     ▼
API Gateway  REST API  "poc-quarkus-hello-api"
     │   recurso /{proxy+}  ·  método ANY  ·  Lambda proxy integration
     │   evento AwsProxyRequest (payload format 1.0)
     ▼
Lambda  "poc-quarkus-hello-img"   PackageType: Image
     │   alias "live" ──> versión publicada
     │   imagen descargada de ──▶ ECR "poc-quarkus-hello"
     │   sin Runtime ni Handler: el binario native ES el runtime
     ▼
GreetingResource  @Path("/hello")
     │
     ▼   AwsProxyResponse
respuesta al cliente
```

### Por qué imagen y no zip

| | Zip + S3 | Imagen + ECR |
|---|---|---|
| Runtime | `java21` gestionado | `provided.al2023` dentro de la imagen |
| Handler | `QuarkusStreamHandler::handleRequest` | No se usa: el binario **es** el runtime |
| Arranque en frío | ~3 s | ~200-400 ms |
| Memoria sugerida | 1024 MB | 256 MB |
| Límite de tamaño | 250 MB descomprimido | 10 GB |
| SnapStart | Disponible | No disponible |
| Etapas de pipeline | Nuevas | **Las que ya existen para ECS/Batch** |

Que SnapStart no aplique deja de importar: era una forma de tapar el arranque en frío de la
JVM, y con native no hay JVM.

> **`poc-quarkus-hello` (la función zip que ya tienes) no sirve para esto.** El
> `PackageType` de una función **no se puede cambiar** — nació `Zip` y se queda así. Por eso
> toda esta guía usa una función nueva, `poc-quarkus-hello-img`. Sirve además para comparar
> las dos lado a lado antes de decidir con cuál se queda el pipeline.

---

## Antes de empezar

Tené a mano:

| Dato | Cómo obtenerlo |
|---|---|
| `ACCOUNT_ID` | Consola → esquina superior derecha |
| `REGION` | `us-east-1` en este POC |
| Rol de ejecución | Ya lo tienes: `poc-quarkus-hello-lambda-role` |

Y en WSL: `podman` (ya lo tienes, 4.9.3) y `aws` cli con el perfil SSO de consban.

**El repositorio ECR y la función deben estar en la MISMA región.** Lambda no toma imágenes
de ECR de otra región, a diferencia de ECS/EKS.

---

## Paso 1 — Rol de ejecución (ya lo tienes, solo verificar)

Tu `poc-quarkus-hello-lambda-role` tiene esta policy de permisos, que es correcta y
suficiente:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
```

Es el equivalente de la managed `AWSLambdaBasicExecutionRole`. Con eso la función puede
escribir a CloudWatch Logs, que es todo lo que necesita este POC.

**Lo único que hay que verificar es la *trust policy*** (pestaña *Trust relationships*).
Debe permitir que el servicio Lambda asuma el rol:

**IAM → Roles → `poc-quarkus-hello-lambda-role` → Trust relationships → Edit trust policy**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLambdaAssumeRole",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Está en [`trust-policy-lambda.json`](trust-policy-lambda.json). Si ya funcionaba con la
función zip, ya la tiene bien.

> ### El rol de ejecución NO necesita permisos de ECR
>
> Es la confusión más común al pasar a imágenes. Quien descarga la imagen **no es el rol de
> ejecución: es el servicio Lambda** (`lambda.amazonaws.com`), antes de que la función
> arranque.
>
> - **Misma cuenta** (ECR y función en la misma): funciona sin configurar nada.
> - **Cuentas distintas**: hace falta una *repository policy* en el ECR. Es el §11.
>
> Agregarle `ecr:*` al rol de ejecución no arregla nada y da permisos de más.

---

## Paso 2 — Repositorio ECR

**Consola → ECR → Repositories → Create repository**

| Campo | Valor | Por qué |
|---|---|---|
| Visibility | `Private` | |
| Repository name | `poc-quarkus-hello` | Debe coincidir con `ecrRepo` del `azure-pipelines.yml` |
| Tag immutability | **Enabled** | Impide sobrescribir un tag ya publicado: lo que está en un tag hoy es lo mismo mañana |
| Scan on push | **Enabled** | Escaneo de vulnerabilidades en cada push |
| Encryption | AES-256 (default) | |

**Create repository**. Anotá el URI:

```
<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/poc-quarkus-hello
```

### Lifecycle policy

**Repository → Lifecycle policy → Create rule**: conservar las últimas 10 imágenes y
expirar el resto.

No es opcional en un repositorio que recibe **un push por commit**: sin esto cada commit
deja una imagen para siempre y el almacenamiento crece sin techo.

> El pipeline **valida** que este repositorio exista (`ecr:DescribeRepositories`) y falla
> con mensaje explícito si no está. No lo crea.

---

## Paso 3 — Construir la primera imagen y probarla local

Hace falta hacerlo a mano una vez: **una función `PackageType: Image` no se puede crear si
el repositorio está vacío**. De ahí en adelante lo hace el pipeline.

### 3.1 Construir

Desde WSL, en la raíz del repositorio:

```bash
TAG=1.0.0-$(git rev-parse --short HEAD)
./aws/build-lambda-image.sh "$TAG"
```

El script construye con **el mismo `Dockerfile` de la raíz y los mismos `--build-arg` que
el pipeline**, así el build local y el del pipeline son equivalentes. Valida antes de
empezar que exista el Dockerfile y que haya salida a los registros que necesita.

Tarda **varios minutos** y necesita **~3 GB de RAM libres**: `native-image` es glotón. Si
el equipo anda justo, `NATIVE=false ./aws/build-lambda-image.sh "$TAG"` construye la
variante JVM en una fracción del tiempo, para validar el resto del camino.

### 3.2 Probarla antes de subir nada

La imagen base de AWS trae el **Runtime Interface Emulator**, así que se puede ejercitar el
camino completo sin desplegar:

```bash
podman run --rm -p 9000:8080 poc-quarkus-hello:$TAG
```

En otra terminal:

```bash
curl -sX POST "http://localhost:9000/2015-03-31/functions/function/invocations" \
     -d @aws/event-apigw-rest-v1.json
```

Debe devolver un `AwsProxyResponse` con `"body":"Hello World"`.

**Si esto funciona, lo que falle después es configuración de AWS, no de la imagen.** Vale
mucho hacerlo: separa los dos tipos de problema.

### 3.3 Publicar a ECR

```bash
PUSH=true ECR_ACCOUNT=<ACCOUNT_ID> ./aws/build-lambda-image.sh "$TAG"
```

Hace login a ECR (el token vale 12 horas), valida que el repositorio exista, taguea y hace
push. Al terminar imprime el `aws lambda create-function` ya armado, por si preferís crear
la función por CLI en vez de consola.

Verificá en **ECR → `poc-quarkus-hello` → Images** que aparezca tu tag.

> **Usá un tag inmutable** (`1.0.0-<commit>`), nunca `latest`. Lambda resuelve el tag a un
> digest al momento de desplegar; con `latest` pierdes la trazabilidad de qué imagen está
> corriendo. El pipeline usa `$(Build.BuildNumber)`, que ya es inmutable.
>
> **La arquitectura debe coincidir** con la de la función. WSL es `x86_64`, así que la
> imagen sale `linux/amd64` y la función debe crearse `x86_64`. El pipeline **valida** esto
> y falla si no cuadra, en vez de cambiarlo.

---

## Paso 4 — Crear la función desde la imagen

**Consola → Lambda → Create function → Container image**

| Campo | Valor |
|---|---|
| Function name | `poc-quarkus-hello-img` |
| Container image URI | **Browse images** → repo `poc-quarkus-hello` → tu tag |
| Architecture | `x86_64` |
| Execution role | *Use an existing role* → `poc-quarkus-hello-lambda-role` |

**Create function**.

Fijate que **no hay campos de Runtime ni de Handler**. La imagen los reemplaza: el
`ENTRYPOINT`/`CMD` del Dockerfile define qué se ejecuta.

### 4.1 Memoria y timeout

**Configuration → General configuration → Edit**

| Campo | Valor |
|---|---|
| Memory | `1024 MB` |
| Timeout | `30 s` |

> **No bajes la memoria mirando solo `Max Memory Used`.** Es el error más fácil de cometer
> acá. En una medición real esta función usó **68 MB** con 256 MB asignados — parecería que
> sobra memoria de más. Pero **en Lambda la memoria es el único dial de CPU**:
>
> | Memoria | vCPU aprox. |
> |---|---|
> | 256 MB | ~0.14 |
> | 512 MB | ~0.29 |
> | 1024 MB | ~0.58 |
> | 1769 MB | 1.0 |
>
> Con 256 MB la función recibe **una séptima parte de un core**, y el arranque —que es puro
> CPU e I/O— no alcanza a terminar en el presupuesto de INIT. Ver §4.2.
>
> Como las invocaciones calientes son de ~2 ms, subir la memoria casi no mueve el costo en
> GB-ms; lo que mueve es el arranque en frío.

Estos dos valores los gobierna **IaC**, no el pipeline. El pipeline ya no los toca.

### 4.2 El presupuesto de INIT son 10 segundos

Lambda le da a la fase INIT un presupuesto **fijo de 10 s**, independiente del `Timeout` de
la función. Si no termina, **no falla**: re-ejecuta la inicialización dentro de la primera
invocación. En los logs se ve así:

```
INIT_REPORT Init Duration: 9999.21 ms Phase: init Status: timeout
... banner de Quarkus DESPUES del INIT_REPORT ...
rest-service 1.0.0-SNAPSHOT native ... started in 2.571s
REPORT ... Duration: 3432.75 ms ... Max Memory Used: 68 MB
```

El orden delata el problema: el banner aparece **después** del `INIT_REPORT`, o sea que ese
arranque de 2.5 s ocurrió ya dentro de la invocación, no en INIT. Y la primera request pagó
3.4 s en vez de los ~2 ms de una caliente.

Dos aclaraciones para leer bien ese log:

- **`Init Duration: 9999.21 ms` es el tope, no una medición.** No dice cuánto habría tardado
  el INIT: dice que se cortó a los 10 s.
- **Los 2.571 s son del segundo intento**, ya con las páginas del binario en caché. El
  primero fue peor.

### Por qué 2.5 s es anómalo para native

Un native de Quarkus con un `@Path` debería reportar `started in 0.0XXs`. Si ves segundos,
hay **dos sospechosos independientes** y conviene no confundirlos:

| Sospechoso | Síntoma | Cómo se ataca |
|---|---|---|
| **CPU insuficiente** | Todo lento de forma pareja | Subir memoria (§4.1) |
| **Stall de Netty / DNS** | `WARN [io.qua.net.run.NettyRecorder] ... took more than a second` | Evitar la resolución de hostname en el arranque |

El segundo es el patrón conocido de `DefaultChannelId`: en un contenedor donde el hostname
no está en `/etc/hosts`, `InetAddress.getLocalHost()` espera el timeout de DNS.
`quarkus-amazon-lambda-rest` arrastra Vert.x (aparece como `vertx` en
`Installed features`), así que Netty se inicializa siempre. **Más CPU no arregla un timeout
de red.**

Prueba para distinguirlos, en este orden:

1. Subir memoria a 1024 MB (un click, sin recompilar).
2. Forzar un **segundo** arranque en frío (§4.3).
3. Mirar el `started in` y si el `WARN` de Netty sigue.

| Resultado | Conclusión |
|---|---|
| `started in ~0.1-0.3s`, sin WARN | Era CPU |
| `started in ~1.5-2.5s`, con WARN | Es Netty/DNS |

### 4.3 Cómo medir el arranque en frío de verdad

El primer arranque tras el deploy es el **peor caso posible**: Lambda además está
materializando y optimizando la imagen por primera vez. Los arranques en frío siguientes
reutilizan esa imagen optimizada y son notablemente más rápidos.

Para un número representativo, forzá un **segundo** arranque en frío: cambiá cualquier valor
de configuración (eso recicla el entorno de ejecución) o esperá ~15 minutos, y volvé a
invocar. Ese `Init Duration` es el que sirve para comparar native vs JVM.

> **SnapStart no está disponible para funciones de imagen.** Si el arranque en frío tiene
> que desaparecer del todo, la única vía es *provisioned concurrency*, que se paga de forma
> continua. Es decisión de costo, no técnica: vale plantearla con el área dueña.

---

## Paso 5 — Publicar versión y crear el alias

Este paso es **obligatorio** para que el pipeline funcione: el pipeline **mueve** el alias,
no lo crea, y falla con mensaje explícito si no existe.

### 5.1 Publicar una versión

**Función → Actions → Publish new version** → descripción `inicial` → **Publish**.

Queda la versión `1`.

### 5.2 Crear el alias

**Función → Aliases → Create alias**

| Campo | Valor |
|---|---|
| Name | `live` |
| Version | `1` |

**Create**.

> **Un alias no puede apuntar a `$LATEST`.** AWS solo permite versiones numeradas, y por eso
> hay que publicar la versión antes. Es también la razón de que el pipeline exija
> `publishVersion: true` cuando se configura un `aliasName`.

El alias es el **punto de rollback instantáneo**: si un despliegue sale mal, se reapunta a
la versión anterior sin recompilar nada.

---

## Paso 6 — Probar la función sola, sin API Gateway

**Función → Test → Create new event**

- Event name: `apigw-rest-hello`
- Pega el contenido de [`event-apigw-rest-v1.json`](event-apigw-rest-v1.json)

**Test**. Debe responder algo así:

```json
{
  "statusCode": 200,
  "body": "Hello World",
  "isBase64Encoded": false
}
```

Mirá **`Init Duration`** en el resumen de la ejecución. Con native el objetivo son
**200-400 ms**, pero **no esperes verlo en la primera invocación**: la primera paga la
materialización de la imagen y puede terminar en `Status: timeout`. Medí sobre un segundo
arranque en frío (§4.3) antes de sacar conclusiones.

La otra métrica que importa es la **invocación caliente**: con native debería quedar en
~2 ms. Si la caliente está bien y solo el arranque está mal, el problema es de
inicialización (§4.2), no de la aplicación.

Si falla acá, el problema es la función o la imagen — no el API Gateway. Ver §11.

---

## Paso 7 — API Gateway

### 7.1 Crear el API (si no existe)

**API Gateway → Create API → REST API → Build**

| Campo | Valor |
|---|---|
| API name | `poc-quarkus-hello-api` |
| Endpoint type | Regional |

> **REST API, no HTTP API.** La extensión `quarkus-amazon-lambda-rest` espera eventos
> `AwsProxyRequest`, o sea *payload format 1.0*. HTTP API manda formato 2.0 y la app no lo
> entiende. Si algún día se migra a HTTP API, hay que cambiar la dependencia del `pom.xml` a
> `quarkus-amazon-lambda-http`.

### 7.2 Recurso proxy

**Resources → Create resource**

- **Proxy resource**: activado
- Resource path: `/`
- Resource name: `{proxy+}`

Queda el recurso `/{proxy+}`, que captura cualquier ruta y la pasa tal cual a la aplicación.
Así los `@Path` de Quarkus siguen funcionando sin declarar cada endpoint en el API.

### 7.3 Método ANY con integración Lambda proxy

**Sobre `/{proxy+}` → Create method**

| Campo | Valor |
|---|---|
| Method type | `ANY` |
| Integration type | `Lambda` |
| **Lambda proxy integration** | **Activado** |
| Lambda function | `poc-quarkus-hello-img:live` |

**Create method** y aceptá el diálogo del permiso de invocación.

> **Apuntá al alias, no a la función pelada.** Si escribís solo
> `poc-quarkus-hello-img`, API Gateway invoca `$LATEST` y **mover el alias no cambia nada** —
> el pipeline desplegaría y no verías diferencia. Con `:live` estás ejercitando exactamente
> lo que el pipeline modifica.
>
> El permiso de invocación es **por función y por qualifier**: el que otorgaste a otra
> función (o a la misma sin alias) no cubre este.

### 7.4 Desplegar el stage

**Deploy API**

| Campo | Valor |
|---|---|
| Stage | *New stage* → `poc` |

**Deploy**. Anotá el **Invoke URL**.

> Cada vez que cambies **la configuración del API** (recursos, métodos, integración) hay que
> volver a desplegar el stage. Cuando solo cambia el **código de la Lambda**, no: el API
> apunta al alias y el alias se reapunta solo.

---

## Paso 8 — Probar end-to-end

```powershell
Invoke-RestMethod "https://<API_ID>.execute-api.us-east-1.amazonaws.com/poc/hello"
# -> Hello World

Invoke-RestMethod "https://<API_ID>.execute-api.us-east-1.amazonaws.com/poc/hello/Atlantida"
# -> Hello Atlantida
```

Con esto el POC está levantado a mano y completo.

---

## Paso 9 — Logs

**CloudWatch → Log groups → `/aws/lambda/poc-quarkus-hello-img`**

Qué mirar en el `REPORT` de cada invocación:

| Campo | Para qué |
|---|---|
| `Init Duration` | Arranque en frío. Es la métrica que compara native vs JVM |
| `Duration` | Ejecución ya caliente |
| `Max Memory Used` | Para calibrar los 256 MB |

El log group lo crea la función en su primera invocación, gracias al `logs:CreateLogGroup`
del rol.

---

## Paso 10 — Habilitar el pipeline

Con todo lo anterior en su lugar, el pipeline ya solo tiene que desplegar.

### 10.1 Rol que asume el pipeline

Creá (o ajustá) el rol de despliegue con
[`policy-pipeline-deploy-ecr.json`](policy-pipeline-deploy-ecr.json), reemplazando
`ACCOUNT_ID_REGISTRY` y `ACCOUNT_ID_FUNCION`.

Su ARN va en el variable group que indique `pushVariableGroup` / el de cada ambiente.

> Ojo con `ecr:GetAuthorizationToken`: es la única acción que **obliga** a `Resource: "*"`,
> porque el token de autenticación es de cuenta, no de repositorio. No es un descuido.

### 10.2 Confirmar el `azure-pipelines.yml`

Que estos valores correspondan a lo que acabás de crear:

```yaml
    deployTarget: ecr
    ecrRepo: "poc-quarkus-hello"
    ecrVariableGroup: "hnd-bco-consban-registry-dev-ecr-vars"
    environments:
      dev:
        functionName: "poc-quarkus-hello-img"   # NO "poc-quarkus-hello"
        architecture: x86_64
        publishVersion: true
        aliasName: "live"
```

### 10.3 Qué hace y qué no hace el pipeline

| Etapa | Equivalente manual de esta guía | Dónde vive |
|---|---|---|
| Build + tests | `./mvnw clean package` | `stage-build-lambda.yml` |
| Quality Gate | — | `stage-quality-gate-lambda.yml` |
| Build imagen | §3.1 | `stage-podman-build-push-lambda.yml` |
| Escaneo Trivy | — | mismo stage, **bloqueante**, antes del push |
| Login + push ECR | §3.3 | mismo stage |
| **Deploy** | `update-function-code --image-uri` | `step-deploy-lambda.yml` |
| Publicar versión | §5.1 | mismo step |
| Mover el alias | §5.2 (solo lo mueve) | mismo step |
| Smoke test | §8 | **No lo hace**: los agentes no alcanzan todas las VPCs. Queda en QA |

Y **valida, sin modificar**: que la función exista, que sea `PackageType: Image`, que la
arquitectura coincida, que esté `Active`, que el alias exista y que el repositorio ECR
exista. Si algo falta, falla listando **todos** los problemas de una vez, no solo el
primero.

Cuatro cosas que conviene tener claras:

1. **Publicar la imagen no despliega nada.** Lambda resuelve el tag a un digest solo cuando
   corre `update-function-code`. Si el pipeline hace push y no llama a Lambda, la función
   sigue sirviendo la imagen anterior.
2. **El gate de Trivy es bloqueante y corre antes del push.** Si la imagen tiene
   vulnerabilidades Critical/High, no llega a ECR ni se despliega: la función queda con la
   imagen anterior, sin estado a medias.
3. **La build de native necesita ~3 GB** (`quarkus.native.native-image-xmx=3g`, en el perfil
   `native` del `pom.xml`). Verificá que los agentes tengan esa memoria, o la build muere con
   un OOM difícil de leer.
4. **El pipeline no configura la función.** Memoria, timeout, variables de entorno,
   repositorio y alias son de IaC. Solo cambia código, versión y alias.

---

## Paso 11 — Si algo falla

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| Al crear la función: no aparece la imagen en *Browse images* | El push no llegó, o el repo está en otra región | Verificar en ECR → Images, y que la región coincida |
| `Lambda does not have permission to access the ECR image` | ECR en **otra cuenta** que la función | Agregar la *repository policy* (abajo) |
| `exec format error` al invocar | Arquitectura de la imagen ≠ de la función | Recrear la función como `x86_64`, o construir para la otra arquitectura |
| Timeout en la primera invocación | Arranque en frío + timeout muy corto | Subir el timeout a 30 s y reintentar |
| `INIT_REPORT ... Status: timeout` | El arranque no cabe en el presupuesto fijo de 10 s de INIT | No es un fallo: Lambda re-inicializa dentro de la primera invocación. Ver §4.2 para separar CPU de stall de Netty |
| `started in Xs` con X en segundos, siendo native | CPU insuficiente, o stall de Netty resolviendo el hostname | §4.2 tiene la prueba que distingue las dos |
| `502 Bad Gateway` desde API Gateway | *Lambda proxy integration* desactivado, o la app no devuelve `AwsProxyResponse` | Verificar el check de proxy integration; probar la función sola (§6) |
| El API responde pero no ves el cambio tras desplegar | La integración apunta a la función pelada (`$LATEST`), no al alias | Reapuntar a `poc-quarkus-hello-img:live` y redesplegar el stage |
| El pipeline falla con `PackageType='Zip'` | `functionName` apunta a la función vieja | Corregir a `poc-quarkus-hello-img` |

### Repository policy del ECR (solo cross-account)

Si el ECR vive en una cuenta distinta a la de la función, hay que **agregar** un statement a
la repository policy del repositorio:

**ECR → `poc-quarkus-hello` → Permissions → Edit policy JSON**

El statement está en
[`ecr-repository-policy-lambda.json`](ecr-repository-policy-lambda.json). Se **suma** al
arreglo `Statement` existente, no lo reemplaza.

Este es el requisito que más sorprende, y **no basta con que la cuenta ya tenga acceso al
repositorio**: las policies que ya existen para ECS/EKS otorgan acceso a principals IAM
(`arn:aws:iam::<cuenta>:root`, o los *task execution roles*), y esos **no cubren al service
principal** `lambda.amazonaws.com`. Por eso ECS funciona y Lambda no.

Es exactamente el bloqueo que hizo falta rodear con `deployTarget: s3` en el registry
centralizado, y la razón de que este POC use un ECR propio.

---

## Paso 12 — Limpieza

En este orden:

1. **API Gateway** → borrar el API `poc-quarkus-hello-api`, o devolver la integración a la
   función zip
2. **Lambda** → `poc-quarkus-hello-img` → *Delete* (borra también sus versiones y alias)
3. **CloudWatch** → log group `/aws/lambda/poc-quarkus-hello-img` → *Delete*
4. **ECR** → borrar las imágenes y después el repositorio
5. **IAM** → el rol de ejecución se comparte con la función zip: borralo solo al final

---

## Antes de llevarlo a un ambiente real

- **Scan on push** va a reportar hallazgos de la imagen base. Con native la superficie es
  chica, pero `provided.al2023` igual trae paquetes del sistema. El pipeline ya bloquea con
  Trivy en Critical/High; vale confirmar ese umbral con **Seguridad** y definir cómo se
  tramita una excepción cuando una vulnerabilidad no tiene fix.
- **Tag immutability + lifecycle policy** no son opcionales con un push por commit: sin lo
  primero pierdes trazabilidad, sin lo segundo el costo crece sin techo.
- **La identidad del pipeline** sigue pendiente de definir (OIDC federado vs usuario IAM con
  llaves). Con ECR de por medio pesa más, porque ese pipeline va a poder publicar imágenes
  en un registro compartido. Es conversación con **Seguridad/Arquitectura**.
- **Todo lo que creaste a mano en esta guía debe pasar a IaC** antes de QA o producción. El
  pipeline está escrito asumiendo que existe: valida y falla, no aprovisiona. Lo que hoy es
  un click en la consola tiene que ser un recurso de Terraform con dueño.
