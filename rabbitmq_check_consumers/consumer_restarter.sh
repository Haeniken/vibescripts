#!/bin/bash

# Загрузка переменных окружения
ENV_FILE="/opt/containers/queue/.env"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    log "Файл конфигурации не найден: $ENV_FILE"
    exit 1
fi

# credentials и URL для API
USER="${RABBITMQ_DEFAULT_USER}"
PASS="${RABBITMQ_DEFAULT_PASS}"
API_URL="http://localhost:${RABBITMQ_MANAGEMENT_PORT}/api/consumers"

# Список очередей для мониторинга (можно сделать динамическим)
QUEUES=("default")
#QUEUES=(
#    "default"
#)

# файл для логов
LOG_FILE="/var/log/consumer_restarter.log"

# функция для логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# получаем все данные о консьюмерах один раз
CONSUMERS_JSON=$(curl -s -u "$USER:$PASS" "$API_URL")
CURL_EXIT_CODE=$?

# проверка успешности запроса
if [ $CURL_EXIT_CODE -ne 0 ] || [ -z "$CONSUMERS_JSON" ]; then
    log "Ошибка при получении данных от API. Код выхода: $CURL_EXIT_CODE"
    exit 1
fi

# проверка валидности JSON
if ! jq -e . >/dev/null 2>&1 <<<"$CONSUMERS_JSON"; then
    log "Получены невалидные JSON данные"
    exit 1
fi

# обработка каждой очереди
for QUEUE in "${QUEUES[@]}"; do
    # извлекаем количество консьюмеров для очереди
    CONSUMER_COUNT=$(jq -r --arg q "$QUEUE" '[.[] | select(.queue.name == $q)] | length' <<< "$CONSUMERS_JSON")

    log "Очередь $QUEUE: $CONSUMER_COUNT консьюмеров"

    # если консьюмеров 0 - перезапускаем
    if [ "$CONSUMER_COUNT" -eq 0 ]; then
        log "Обнаружено 0 консьюмеров для $QUEUE. Перезапускаю..."

        # преобразование имени очереди в имя консьюмера
        CONSUMER_NAME=$(sed -e 's/^queue-/consumer_/' -e 's/-/_/g' <<< "$QUEUE")

        # перезапуск контейнера через docker compose
        cd /opt/containers/queue/ && docker compose down && docker compose up -d >/dev/null

        if [ $? -eq 0 ]; then
            log "Консьюмеры для $QUEUE ($CONSUMER_NAME) успешно перезапущены"
        else
            log "Ошибка при перезапуске консьюмеров для $QUEUE ($CONSUMER_NAME)"
        fi
    fi
done
