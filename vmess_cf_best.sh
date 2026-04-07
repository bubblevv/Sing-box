#!/usr/bin/env bash

set -euo pipefail

WORK_DIR="${WORK_DIR:-/etc/sing-box}"
URL_FILE="${URL_FILE:-${WORK_DIR}/url.txt}"
SUB_FILE="${SUB_FILE:-${WORK_DIR}/sub.txt}"
ARGO_LOG="${ARGO_LOG:-${WORK_DIR}/argo.log}"
MAX_TIME="${MAX_TIME:-12}"

DEFAULT_CANDIDATES=(
  "cf.090227.xyz:443"
  "cf.877774.xyz:443"
  "cf.877771.xyz:443"
  "cdns.doon.eu.org:443"
  "cf.zhetengsha.eu.org:443"
  "time.is:443"
)

red() { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "缺少依赖: $1"; exit 1; }
}

get_vmess_url() {
  grep -o 'vmess://[^ ]*' "${URL_FILE}" 2>/dev/null | head -n 1
}

get_vmess_json() {
  local vmess_url encoded

  vmess_url=$(get_vmess_url)
  [ -n "${vmess_url}" ] || return 1

  encoded="${vmess_url#vmess://}"
  echo "${encoded}" | base64 --decode 2>/dev/null
}

get_argo_domain() {
  local domain

  domain=$(sed -n 's|.*https://\([^/]*trycloudflare\.com\).*|\1|p' "${ARGO_LOG}" 2>/dev/null | tail -n 1)
  if [ -n "${domain}" ]; then
    echo "${domain}"
    return 0
  fi

  get_vmess_json 2>/dev/null | jq -r '.host // empty' 2>/dev/null
}

parse_candidate() {
  local candidate="$1"
  local host port

  if [[ "${candidate}" == *:* ]]; then
    host="${candidate%:*}"
    port="${candidate##*:}"
  else
    host="${candidate}"
    port="443"
  fi

  printf '%s %s\n' "${host}" "${port}"
}

test_candidate() {
  local candidate="$1"
  local host port header_file metrics status_code connect_time tls_time first_byte score_ms

  read -r host port < <(parse_candidate "${candidate}")
  header_file=$(mktemp)

  metrics=$(curl -sk --http1.1 --max-time "${MAX_TIME}" -o /dev/null -D "${header_file}" \
    --connect-to "${ARGO_DOMAIN}:443:${host}:${port}" \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: SGVsbG8sIHdvcmxkIQ==" \
    "https://${ARGO_DOMAIN}/vmess-argo?ed=2560" \
    -w 'code=%{http_code} connect=%{time_connect} tls=%{time_appconnect} start=%{time_starttransfer}' 2>/dev/null || true)

  status_code=$(awk 'NR==1 {print $2}' "${header_file}" 2>/dev/null)
  rm -f "${header_file}"

  connect_time=$(echo "${metrics}" | sed -n 's/.*connect=\([0-9.]*\).*/\1/p')
  tls_time=$(echo "${metrics}" | sed -n 's/.*tls=\([0-9.]*\).*/\1/p')
  first_byte=$(echo "${metrics}" | sed -n 's/.*start=\([0-9.]*\).*/\1/p')

  [ -z "${tls_time}" ] && tls_time="999"
  score_ms=$(awk -v t="${tls_time}" 'BEGIN { printf "%.0f", t * 1000 }')

  if [ "${status_code}" = "101" ] || echo "${metrics}" | grep -q 'code=101'; then
    printf 'OK|%s|%s|%s|%s|%s\n' "${candidate}" "${score_ms}" "${connect_time:-0}" "${tls_time:-0}" "${first_byte:-0}"
  else
    printf 'FAIL|%s|%s|%s|%s|%s\n' "${candidate}" "${score_ms}" "${connect_time:-0}" "${tls_time:-0}" "${first_byte:-0}"
  fi
}

