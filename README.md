
# Оглавление
[telegram-alert.sh](#telegram-alert-script)

[rabbitmq_check_consumers](#rabbitmq-consumer-restarter-scripts)



# Telegram Alert Script

Скрипт `telegram-alert.sh` используется для отправки уведомлений в Telegram. Он поддерживает различные форматы заголовков для уведомлений, что позволяет легко интегрировать его в задачи планировщика (`crontab`).

## Особенности

- **Заголовки**: Скрипт поддерживает три режима отправки уведомлений:
  - По умолчанию: `(Alert)`
  - С флагом `--crontab`: `(Crontab)`
  - С флагом `--disaster`: 🔥 Disaster 🔥
- **Интеграция с crontab**: Легко настраивается для мониторинга состояния контейнеров Docker или других задач.
- **HTML-форматирование**: Поддерживает форматирование текста с использованием HTML (например, `<code>` для выделения кода).

## Установка

1. Убедитесь, что у вас есть:
   - Telegram Bot Token.
   - ID чата или канала, куда будут отправляться уведомления.

2. Создайте переменные окружения в вашем `crontab`:
   ```bash
   ERROR_TELEGRAM_CHAT_ID="-111111111"
   ERROR_TELEGRAM_TOKEN="123124125:AAHyAAaasda_MkeRsasddtmnLpasasdzDV05aBo"
   ```

3. Разместите скрипт `telegram-alert.sh` в удобной директории, например, `/opt/scripts/`.

4. Добавьте права на выполнение:
   ```bash
   chmod +x /opt/scripts/telegram-alert.sh
   ```

### Интеграция с crontab
Добавьте следующие строки в ваш `crontab` (выполняется каждую минуту):

```bash
# Переменные для скрипта
ERROR_TELEGRAM_CHAT_ID="-111111111"
ERROR_TELEGRAM_TOKEN="123124125:AAHyAAaasda_MkeRsasddtmnLpasasdzDV05aBo"

# Проверка состояния контейнера php-apache
* * * * * [ "$(docker inspect -f '{{.State.Running}}' php-apache 2>/dev/null)" = "true" ] || /opt/scripts/telegram-alert.sh "Container <code>php-apache-clients</code> is dead"
* * * * * [ "$(docker inspect -f '{{.State.Running}}' php-apache 2>/dev/null)" = "true" ] || /opt/scripts/telegram-alert.sh --crontab "Container <code>php-apache-clients</code> is dead"
* * * * * [ "$(docker inspect -f '{{.State.Running}}' php-apache 2>/dev/null)" = "true" ] || /opt/scripts/telegram-alert.sh --disaster "Container <code>php-apache-clients</code> is dead"
```

## Формат уведомлений

### По умолчанию
```
(Alert) hostname
Container <code>php-apache-clients</code> is dead
```

### С флагом `--crontab`
```
(Crontab) hostname
Container <code>php-apache-clients</code> is dead
```

### С флагом `--disaster`
```
🔥 Disaster 🔥 hostname
Container <code>php-apache-clients</code> is dead
```

## Зависимости

- `curl`: Используется для отправки HTTP-запросов к API Telegram.
- `bash`: Скрипт написан на Bash.

## Настройка переменных окружения

Для работы скрипта необходимо задать следующие переменные окружения:

| Переменная              | Описание                                      |
|-------------------------|-----------------------------------------------|
| `ERROR_TELEGRAM_CHAT_ID`| ID чата или канала Telegram                   |
| `ERROR_TELEGRAM_TOKEN`  | Токен вашего Telegram-бота                    |

Эти переменные можно задать либо в `crontab`, либо в системном окружении.





# RabbitMQ Consumer Restarter Scripts

Этот репозиторий содержит два скрипта для мониторинга и автоматического перезапуска потребителей RabbitMQ:

1. **`consumer_restarter.sh`**: Основной скрипт для проверки состояния потребителей RabbitMQ и их перезапуска при необходимости.
2. **`check_rabbitmq_consumers.sh`**: Скрипт для мониторинга состояния основного скрипта и отправки уведомлений в Telegram через `telegram-alert.sh`.


## Особенности

- **Автоматический мониторинг**: Проверяет количество активных потребителей для указанных очередей RabbitMQ.
- **Автоматический перезапуск**: Если количество потребителей равно 0, контейнеры Docker перезапускаются.
- **Уведомления в Telegram**: Отправляет уведомления о проблемах или успешном восстановлении через `telegram-alert.sh`.
- **Логирование**: Все действия записываются в лог-файл для последующего анализа.

---

## Установка

1. Разместите оба скрипта (`consumer_restarter.sh` и `check_rabbitmq_consumers.sh`) в удобной директории, например:
   ```bash
   /opt/scripts/queue/
   ```

2. Добавьте права на выполнение:
   ```bash
   chmod +x /opt/scripts/queue/consumer_restarter.sh
   chmod +x /opt/scripts/queue/check_rabbitmq_consumers.sh
   ```

3. Убедитесь, что установлены необходимые зависимости (см. раздел [Зависимости](#зависимости)).

---

## Настройка

### 1. Конфигурация `consumer_restarter.sh`

Скрипт использует файл `.env` для загрузки переменных окружения. Убедитесь, что файл существует и содержит следующие параметры:

```bash
RABBITMQ_DEFAULT_USER=guest
RABBITMQ_DEFAULT_PASS=guest
RABBITMQ_MANAGEMENT_PORT=15672
```

Путь к файлу `.env` указан в скрипте:
```bash
ENV_FILE="/opt/containers/queue/.env"
```

Если путь отличается, обновите его в скрипте.

### 2. Настройка очередей для мониторинга

По умолчанию скрипт мониторит очередь `default`. Вы можете добавить дополнительные очереди, раскомментировав и изменив массив `QUEUES`:
```bash
QUEUES=(
    "default"
    "another_queue"
)
```

### 3. Настройка Telegram-уведомлений

Для работы `check_rabbitmq_consumers.sh` требуется скрипт `telegram-alert.sh`. Убедитесь, что он настроен и доступен по пути `/opt/scripts/telegram-alert.sh`.

Также настройте переменные окружения для Telegram:
```bash
ERROR_TELEGRAM_CHAT_ID="-111111111"
ERROR_TELEGRAM_TOKEN="123124125:AAHyAAaasda_MkeRsasddtmnLpasasdzDV05aBo"
```

---

## Использование

### `consumer_restarter.sh`

#### Описание
Скрипт проверяет количество активных потребителей для каждой очереди RabbitMQ. Если количество потребителей равно 0, он перезапускает контейнеры Docker.

#### Пример использования
Запустите скрипт вручную:
```bash
/opt/scripts/queue/consumer_restarter.sh
```

Или добавьте его в `crontab` для периодической проверки:
```bash
* * * * * /opt/scripts/queue/consumer_restarter.sh
```

#### Логика работы
1. Загружает данные о потребителях через API RabbitMQ.
2. Проверяет количество потребителей для каждой очереди.
3. Если потребители отсутствуют, перезапускает контейнеры Docker.

---

### `check_rabbitmq_consumers.sh`

#### Описание
Скрипт мониторит состояние основного скрипта `consumer_restarter.sh` и отправляет уведомления в Telegram при изменении статуса.

#### Пример использования
Добавьте скрипт в `crontab` для периодической проверки:
```bash
* * * * * /opt/scripts/queue/check_rabbitmq_consumers.sh
```

#### Логика работы
1. Запускает `consumer_restarter.sh` и проверяет его выходной код.
2. Если статус изменился (например, с ошибки на успех), отправляет уведомление в Telegram.
3. Сохраняет текущий статус в файл `/tmp/rabbitmq_consumer_status`.

---

## Логирование

Все действия записываются в лог-файл:
```bash
/var/log/consumer_restarter.log
```

Пример записи:
```
2023-10-01 12:00:00 - Очередь default: 0 консьюмеров
2023-10-01 12:00:01 - Обнаружено 0 консьюмеров для default. Перезапускаю...
2023-10-01 12:00:10 - Консьюмеры для default успешно перезапущены
```

---

## Зависимости

Для работы скриптов требуются следующие инструменты:

- `curl`: Для запросов к API RabbitMQ.
- `jq`: Для обработки JSON-данных.
- `bash`: Скрипты написаны на Bash.

Установите зависимости, если они отсутствуют:
```bash
sudo apt update
sudo apt install curl jq -y
```
