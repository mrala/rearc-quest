#!/usr/bin/env bash
# Cloud-neutral acceptance test for the quest app (ADR-0010).
#
#   tests/smoke.sh [-k] [-H 'Name: value']... [-s ROUTE]... [-t SECONDS] BASE_URL
#
#   -k   accept a self-signed certificate (our TLS cert is self-signed)
#   -H   extra request header, repeatable (used locally to forge ALB headers)
#   -s   skip a route, repeatable (e.g. -s / -s /aws outside a cloud, where they cannot pass)
#   -t   per-request timeout in seconds (default 90; "/" takes ~25 s outside a cloud)
#
# Environment:
#   EXPECT_SECRET_WORD  if set, /secret_word must also print this value
#
# Contains no cloud-specific logic. It records what each route says and exits
# non-zero if any route fails, so per-cloud differences are visible, not hidden.
set -o pipefail

TIMEOUT=90
INSECURE=""
HEADERS=()
SKIP=()

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":kH:s:t:h" opt; do
  case "$opt" in
    k) INSECURE="--insecure" ;;
    H) HEADERS+=("$OPTARG") ;;
    s) SKIP+=("$OPTARG") ;;
    t) TIMEOUT="$OPTARG" ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || { usage >&2; exit 2; }
BASE="${1%/}"

ROUTES=(/ /aws /docker /secret_word /loadbalanced /tls)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CURL_ARGS=(--silent --show-error --location --max-time "$TIMEOUT")
[[ -n "$INSECURE" ]] && CURL_ARGS+=("$INSECURE")
for h in ${HEADERS[@]+"${HEADERS[@]}"}; do CURL_ARGS+=(-H "$h"); done

fetch() { # $1 = route index, $2 = route
  local out="$TMP/$1"
  curl "${CURL_ARGS[@]}" --output "$out.body" --write-out '%{http_code} %{time_total}' \
    "$BASE$2" > "$out.meta" 2> "$out.err"
  [[ -s "$out.meta" ]] || echo "000 0" > "$out.meta"
}

skipped() { local s; for s in ${SKIP[@]+"${SKIP[@]}"}; do [[ "$s" == "$1" ]] && return 0; done; return 1; }

# Requests run in parallel: total time is the slowest route, not the sum.
for i in "${!ROUTES[@]}"; do skipped "${ROUTES[$i]}" || fetch "$i" "${ROUTES[$i]}" & done
wait

verdict() { # $1 = route, $2 = http code, $3 = body file
  [[ "$2" == "200" ]] || { echo FAIL; return; }
  case "$1" in
    # The success text of "/" and "/aws" has not been observed outside a cloud, so
    # these pass when they return something other than the known "not in a cloud" text.
    /|/aws)
      if [[ ! -s "$3" ]] || grep -q "don't seem to be running" "$3"; then echo FAIL; else echo PASS; fi ;;
    /secret_word)
      if grep -q "Congratulations" "$3" && { [[ -z "${EXPECT_SECRET_WORD:-}" ]] || grep -qF "$EXPECT_SECRET_WORD" "$3"; }
      then echo PASS; else echo FAIL; fi ;;
    *)
      if grep -q "Congratulations" "$3"; then echo PASS; else echo FAIL; fi ;;
  esac
}

echo "smoke test: $BASE"
printf '%-5s %-14s %-5s %-8s %s\n' RESULT ROUTE HTTP TIME BODY
pass=0; fail=0; skip=0
for i in "${!ROUTES[@]}"; do
  route="${ROUTES[$i]}"
  if skipped "$route"; then
    printf '%-5s %-14s\n' SKIP "$route"; skip=$((skip + 1)); continue
  fi
  read -r code secs < "$TMP/$i.meta"
  v="$(verdict "$route" "$code" "$TMP/$i.body")"
  body=""
  [[ -f "$TMP/$i.body" ]] && body="$(tr '\n' ' ' < "$TMP/$i.body" | tr -s ' ' | cut -c1-110)"
  [[ -z "$body" && -s "$TMP/$i.err" ]] && body="$(head -n1 "$TMP/$i.err" | cut -c1-110)"
  printf '%-5s %-14s %-5s %-8s %s\n' "$v" "$route" "$code" "${secs}s" "$body"
  if [[ "$v" == PASS ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi
done
echo "$pass passed, $fail failed, $skip skipped"
[[ "$fail" -eq 0 ]]
