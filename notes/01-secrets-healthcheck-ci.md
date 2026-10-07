---
title: "01 — Секреты, healthcheck, настоящий CI"
date: 2026-10-03
project: training_docker_postgresql_fastapi
tags:
  - devops
  - docker
  - docker-compose
  - github-actions
  - ci
  - yaml
  - postgresql
  - git
---

# 01 — Секреты, healthcheck, настоящий CI

> [!abstract] Что сделали за сессию
> 1. Убрали пароль из кода → переменные окружения + `.env`
> 2. Добавили healthcheck для **db** и **app** + эндпоинт `/health`
> 3. Переписали CI: теперь он **реально проверяет** API и падает, если что-то сломано
> 4. Разобрали 3 реальные поломки (не было коммита, неверный секрет, `connection reset`)

Связанные темы: [[YAML синтаксис]] · [[Docker Compose]] · [[GitHub Actions]] · [[Git основы]] · [[Linux права доступа]]

---

## 1. Было → стало (кратко)

| Что | Было | Стало | Зачем |
|---|---|---|---|
| Пароль БД | в `main.py`: `password="12345"` | в `.env`, читается через `os.environ` | секреты не должны лежать в коде и в git |
| Подключение к БД | 4 одинаковых `psycopg.connect(...)` | одна функция `get_conn()` | DRY: меняем в одном месте |
| Ожидание базы | `depends_on: - db` | `depends_on` + `condition: service_healthy` | app стартует, когда БД **готова**, а не просто запущена |
| Проверка готовности | нет | `healthcheck` у db и app, эндпоинт `/health` | «контейнер запущен» ≠ «сервис готов» |
| Ожидание в CI | `sleep 10` | `docker compose up --wait` | ждём ровно столько, сколько нужно |
| Тест в CI | `curl http://127.0.0.1:8080` (без `-f`) | 5 проверок с `curl -f` + негативный тест на 404 | старый тест **всегда был зелёным** |
| Лишнее в CI | установка Python и `pip install` | убрано | всё ставится внутри Docker-образа |
| Отладка CI | нет | `docker compose logs` при падении | видно причину ошибки |

---

## 2. Секреты: `.env`, `.env.example`, `.gitignore`

### Три файла и их роли

| Файл | Что внутри | В git? |
|---|---|---|
| `.env` | настоящие значения (пароль) | ❌ **никогда** |
| `.env.example` | шаблон с `change_me` | ✅ да, чтобы все знали, какие переменные нужны |
| `.gitignore` | список того, что git должен игнорировать | ✅ да |

```dotenv
# .env.example
POSTGRES_USER=runner
POSTGRES_PASSWORD=change_me
POSTGRES_DB=project_db
```

```gitignore
# .gitignore
.env
venv/
__pycache__/
.vscode/
```

> [!tip] Как проверить, что файл игнорируется
> ```bash
> git check-ignore -v .env
> # .gitignore:1:.env   .env   ← значит, игнорируется правилом из строки 1
> ```

> [!warning] Если секрет уже попал в git
> Удалить файл новым коммитом **недостаточно**: пароль остаётся в истории. Его надо **сменить**.

### Как значения из `.env` попадают в контейнеры

```
.env  ──(compose читает автоматически)──▶  ${POSTGRES_PASSWORD} в docker-compose.yml
                                              │
                                              ▼
                              environment: контейнера app и db
                                              │
                                              ▼
                      os.environ["POSTGRES_PASSWORD"] в main.py
```

Проверить, что подставилось, можно так: `docker compose config` покажет итоговый конфиг с уже подставленными значениями.

### `main.py`: функция `get_conn()`

```python
def get_conn():
    return psycopg.connect(
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        host=db_host,      # "db" — имя сервиса в compose = DNS-имя в docker-сети
        port=5432,
    )
```

