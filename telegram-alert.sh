#!/bin/bash

die() {
    >&1 echo "error: $@"
    exit 1
}

token="$ERROR_TELEGRAM_TOKEN"
chat_id="$ERROR_TELEGRAM_CHAT_ID"
hostname=$(hostname)

[ -z "$token" ] && die "no token"
[ -z "$chat_id" ] && die "no chat_id"

# По умолчанию используем Alert
prefix="(Alert)"

# Обработка аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --crontab)
            prefix="(Crontab)"
            shift
            ;;
        --disaster)
            prefix="🔥 Disaster 🔥"
            shift
            ;;
        *)
            # Все остальные аргументы считаем текстом сообщения
            message="$1"
            shift
            ;;
    esac
done

[ -z "$message" ] && die "no message provided"

url="https://api.telegram.org/bot${token}/sendMessage"

curl \
 --data parse_mode=HTML \
 --data chat_id="${chat_id}" \
 --data text="<b>${prefix} ${hostname}</b>%0A${message}" \
 --request POST "$url"
