# MySQL Emergency Recover

Скрипт: `mysql-emergency-recover.sh`

Назначение: быстро стабилизировать стек при проблемах с БД (без рестарта MySQL), затем вернуть нормальные runtime-параметры.

## Модель конфигурации

Все значения по умолчанию собраны в начале скрипта в блоке **Default configuration**.

Настраивать поведение можно двумя способами:
1. Изменить дефолты в заголовке скрипта.
2. Переопределить значения через переменные окружения при запуске.

Ключевые дефолты в заголовке:
- имена контейнеров (`mysql-clients`, `php-apache-clients`)
- hostname PHP-приложения (`php-apache-clients`)
- URL проверяемого сайта (`https://fineart-print.ru/`)
- временные таймауты и лимиты соединений
- значения для возврата в штатный режим

## Что делает скрипт (полный режим)

1. Проверяет базовые зависимости (`docker`, нужные контейнеры).
2. Показывает стартовый срез MySQL:
   - `wait_timeout`, `interactive_timeout`, `max_connections`
   - `Threads_connected`, `Threads_running`, `Max_used_connections`
   - топ по `processlist`
3. Ставит временные низкие таймауты:
   - `wait_timeout=30`
   - `interactive_timeout=30`
4. Убивает старые `Sleep`-сессии от источников PHP (hostname/имя контейнера/IP контейнера).
5. Временно поднимает `max_connections` (по умолчанию `700`).
6. Показывает срез MySQL после изменений.
7. Проверяет доступность сайта (ожидает HTTP `200` от целевого URL).
8. Возвращает штатные значения:
   - `wait_timeout=300`
   - `interactive_timeout=28800`
   - `max_connections=500`
9. Показывает финальный срез MySQL.

По умолчанию скрипт всегда выводит подробный debug-лог.

## Режим `--default`

`--default` выполняет только возврат штатных значений и завершает работу:
- `wait_timeout`
- `interactive_timeout`
- `max_connections`

Без HTTP-проверок и без аварийных шагов.

## Откуда берется пароль MySQL

Пароль читается из секрета внутри MySQL-контейнера:
- по умолчанию: `/run/secrets/MYSQL_ROOT_PASSWORD`
- контейнер: `mysql-clients`

## Параметры CLI

- `--default`
  Применить только restore-значения и завершить.
- `--site-url URL`
  Переопределить URL для HTTP-проверки.
- `--sleep-age-sec N`
  Убивать `Sleep`-сессии старше `N` секунд.
- `-h`, `--help`
  Показать справку.

## Переменные окружения (runtime override)

- `MYSQL_CONTAINER` (по умолчанию `mysql-clients`)
- `PHP_CONTAINER` (по умолчанию `php-apache-clients`)
- `PHP_HOSTNAME` (по умолчанию `php-apache-clients`)
- `MYSQL_USER` (по умолчанию `root`)
- `MYSQL_SECRET_PATH` (по умолчанию `/run/secrets/MYSQL_ROOT_PASSWORD`)
- `SITE_URL` (по умолчанию `https://fineart-print.ru/`)
- `TEMP_WAIT_TIMEOUT` (по умолчанию `30`)
- `TEMP_INTERACTIVE_TIMEOUT` (по умолчанию `30`)
- `TEMP_MAX_CONNECTIONS` (по умолчанию `700`)
- `RESTORE_WAIT_TIMEOUT` (по умолчанию `300`)
- `RESTORE_INTERACTIVE_TIMEOUT` (по умолчанию `28800`)
- `RESTORE_MAX_CONNECTIONS` (по умолчанию `500`)
- `SLEEP_AGE_SEC` (по умолчанию `60`)
- `CURL_ATTEMPTS` (по умолчанию `3`)
- `CURL_TIMEOUT_SEC` (по умолчанию `15`)

## Примеры запуска

Полное восстановление:
```bash
./mysql-emergency-recover.sh
```

Только вернуть штатные значения:
```bash
./mysql-emergency-recover.sh --default
```

С кастомным URL для проверки:
```bash
./mysql-emergency-recover.sh --site-url https://fineart-print.ru/
```

## Коды выхода

- `0` успех
- `2` ошибка скрипта/окружения

## Важно

- Скрипт меняет глобальные runtime-параметры MySQL через `SET GLOBAL`.
- Runtime-значения могут не сохраняться после рестарта MySQL-контейнера.
- Это инструмент аварийной стабилизации, а не исправление первопричины.