- `os.environ["X"]` **падает** (`KeyError`), если переменной нет. Это хорошо: сразу видно, что забыли передать.
- `os.getenv("X", "default")` вернёт значение по умолчанию. Мы используем его для `DB_HOST`, потому что `localhost` — разумный дефолт.

> [!info] Почему `host=db`
> Docker Compose создаёт сеть, в которой каждый сервис доступен **по имени сервиса**. Внутри сети работает встроенный DNS Docker: `db` → IP контейнера с Postgres.

---

## 3. Healthcheck и `/health`

> [!important] Главная идея
> **«Контейнер запущен» ≠ «сервис готов».** Postgres стартует несколько секунд, uvicorn тоже. Healthcheck — это команда, которую Docker периодически запускает **внутри** контейнера: код выхода `0` = здоров, не `0` = нет.

### Статусы контейнера

```
starting ──(healthcheck прошёл)──▶ healthy
    └────(retries раз подряд не прошёл)──▶ unhealthy
```

### Эндпоинт `/health` в `main.py`

```python
@app.get("/health", tags=["health"])
def health():
    try:
        with get_conn() as conn:
            conn.execute("SELECT 1")          # самый лёгкий запрос к БД
    except psycopg.OperationalError:
        raise HTTPException(status_code=503, detail="db unavailable")
    return {"status": "ok"}
```

- `200 {"status":"ok"}`: приложение живо **и** база отвечает.
- `503 Service Unavailable`: приложение живо, но база недоступна.

### Цепочка запуска

```
db:  starting → healthy           (pg_isready)
        │ depends_on: condition: service_healthy
        ▼
app: starting → healthy           (GET /health → 200)
        │ docker compose up --wait дождался
        ▼
CI:  curl-тесты
```

> [!example] В Kubernetes это то же самое
> - `readinessProbe`: готов ли под принимать трафик (наш `/health`)
> - `livenessProbe`: жив ли под (если нет, k8s его перезапустит)

---

## 4. Синтаксис YAML (основа для compose и Actions)

> [!note] YAML = данные, записанные отступами
> YAML описывает 3 вещи: **словари** (ключ: значение), **списки** (`- элемент`) и **скаляры** (строки, числа, true/false).

### 4.1 Отступы

- Вложенность задаётся **только пробелами** (обычно 2). **Табы запрещены.**
- Одинаковый отступ = один уровень.

```yaml
services:          # уровень 0
  app:             # уровень 1 — внутри services
    build: .       # уровень 2 — внутри app
```

> [!danger] Самая частая ошибка
> Сдвинул строку на 1 пробел, и она «переехала» в другой блок или YAML не парсится. Если CI пишет `yaml: line X: mapping values are not allowed`, ищи отступы.

### 4.2 Словарь (map): `ключ: значение`

```yaml
container_name: fast_api_app     # пробел после двоеточия обязателен
environment:
  DB_HOST: db
  POSTGRES_DB: project_db
```

### 4.3 Список (list): `- элемент`

```yaml
ports:
  - "8080:8000"        # список из одной строки

networks:
  - app_network
```

Список **словарей** — так устроены `steps` в Actions:

```yaml
steps:
  - name: Checkout              # «-» начинает новый элемент списка (новый шаг)
    uses: actions/checkout@v4   # тот же элемент, просто второй ключ
  - name: Start containers      # следующий шаг
    run: docker compose up -d
```

> [!tip] Как читать `- name:`
> `-` значит «новый элемент списка», а всё, что ниже с тем же отступом, что и `name`, принадлежит **этому же** элементу.

### 4.4 Инлайн-формы (как в JSON)

```yaml
test: ["CMD", "pg_isready"]       # список в одну строку
labels: {env: dev, team: ops}     # словарь в одну строку
```

### 4.5 Строки и кавычки

```yaml
a: hello            # строка без кавычек — ок
b: "8080:8000"      # кавычки нужны! без них 8080:8000 может прочитаться не как строка
c: "yes"            # без кавычек yes/no/on/off могут стать true/false
d: '{"name":"x"}'   # одинарные кавычки — всё внутри как есть
```

