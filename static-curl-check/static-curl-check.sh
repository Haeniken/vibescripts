#!/bin/bash

# Скрипт для ненужных ссылок в коде группы сайтов
# Надо указать домены в файле с доменами, обратить внимание на протокол и какую ссылку мы именно ищем (static3 в данном примере)
# Файл с доменами:
DOMAINS_FILE="static-curl-check_domains.csv"

if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "ERROR: File $DOMAINS_FILE not exist"
  exit 1
fi

while read -r domain; do
  if [[ -z "$domain" || "$domain" == "#"* ]]; then
    continue
  fi

  domain=$(echo "$domain" | sed 's|/$||')
  echo "Checking: $domain"
  result=$(curl -s --max-time 5 "https://$domain" | grep "static3")

  if [[ -n "$result" ]]; then
    echo "ERROR for $domain"
    echo "$result"
  else
    echo "$domain is OK"
  fi

  echo "-----------------------------"
done < "$DOMAINS_FILE"
