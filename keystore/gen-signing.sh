#!/usr/bin/env bash
# 生成 CamelHump 的调试签名材料。
#
# 密码规则来自 hvigor 的 SignHap 校验与 hap-sign-tool 的 base64 解码:
#   长度必须 >= 32, 必须为偶数, 且必须是合法 base64(长度为 4 的倍数)。
# 证书链结构: 根 CA -> (应用签名 CA | profile 签名 CA) -> 叶子证书。
# profile 侧必须使用 ECC 密钥，generate-profile-cert 只接受 ECDSA 签名算法。
#
# 关键顺序(踩坑记录):
#   1. generate-*-cert -outForm certChain 输出是 叶子->中间->根,
#      而 hap-sign-tool 要求 根->中间->叶子, 必须重排一次。
#   2. profile.json 里的 development-certificate 要取重排后的最后一张(叶子)。
#   3. sign-profile 必须在重排之后执行, 否则 profile 证书链不合法。
#   4. development-certificate 必须以 \n 结尾(-----END CERTIFICATE-----\n),
#      否则 hap-sign-tool 的 base64 解码会报 "Illegal base64 character 20"。
set -euo pipefail

TOOLCHAIN="${TOOLCHAIN:-/root/ohos/sdk/18/toolchains}"
KS_DIR="$(cd "$(dirname "$0")" && pwd)"
KS="$KS_DIR/camelhump.p12"

STORE_PWD="MjkwZjBlZTUxMjY1Y2FhMjgzNTA3N2QyNjNk"  # 36, 偶数
KEY_PWD="ZDg4Y2I0ZTM5ZDdmOTJkZDA4NmNhYmQ5YzIx"   # 38, 偶数

sign_log() { java -jar "$TOOLCHAIN/lib/hap-sign-tool.jar" "$@" 2>&1 | tail -1; }