> [!warning] Правило
> Порты, версии (`"3.12"`, иначе YAML прочтёт `3.10` как число `3.1`), строки с `:`, `{`, `#`, `*` всегда бери в кавычки.

### 4.6 Многострочный текст `|`

```yaml
run: |
  echo "строка 1"
  echo "строка 2"
```

`|` значит «дальше многострочный текст, переносы строк сохраняются». Каждая строка — отдельная bash-команда.

### 4.7 Комментарии

```yaml
# это комментарий
build: .   # и это тоже
```

### 4.8 Подстановки: кто их обрабатывает

| Запись | Где | Кто подставляет |
|---|---|---|
| `${POSTGRES_USER}` | docker-compose.yml | **Docker Compose**, из `.env` |
| `$${POSTGRES_USER}` | docker-compose.yml | `$$` → `$`: compose **не трогает**, переменную раскрывает shell **внутри контейнера** |
| `${{ secrets.ENV_FILE }}` | GitHub Actions | **GitHub**, до запуска шага |
| `$ENV_FILE` | внутри `run:` | **bash** на раннере |

> [!info] Зачем `$$` в healthcheck db
> `pg_isready -U $${POSTGRES_USER}` — нам нужно, чтобы переменная раскрылась **внутри контейнера** Postgres (там она есть), а не при чтении compose-файла.

---

## 5. `docker-compose.yml` построчно

```yaml
services:                       # словарь сервисов (контейнеров)
  app:
    build: .                    # собрать образ из Dockerfile в текущей папке
    container_name: fast_api_app
    ports:
      - "8080:8000"             # ХОСТ:КОНТЕЙНЕР — localhost:8080 → порт 8000 внутри
    environment:                # переменные окружения внутри контейнера
      DB_HOST: db
      POSTGRES_USER: ${POSTGRES_USER}           # значение из .env
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}

    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 5s              # проверять каждые 5 секунд
      timeout: 3s               # дольше 3 с — считается провалом
      retries: 10               # 10 провалов подряд → unhealthy
      start_period: 5s          # первые 5 с провалы не считаются (время на старт)

    depends_on:
      db:
        condition: service_healthy   # ждать, пока db станет healthy
    networks:
      - app_network

  db:
    image: postgres:17          # готовый образ с Docker Hub, версия зафиксирована
    container_name: container_postgres_db
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pg_data:/var/lib/postgresql/data   # ИМЯ_VOLUME:ПУТЬ_В_КОНТЕЙНЕРЕ — данные переживут удаление контейнера
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 10
    networks:
      - app_network

networks:
  app_network:
    driver: bridge              # обычная изолированная сеть на одном хосте

volumes:
  pg_data:                      # именованный volume, Docker хранит его сам
```

### `CMD` vs `CMD-SHELL` в healthcheck

| Форма | Как запускается | Когда использовать |
|---|---|---|
| `["CMD", "python", "-c", "..."]` | напрямую, **без shell** | переменные `$X` не нужны |
| `["CMD-SHELL", "pg_isready -U $${X}"]` | через `/bin/sh -c` | нужны переменные, `&&`, `\|` |

> [!question] Почему healthcheck app через Python, а не curl?
> В образе `python:3.12-slim` **нет curl**. А Python там есть точно.

### `postgres:17`, а не `postgres:latest`

> [!danger] Не используй `latest` для баз данных
> - `latest` — **движущаяся метка**: сегодня это 18, завтра 19. После `docker compose pull` мажорная версия поменяется молча, и старые данные не прочитаются без `pg_upgrade`.
> - У Postgres 18 изменился путь данных: маунт `/var/lib/postgresql/data` от 17-й версии с ним **не работает**.
> - Правило для прода: **всегда фиксируй версию** образа.

