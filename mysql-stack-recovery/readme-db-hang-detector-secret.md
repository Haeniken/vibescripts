# DB Hang Detector (secret)

Скрипт: `db-hang-detector-secret.sh`

Назначение: быстрый детект именно той аварии, которую вы ловили в проде:
1. Saturation Apache worker pool.
2. Признак проблем MySQL (медленный ответ/давление по коннектам/не отвечает).
3. Наличие `upstream timed out` в Nginx.

Срабатывание только по тройному подтверждению. Если подтверждены все 3 условия, скрипт завершаетcя с `exit 1`.

## Источник пароля MySQL

Скрипт читает пароль из секрета внутри MySQL-контейнера:
- контейнер: `mysql-clients`
- путь по умолчанию: `/run/secrets/MYSQL_ROOT_PASSWORD`

Fallback через файл на хосте тоже есть, но для вашего сценария с секретом он не обязателен.

## Логика проверок

1. Быстрый Apache-check.
2. Если Apache не насыщен и нет `--full`, ранний `exit 0`.
3. Короткий SQL-check MySQL (одним вызовом).
4. Если MySQL не подтверждает проблему и нет `--full`, ранний `exit 0`.
5. Проверка Nginx по логам за последнее окно времени.
6. Если все 3 шага «плохие», `exit 1`, иначе `exit 0`.

## Коды выхода

- `0` инцидент не подтвержден
- `1` инцидент подтвержден (тройное совпадение)
- `2` внутренняя ошибка скрипта

## Параметры CLI

- `--debug`
  Печатает детальные значения по каждому шагу.
- `--full`
  Прогоняет все шаги без раннего выхода.
- `-h`, `--help`
  Краткая справка.

## Переменные окружения

- `NGINX_CONTAINER` (по умолчанию `nginx-clients`)
- `PHP_CONTAINER` (по умолчанию `php-apache-clients`)
- `MYSQL_CONTAINER` (по умолчанию `mysql-clients`)
- `MYSQL_USER` (по умолчанию `root`)
- `MYSQL_SECRET_IN_CONTAINER` (по умолчанию `/run/secrets/MYSQL_ROOT_PASSWORD`)
- `DOCKER_TIMEOUT_SEC` (по умолчанию `6`)
- `MYSQL_TIMEOUT_SEC` (по умолчанию `3`)
- `LOCK_FILE` (по умолчанию `/tmp/db-hang-detector.lock`)
- `APACHE_SAT_PCT_THRESHOLD` (по умолчанию `95`)
- `APACHE_WORKERS_ABS_THRESHOLD` (по умолчанию `220`)
- `MYSQL_CONN_PCT_THRESHOLD` (по умолчанию `70`)
- `MYSQL_QUERY_MS_THRESHOLD` (по умолчанию `1200`)
- `NGINX_LOOKBACK_SEC` (по умолчанию `60`)
- `NGINX_TIMEOUTS_THRESHOLD` (по умолчанию `10`)

## Примеры запуска

Обычный режим (быстрый):
```bash
./db-hang-detector-secret.sh
```

Подробный вывод:
```bash
./db-hang-detector-secret.sh --debug
```

Принудительно все проверки:
```bash
./db-hang-detector-secret.sh --debug --full
```

## Пример для cron + Telegram

Проверка каждую минуту, отправка алерта только если подтвержден инцидент (`exit 1`):

```cron
* * * * * /opt/scriptsdb-hang-detector-secret.sh >/tmp/db-hang-detector.log 2>&1 || /opt/scriptstelegram-alert.sh --disaster "DB freeze pattern detected: Apache saturation + MySQL pressure + Nginx timeouts"
```

Если нужен debug в логе cron:

```cron
* * * * * /opt/scriptsdb-hang-detector-secret.sh --debug >/tmp/db-hang-detector.log 2>&1 || /opt/scriptstelegram-alert.sh --disaster "DB freeze pattern detected: Apache saturation + MySQL pressure + Nginx timeouts"
```

## Замечания

- Скрипт использует lock-файл (`flock`), чтобы не запускаться параллельно.
- Если lock уже занят, скрипт тихо выходит с `0`.
