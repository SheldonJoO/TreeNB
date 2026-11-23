#!/bin/bash
# TreeNB 正式签名：导入 p12 + 描述文件，用签名账号重签 IPA
# 只在 release / 手动触发时运行；所有密钥来自 GitHub Secrets（环境变量）
set -euo pipefail

cd "$(dirname "$0")/.."
: "${CERT_P12_BASE64:?缺少 SIGNING_CERT_P12 secret}"
: "${CERT_PASSWORD:?缺少 SIGNING_CERT_PASSWORD secret}"
: "${PROVISIONING_PROFILE_BASE64:?缺少 PROVISIONING_PROFILE secret}"

IPA=$(find build -name "*-unsigned.ipa" -type f | head -1)
[ -n "$IPA" ] || { echo "找不到未签名 IPA" >&2; exit 1; }

echo "==> 导入签名证书"
KEYCHAIN="treenb-signing.keychain-db"
security create-keychain -p "" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "" "$KEYCHAIN"
echo "$CERT_P12_BASE64" | base64 --decode > /tmp/cert.p12
security import /tmp/cert.p12 -k "$KEYCHAIN" -P "$CERT_PASSWORD" \
  -T /usr/bin/codesign -T /usr/bin/security 2>/dev/null || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

echo "==> 准备描述文件"
PP_UUID=$(python3 - <<'PY'
import base64, plistlib, os
data = base64.b64decode(os.environ["PROVISIONING_PROFILE_BASE64"])
p = plistlib.loads(data)
open("/tmp/profile.mobileprovision", "wb").write(data)
print(p.get("UUID", ""))
PY
)
mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
cp /tmp/profile.mobileprovision "$HOME/Library/MobileDevice/Provisioning Profiles/$PP_UUID.mobileprovision"

# 从描述文件提取签名身份
CERT_NAME=$(python3 - <<'PY'
import plistlib
p = plistlib.load(open("/tmp/profile.mobileprovision", "rb"))
certs = p.get("DeveloperCertificates", [])
if certs:
    # 用 openssl 读取 CN
    import subprocess, tempfile
    f = tempfile.NamedTemporaryFile(suffix=".cer", delete=False)
    f.write(certs[0]); f.close()
    out = subprocess.run(["openssl","x509","-inform","DER","-in",f.name,"-noout","-subject"],
                         capture_output=True, text=True).stdout
    cn = out.split("CN=")[-1].split(",")[0].strip() if "CN=" in out else ""
    print(cn)
PY
)

echo "==> 重签 IPA (identity: ${CERT_NAME:-<from profile>})"
# 用 ipa sign 工具（xcode 镜像自带 / 或 brew install assemble-libraries 的 `ipa`）
# 这里用最直接的方式：解包 → codesign → 重打包
WORK=$(mktemp -d)
cd "$WORK"
unzip -q "$OLDPWD/$IPA"
APP=$(find Payload -maxdepth 1 -name "*.app" -type d | head -1)

# 覆盖描述文件
cp /tmp/profile.mobileprovision "$APP/embedded.mobileprovision"

# 生成 entitlements plist（从描述文件）
python3 - <<'PY'
import plistlib
p = plistlib.load(open("/tmp/profile.mobileprovision", "rb"))
ents = p.get("Entitlements", {})
import os
# 去掉不可签名的键
for k in ["com.apple.developer.ubiquity-container-identifiers"]:
    ents.pop(k, None)
with open("entitlements.plist", "wb") as f:
    plistlib.dump(ents, f)
PY

# 先签 appex，再签主 app（顺序不能反）
find "$APP/PlugIns" -name "*.appex" -type d 2>/dev/null | while read -r appex; do
  codesign --force --sign "$CERT_NAME" --entitlements entitlements.plist \
    --timestamp=none "$appex"
done
codesign --force --sign "$CERT_NAME" --entitlements entitlements.plist \
  --timestamp=none "$APP"

SIGNED="$OLDPWD/build/$(basename "$IPA" -unsigned.ipa)-signed.ipa"
zip -qr "$SIGNED" Payload -x "._*" -x ".DS_Store"
echo "完成: $SIGNED"

# 清理临时 keychain
security delete-keychain "$KEYCHAIN" 2>/dev/null || true