```bash
docker images              # посмотреть скачанные образы
docker rmi postgres:latest # удалить ненужный
```

### Ловушка с паролем и volume

> [!warning] Postgres берёт `POSTGRES_PASSWORD` только при **первой** инициализации
> Если volume `pg_data` уже существует со старым паролем, новый пароль из `.env` **проигнорируется**, и будет ошибка `password authentication failed`.
> ```bash
> docker compose down -v    # -v удаляет volumes (данные пропадут!)
> docker compose up -d --build
> ```

---

## 6. GitHub Actions: `tests.yml` построчно

### Структура любого workflow

```
workflow (файл .yml)
└── on: событие-триггер
└── jobs:
    └── job (отдельная виртуалка)
        └── steps: (по порядку)
            ├── uses: готовое действие
            └── run:  команды bash
```

### Весь файл с объяснениями

```yaml
name: test                      # имя workflow во вкладке Actions
on: push                        # запускать при каждом git push

jobs:                           # словарь задач (могут идти параллельно)
  api_test:                     # id задачи, придумываем сами
    runs-on: ubuntu-latest      # на какой виртуалке GitHub запускать
    steps:                      # СПИСОК шагов, выполняются сверху вниз
      - name: Checkout
        uses: actions/checkout@v4   # готовое действие: скачать код репозитория

      - name: Create .env
        env:                                    # переменные окружения для ЭТОГО шага
          ENV_FILE: ${{ secrets.ENV_FILE }}     # GitHub подставит секрет
        run: |
          if [ -z "$ENV_FILE" ]; then           # -z = строка пустая?
            echo "::error::Secret ENV_FILE is empty or missing"
            exit 1                              # код ≠ 0 → шаг красный
          fi
          printf '%s\n' "$ENV_FILE" > .env      # записать секрет в файл .env

      - name: Start containers
        run: docker compose up -d --build --wait

      - name: Create task
        run: |
          curl -f --retry 10 --retry-connrefused --retry-delay 2 \
            -X POST http://127.0.0.1:8080/app/task \
            -H "Content-Type: application/json" \
            -d '{"name":"ci_test","status":"new"}'

      - name: Get all tasks
        run: curl -f http://127.0.0.1:8080/app/tasks

      - name: Get task by id
        run: curl -f http://127.0.0.1:8080/app/task/1

      - name: Delete task
        run: curl -f -X DELETE http://127.0.0.1:8080/app/task/1

      - name: Deleted task returns 404
        run: |
          code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/app/task/1)
          echo "HTTP $code"
          test "$code" = "404"                  # не 404 → код 1 → шаг красный

      - name: Show logs on failure
        if: failure()                           # только если что-то упало выше
        run: docker compose logs

      - name: Stop containers
        if: always()                            # всегда, даже после ошибки
        run: docker compose down -v
```

### Ключи Actions

| Ключ | Что значит |
|---|---|
| `name` | человеческое имя (workflow или шага) |
| `on` | триггер: `push`, `pull_request`, `workflow_dispatch` (кнопка вручную), `schedule` (cron) |
| `jobs` | задачи; каждая на **своей чистой виртуалке** |
| `runs-on` | ОС раннера |
| `steps` | список шагов |
| `uses` | взять готовое действие из маркетплейса (`автор/репо@версия`) |
| `with` | параметры для `uses` |
| `run` | выполнить bash-команды |
| `env` | переменные окружения |
| `if` | условие запуска шага |

### Условия `if`

| Условие | Когда шаг выполнится |
|---|---|
| (нет `if`) | только если все предыдущие шаги успешны |
| `if: failure()` | только если что-то **упало** |
| `if: always()` | **всегда**: для уборки (cleanup) |
| `if: success()` | то же, что по умолчанию |

### Секреты: почему через `env:`, а не прямо в команду