rm -f "$KS_DIR"/*.cer "$KS_DIR"/*.p7b "$KS_DIR"/*.csr "$KS_DIR"/profile.json "$KS"

# ---------- 1. 根CA ----------
sign_log generate-keypair -keyAlias camelhump-root-ca -keyPwd "$KEY_PWD" -keyAlg RSA -keySize 4096 \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD"
sign_log generate-ca -keyAlias camelhump-root-ca -keyPwd "$KEY_PWD" -keyAlg RSA -keySize 4096 \
  -subject "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpRootCA" -validity 3650 -signAlg SHA384withRSA \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outFile "$KS_DIR/root-ca.cer"

# ---------- 2. 应用签名子 CA ----------
sign_log generate-keypair -keyAlias camelhump-app-ca -keyPwd "$KEY_PWD" -keyAlg RSA -keySize 4096 \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD"
sign_log generate-ca -keyAlias camelhump-app-ca -keyPwd "$KEY_PWD" -keyAlg RSA -keySize 4096 \
  -issuer "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpRootCA" -issuerKeyAlias camelhump-root-ca -issuerKeyPwd "$KEY_PWD" \
  -subject "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpAppCA" -validity 3650 -signAlg SHA384withRSA \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outFile "$KS_DIR/app-ca.cer"

# ---------- 3. profile 签名子 CA (ECC) ----------
sign_log generate-keypair -keyAlias camelhump-profile-ca -keyPwd "$KEY_PWD" -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD"
sign_log generate-ca -keyAlias camelhump-profile-ca -keyPwd "$KEY_PWD" -keyAlg ECC -keySize NIST-P-256 \
  -issuer "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpRootCA" -issuerKeyAlias camelhump-root-ca -issuerKeyPwd "$KEY_PWD" \
  -subject "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpProfileCA" -validity 3650 -signAlg SHA384withRSA \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outFile "$KS_DIR/profile-ca.cer"

# ---------- 4. 应用叶子证书 (ECC) ----------
sign_log generate-keypair -keyAlias camelhump-app-v1 -keyPwd "$KEY_PWD" -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD"
sign_log generate-app-cert -keyAlias camelhump-app-v1 -keyPwd "$KEY_PWD" \
  -issuer "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpAppCA" -issuerKeyAlias camelhump-app-ca -issuerKeyPwd "$KEY_PWD" \
  -subject "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpDebug" -validity 3650 -signAlg SHA256withECDSA \
  -rootCaCertFile "$KS_DIR/root-ca.cer" -subCaCertFile "$KS_DIR/app-ca.cer" \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outForm certChain -outFile "$KS_DIR/app-cert.cer"

# ---------- 5. profile 叶子证书 (ECC) ----------
sign_log generate-keypair -keyAlias camelhump-profile-v1 -keyPwd "$KEY_PWD" -keyAlg ECC -keySize NIST-P-256 \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD"
sign_log generate-profile-cert -keyAlias camelhump-profile-v1 -keyPwd "$KEY_PWD" \
  -issuer "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpProfileCA" -issuerKeyAlias camelhump-profile-ca -issuerKeyPwd "$KEY_PWD" \
  -subject "C=CN,O=CamelHump,OU=Dev,CN=CamelHumpProfile" -validity 3650 -signAlg SHA256withECDSA \
  -rootCaCertFile "$KS_DIR/root-ca.cer" -subCaCertFile "$KS_DIR/profile-ca.cer" \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outForm certChain -outFile "$KS_DIR/profile-cert.cer"

# ---------- 6. 证书链重排: 叶子优先 -> 根->中间->叶子 ----------
python3 - "$KS_DIR" <<'PY'
import re, sys
d = sys.argv[1]
for name in ('app-cert.cer', 'profile-cert.cer'):
    path = f'{d}/{name}'
    blocks = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                        open(path).read(), re.S)
    if len(blocks) < 2:
        continue
    blocks.reverse()
    open(path, 'w').write('\n'.join(blocks) + '\n')
    print(f'  reordered {name}: root -> intermediate -> leaf ({len(blocks)} certs)')
PY

# ---------- 7. Provision Profile JSON ----------
# 版本号必须与 AppScope/app.json5 里的 versionName / versionCode 一致，
# 否则 hap-sign-tool 或 AGC 会报「Profile 与包不匹配」。
VERSION_NAME="${VERSION_NAME:-1.1.1}"
VERSION_CODE="${VERSION_CODE:-1001001}"
python3 - "$KS_DIR" "$VERSION_NAME" "$VERSION_CODE" <<'PY'
import json, re, sys, time, uuid
d = sys.argv[1]
version_name = sys.argv[2]
version_code = int(sys.argv[3])
# development-certificate 保持 PEM 原文; JSON 会把换行转义成 \n, 不含裸斜杠。
# app-cert.cer 已重排为 根->中间->叶子, 叶子在最后一张。
_blocks = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
                     open(f'{d}/app-cert.cer').read(), re.S)
# 末尾的换行是必需的: hap-sign-tool 会把 PEM 去掉头尾后做 base64 解码,
# 缺少结尾换行会导致 "Illegal base64 character 20"。
leaf = _blocks[-1] + '\n'
prof = {
    "version-name": version_name,
    "version-code": version_code,
    "uuid": str(uuid.uuid4()),
    "validity": {"not-before": int(time.time()) - 3600,
                 "not-after": int(time.time()) + 365 * 24 * 3600},
    "type": "debug",
    "bundle-info": {"developer-id": "CamelHump",
                    "development-certificate": leaf,
                    "bundle-name": "com.camelhump.app",
                    "apl": "normal",
                    "app-feature": "hos_normal_app"},
    "acls": {"allowed-acls": []},
    "permissions": {"restricted-permissions": []},
    "debug-info": {"device-ids": [], "device-id-type": "udid"},
    "issuer": "pki_internal",
}
json.dump(prof, open(f'{d}/profile.json', 'w'), separators=(',', ':'))
PY

# ---------- 8. 签 profile 并校验 ----------
sign_log sign-profile -mode localSign -keyAlias camelhump-profile-v1 -keyPwd "$KEY_PWD" \
  -profileCertFile "$KS_DIR/profile-cert.cer" -inFile "$KS_DIR/profile.json" -signAlg SHA256withECDSA \
  -keystoreFile "$KS" -keystorePwd "$STORE_PWD" -outFile "$KS_DIR/camelhump.p7b"

java -jar "$TOOLCHAIN/lib/hap-sign-tool.jar" verify-profile -inFile "$KS_DIR/camelhump.p7b" 2>&1 | tail -3
echo "签名材料生成完毕: $KS_DIR"
