#!/bin/bash

# Пути к файлам
SCRIPT="/opt/scripts/queue/consumer_restarter.sh"
STATUS_FILE="/tmp/rabbitmq_consumer_status"
CURRENT_STATUS=""

# Запускаем скрипт и перехватываем вывод
if output=$("$SCRIPT" 2>&1); then
    CURRENT_STATUS="OK"
else
    CURRENT_STATUS="ERROR: $output"
fi

# Читаем предыдущий статус
PREVIOUS_STATUS=$(cat "$STATUS_FILE" 2>/dev/null || echo "UNKNOWN")

# Если статус изменился
if [ "$CURRENT_STATUS" != "$PREVIOUS_STATUS" ]; then
    if [ "$CURRENT_STATUS" == "OK" ]; then
        /opt/scripts/telegram-alert.sh "Потребители RabbitMQ восстановлены"
    else
        /opt/telegram-alert.sh "Проблема с потребителями RabbitMQ: $CURRENT_STATUS"
    fi
    # Сохраняем новый статус
    echo "$CURRENT_STATUS" > "$STATUS_FILE"
fi