```yaml
# ❌ плохо — GitHub вставит текст прямо в bash-скрипт
run: echo "${{ secrets.ENV_FILE }}" > .env

# ✅ хорошо — значение придёт как переменная, bash его не «исполнит»
env:
  ENV_FILE: ${{ secrets.ENV_FILE }}
run: printf '%s\n' "$ENV_FILE" > .env
```

Если в секрете будут кавычки, `$` или `` ` ``, первый вариант сломает команду (или выполнит лишнее).

> [!warning] Особенности секретов GitHub
> - Несуществующий секрет = **пустая строка**, без ошибки. Поэтому мы добавили проверку `if [ -z ... ]`.
> - Значение после сохранения посмотреть нельзя, только перезаписать.
> - В логах секреты заменяются на `***`.
> - **Secrets ≠ Variables**: `secrets.X` не видит то, что лежит во вкладке Variables.
> - Repository secrets работают сразу; Environment secrets — только если в job указан `environment:`.

---

## 7. Флаги curl и коды выхода

> [!important] Как CI понимает «успех / провал»
> Каждая команда в Linux завершается с **кодом выхода**: `0` — успех, всё остальное — ошибка. Шаг с кодом ≠ 0 → красный → весь workflow падает.
> ```bash
> echo $?   # показать код выхода последней команды
> ```

| Флаг | Что делает |
|---|---|
| `-f` | HTTP 4xx/5xx → **ошибка** (код 22). Без него curl доволен любым ответом |
| `-s` | тихий режим: без прогресс-бара |
| `-o /dev/null` | тело ответа выкинуть |
| `-w "%{http_code}"` | вывести только HTTP-код |
| `-X POST` / `-X DELETE` | HTTP-метод |
| `-H "..."` | заголовок |
| `-d '...'` | тело запроса |
| `--retry N` | повторить до N раз при временной ошибке |
| `--retry-connrefused` | считать «connection refused» временной ошибкой |
| `--retry-delay 2` | пауза между попытками |
| `-v` | подробный вывод (для отладки: видно DNS, TCP, заголовки) |

| Код curl | Значение |
|---|---|
| `0` | успех |
| `7` | не удалось подключиться (connection refused) |
| `22` | HTTP-ошибка при `-f` |
| `56` | ошибка получения данных (connection reset by peer) |

`\` в конце строки значит «команда продолжается на следующей строке».

---

## 8. Поломки, которые мы чинили (дебаг-истории)

> [!bug] №1. `git push` — «ноль реакции»
> **Симптом:** push ничего не отправляет, пишет `Everything up-to-date`.
> **Причина:** сделан `git add`, но **не сделан `git commit`**. Push отправляет только коммиты.
> **Как увидеть:** `git status` → `Changes to be committed`, `git log` → последний коммит совпадает с `origin/main`.
> ```
> рабочая папка ─git add─▶ staging ─git commit─▶ локальная история ─git push─▶ GitHub
> ```

> [!bug] №2. `container_postgres_db exited (1)`
> **Симптом:** Postgres падает сразу при старте в CI.
> **Причина:** создан один секрет `SECRESTS`, а workflow искал три других (`POSTGRES_USER` и т.д.). Несуществующий секрет = пустая строка → пустой пароль → Postgres отказывается инициализироваться.
> **Решение:** один секрет `ENV_FILE` со всем содержимым `.env` + проверка на пустоту.
> **Вывод:** **падай рано и с понятным сообщением** (fail fast).

> [!bug] №3. `curl: (56) Recv failure: Connection reset by peer`
> **Симптом:** Postgres работает, а первый запрос к API обрывается.
> **Причина:** `--wait` ждал, пока контейнер app **запустится**, но uvicorn внутри ещё не слушал порт. docker-proxy принял соединение на 8080, а передать его было некуда → reset.
> **Решение:** healthcheck у app + `/health` → `--wait` ждёт **готовности**.
> **Вывод:** «запущен» ≠ «готов».

> [!bug] Бонус. `permission denied ... /var/run/docker.sock`
> **Причина:** сокет Docker принадлежит `root:docker` с правами `rw-rw----`. Пользователь не в группе `docker`.
> ```bash
> ls -l /var/run/docker.sock      # srw-rw---- root docker
> id                              # в каких группах я состою
> sudo usermod -aG docker $USER   # добавить себя в группу
> newgrp docker                   # применить без перелогина
> ```
> Это и есть **права доступа в Linux** из вакансии: владелец / группа / остальные.

> [!bug] Старый баг. Тест, который не умел падать
> `curl http://127.0.0.1:8080` → маршрута `/` нет → 404 → но без `-f` curl вернул `0` → CI зелёный.
> **Вывод:** хороший тест надо **проверить на провал**: сломай специально (например, `/app/task/999`) и убедись, что CI красный.