write_vmess_candidate() {
  local selected_host="$1"
  local selected_port="$2"
  local vmess_url encoded vmess_json updated_json updated_vmess new_content backup_file

  vmess_url=$(get_vmess_url)
  [ -n "${vmess_url}" ] || { red "未找到 vmess 节点"; return 1; }

  encoded="${vmess_url#vmess://}"
  vmess_json=$(echo "${encoded}" | base64 --decode 2>/dev/null)
  [ -n "${vmess_json}" ] || { red "vmess 节点解码失败"; return 1; }

  updated_json=$(echo "${vmess_json}" | jq -c \
    --arg add "${selected_host}" \
    --arg port "${selected_port}" \
    --arg host "${ARGO_DOMAIN}" \
    '.add = $add | .port = $port | .host = $host | .sni = $host | .allowInsecure = "false"')

  updated_vmess="vmess://$(echo "${updated_json}" | base64 -w0)"
  new_content=$(sed "s|^vmess://.*$|${updated_vmess}|" "${URL_FILE}")
  backup_file="${URL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${URL_FILE}" "${backup_file}"
  printf '%s\n' "${new_content}" > "${URL_FILE}"
  base64 -w0 "${URL_FILE}" > "${SUB_FILE}"

  green "\n已写入新的 vmess-argo 优选:"
  purple "${selected_host}:${selected_port}\n"
  yellow "原文件备份: ${backup_file}\n"
  purple "${updated_vmess}\n"
}

print_results() {
  local file="$1"
  local index=1
  local line status candidate score connect tls first

  printf '\n'
  green "当前 Argo 域名:"
  purple "${ARGO_DOMAIN}\n"
  green "测试结果(按 TLS 建连耗时升序):\n"

  while IFS='|' read -r status candidate score connect tls first; do
    if [ "${status}" = "OK" ]; then
      printf '%2d. [OK]   %-28s tls=%4sms connect=%ss first=%ss\n' "${index}" "${candidate}" "${score}" "${connect}" "${first}"
      index=$((index + 1))
    fi
  done < "${file}"

  if [ "${index}" -eq 1 ]; then
    yellow "没有测到可用优选，建议回退直连 Argo 域名。\n"
  fi

  while IFS='|' read -r status candidate score connect tls first; do
    if [ "${status}" = "FAIL" ]; then
      printf ' - [FAIL] %s\n' "${candidate}"
    fi
  done < "${file}"
}

main() {
  local candidates=()
  local extra_input results_file ok_file choice selected_line selected_candidate selected_host selected_port

  require_cmd curl
  require_cmd jq
  require_cmd base64

  [ -f "${URL_FILE}" ] || { red "未找到 ${URL_FILE}"; exit 1; }

  ARGO_DOMAIN=$(get_argo_domain)
  [ -n "${ARGO_DOMAIN}" ] || { red "未获取到当前 Argo 域名"; exit 1; }

  if [ "$#" -gt 0 ]; then
    candidates=("$@")
  else
    candidates=("${DEFAULT_CANDIDATES[@]}")
    yellow "内置候选优选:\n"
    printf ' - %s\n' "${candidates[@]}"
    printf '\n'
    read -r -p "可追加自定义候选(空格分隔，回车跳过): " extra_input
    if [ -n "${extra_input}" ]; then
      # shellcheck disable=SC2206
      candidates+=(${extra_input})
    fi
  fi

  results_file=$(mktemp)
  ok_file=$(mktemp)

  yellow "开始测试 vmess-argo 候选，请稍等...\n"
  for candidate in "${candidates[@]}"; do
    yellow "测试: ${candidate}"
    test_candidate "${candidate}" >> "${results_file}"
  done

  grep '^OK|' "${results_file}" | sort -t'|' -k3,3n > "${ok_file}" || true
  cat "${ok_file}" <(grep '^FAIL|' "${results_file}" || true) > "${results_file}.sorted"
  mv "${results_file}.sorted" "${results_file}"

  print_results "${results_file}"

  read -r -p $'\n输入编号写入优选，输入 0 回退直连 Argo，直接回车默认选第 1 个: ' choice
  choice="${choice:-1}"

  if [ "${choice}" = "0" ]; then
    write_vmess_candidate "${ARGO_DOMAIN}" "443"
    rm -f "${results_file}" "${ok_file}"
    exit 0
  fi

  selected_line=$(grep '^OK|' "${results_file}" | sed -n "${choice}p")
  if [ -z "${selected_line}" ]; then
    red "无效选择，未写入任何修改"
    rm -f "${results_file}" "${ok_file}"
    exit 1
  fi

  selected_candidate=$(echo "${selected_line}" | cut -d'|' -f2)
  read -r selected_host selected_port < <(parse_candidate "${selected_candidate}")
  write_vmess_candidate "${selected_host}" "${selected_port}"

  rm -f "${results_file}" "${ok_file}"
}

main "$@"
