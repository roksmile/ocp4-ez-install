#!/usr/bin/env bash
#
# CA + Multi-SAN 서버 인증서 생성 스크립트
#
#   최초 실행      : ca.crt, server.key, server.crt 전부 생성
#   재실행(도메인 추가/갱신) : ca.crt, server.key 는 재사용하고 server.crt 만 재발급
#
# 사용법: DOMAINS 배열에 도메인 추가 후 다시 실행
#
set -euo pipefail

########## 설정 ##########

CA_CN="My Root CA"
CA_DAYS=3650
SRV_DAYS=397          # 브라우저 정책상 398일 이하

DOMAINS=(
  api.ocp4.example.com
  "*.apps.ocp4.example.com"
  registry.ocp4.example.com
)

IPS=(
  # 192.168.0.10
)

##########################

umask 077

# --- SAN 문자열 조립 ---
SAN=$(printf "DNS:%s," "${DOMAINS[@]}")
if [ ${#IPS[@]} -gt 0 ]; then
  SAN+=$(printf "IP:%s," "${IPS[@]}")
fi
SAN=${SAN%,}

echo "==> SAN: $SAN"

# --- 1. CA (없을 때만) ---
if [ -f ca.crt ] && [ -f ca.key ]; then
  echo "==> [1/4] CA 재사용: ca.crt"
else
  echo "==> [1/4] CA 생성"
  openssl req -x509 -newkey rsa:4096 -sha256 -days "$CA_DAYS" -nodes \
    -keyout ca.key -out ca.crt \
    -subj "/CN=$CA_CN" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
fi

# --- 2. 서버 키 (없을 때만) ---
if [ -f server.key ]; then
  echo "==> [2/4] 서버 키 재사용: server.key"
else
  echo "==> [2/4] 서버 키 생성"
  openssl genrsa -out server.key 2048
fi

# --- 3. CSR (매번) ---
echo "==> [3/4] CSR 생성"
openssl req -new -key server.key -sha256 -out server.csr \
  -subj "/CN=${DOMAINS[0]}" \
  -addext "subjectAltName=$SAN" \
  -addext "extendedKeyUsage=serverAuth,clientAuth" \
  -addext "basicConstraints=critical,CA:FALSE"

# --- 4. 서명 (매번) ---
echo "==> [4/4] CA로 서명"
if [ -f server.crt ]; then
  cp server.crt "server.crt.bak.$(date +%Y%m%d%H%M%S)"
fi

if openssl version | grep -q "OpenSSL 3"; then
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$SRV_DAYS" -sha256 -copy_extensions copyall -out server.crt
else
  # OpenSSL 1.1.1 (RHEL 8): -copy_extensions 미지원
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$SRV_DAYS" -sha256 -out server.crt \
    -extfile <(printf "subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nbasicConstraints=critical,CA:FALSE\n" "$SAN")
fi

cat server.crt ca.crt > fullchain.crt
chmod 600 ca.key server.key
chmod 644 ca.crt server.crt fullchain.crt

# --- 검증 ---
echo
echo "===== 검증 ====="
openssl verify -CAfile ca.crt server.crt
openssl x509 -in server.crt -noout -ext subjectAltName -dates

for d in "${DOMAINS[@]}"; do
  t=${d/\*/test}
  printf '  %-45s ' "$t"
  openssl verify -CAfile ca.crt -verify_hostname "$t" server.crt >/dev/null 2>&1 \
    && echo OK || echo FAIL
done

echo
echo "생성 완료: ca.crt / server.key / server.crt / fullchain.crt"