---

## 9. Шпаргалка команд

```bash
# Docker Compose
docker compose up -d --build --wait   # собрать, запустить в фоне, дождаться healthy
docker compose ps                     # статусы (healthy / unhealthy)
docker compose logs app               # логи одного сервиса
docker compose logs -f                # логи в реальном времени
docker compose config                 # итоговый конфиг с подставленными переменными
docker compose down                   # остановить и удалить контейнеры
docker compose down -v                # + удалить volumes (ДАННЫЕ ПРОПАДУТ)

# Docker
docker images                         # список образов
docker rmi postgres:latest            # удалить образ
docker inspect --format '{{.State.Health.Status}}' fast_api_app   # статус healthcheck

# Проверка API
curl -f http://127.0.0.1:8080/health
curl -f -X POST http://127.0.0.1:8080/app/task \
  -H "Content-Type: application/json" -d '{"name":"test","status":"new"}'
curl -f http://127.0.0.1:8080/app/tasks

# Git
git status                            # что изменено / добавлено
git add <файл>                        # в staging
git commit -m "сообщение"             # зафиксировать
git push                              # отправить на GitHub
git log --oneline -5                  # последние коммиты
git check-ignore -v .env              # игнорируется ли файл
```

---

## 10. Вопросы для самопроверки (собеседование)

- [ ] Почему пароли нельзя хранить в коде и в git? Что делать, если пароль уже попал в историю?
- [ ] Чем отличаются `.env` и `.env.example`?
- [ ] Что такое healthcheck? Чем «контейнер запущен» отличается от «сервис готов»?
- [ ] Что делает `depends_on: condition: service_healthy`?
- [ ] Как связаны healthcheck в Docker и `readinessProbe` / `livenessProbe` в Kubernetes?
- [ ] Почему для БД нельзя использовать тег `latest`?
- [ ] Что такое volume и зачем он Postgres? Что делает `down -v`?
- [ ] Как сервис `app` находит сервис `db` по имени? (DNS в docker-сети)
- [ ] Что значит `"8080:8000"` в `ports`?
- [ ] Как CI понимает, что шаг упал? (коды выхода)
- [ ] Зачем `curl -f`? Что было бы без него?
- [ ] Чем отличаются `if: failure()` и `if: always()`?
- [ ] Почему секрет лучше передавать через `env:`, а не `${{ }}` прямо в `run`?
- [ ] Почему `git push` может ничего не отправить?
- [ ] Почему был `permission denied` на `docker.sock` и как это починить?

---

## 11. Что дальше

- [ ] Проверить, что CI зелёный после последнего пуша
- [ ] Специально сломать тест и убедиться, что CI краснеет
- [ ] Bash-скрипты: `backup.sh` / `restore.sh` для Postgres (`pg_dump`)
- [ ] Сборка образа в CI и push в GHCR
- [ ] Продублировать pipeline в `.gitlab-ci.yml` (в вакансии GitLab CI)
- [ ] Kafka в compose → [[02 — Kafka]]
- [ ] Kubernetes: kind → манифесты → Helm → [[03 — Kubernetes]]
