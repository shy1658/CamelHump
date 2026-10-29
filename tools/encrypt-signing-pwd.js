#!/usr/bin/env node
/**
 * 用 hvigor 的 material 密钥把明文密码加密成 hvigor 认识的格式。
 *
 * 背景：
 *   hvigor 的 SignHap / SignApp 任务会用 keystore/material 下的加密材料
 *   解密 build-profile.json5 里的 storePassword / keyPassword。
 *   那个格式是 hex 密文，纯命令行环境没有 DevEco Studio 就没有加密材料，
 *   签名必然失败（ENOENT: stat 'keystore/material'）。
 *
 *   解决办法：命令行工具链自带的 hvigor 插件里就有标准的 material 目录
 *   （res/material/{fd,ac,ce}），复制到工程下即可；密码则用同一套材料加密。
 *
 * 用法：
 *   node tools/encrypt-signing-pwd.js <明文密码>
 *   # 输出可直接填进 build-profile.json5 的 hex 密文
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// hvigor 硬编码的组件常量，见 decipher-util.js
const COMPONENT = new Int8Array([49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119]);

function readDirBytes(dir) {
  const files = fs.readdirSync(dir).filter(f => f !== '.DS_Store');
  if (files.length !== 1) {
    throw new Error(`${dir} 下应有且仅有一个文件，实际 ${files.length} 个`);
  }
  return new Int8Array(fs.readFileSync(path.resolve(dir, files[0])));
}

/**
 * 读 material/fd 目录本身（不是 fd/0、fd/1、fd/2）。
 *
 * hvigor 的 readFd 用 readdirSync 的返回顺序取其中 3 个条目，
 * 顺序必须一致 —— 否则 xor 出的派生串不同，pbkdf2 结果全错。
 */
function readFd(dir) {
  const entries = fs.readdirSync(dir).filter(f => f !== '.DS_Store');
  if (entries.length !== 3) {
    throw new Error(`${dir} 下应有 3 个条目，实际 ${entries.length} 个`);
  }
  return entries.map(e => readDirBytes(path.resolve(dir, e)));
}

function xor(a, b) {
  const r = new Int8Array(a.byteLength);
  for (let i = 0; i < a.byteLength; i++) r[i] = a[i] ^ b[i];
  return r;
}

function xorComponents(arr) {
  let r = xor(arr[0], arr[1]);
  for (let i = 2; i < arr.length; i++) r = xor(r, arr[i]);
  return Buffer.from(r);
}

function decrypt(key, data) {
  const r = (255 & data[0]) << 24 | (255 & data[1]) << 16 | (255 & data[2]) << 8 | (255 & data[3]);
  const i = data.length - 4 - r;
  const iv = data.slice(4, 4 + i);
  const authTag = data.slice(data.length - 16);
  const d = crypto.createDecipheriv('aes-128-gcm', key, iv);
  d.setAuthTag(authTag);
  const body = d.update(data.subarray(4 + i, data.length - 16));
  return Buffer.concat([body, d.final()]);
}

function encrypt(key, plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-128-gcm', key, iv);
  const body = Buffer.concat([c.update(Buffer.from(plain, 'utf8')), c.final()]);
  // 注意：GCM 的 authTag 长度固定 16。不能用 c.getAuthTag().length 来算，
  // 因为 final() 之后 tag 已被消费，长度会变成 0，导致头部值偏小、
  // hvigor 解密时把 IV 长度算错（i 变成 16 而不是 12），报
  // "Unsupported state or unable to authenticate data"。
  const authTag = c.getAuthTag();
  // 头部 r 的语义（用 hvigor 自带样本 zb/de 反推验证）：
  //   总长 = 4(头) + 12(IV) + 密文 + 16(tag)
  //   hvigor: i = 总长 - 4 - r，而 IV 长度必须等于 i
  //   ⇒ r = 密文长度 + 16
  // 样本校验：zb/de 明文 "DebugKey" 8 字节 → 密文 8 → r = 24 = 8 + 16 ✓
  const header = Buffer.alloc(4);
  header.writeInt32BE(body.length + 16, 0);
  return Buffer.concat([header, iv, body, authTag]).toString('hex');
}

function main() {
  const plain = process.argv[2];
  if (!plain) {
    console.error('用法: node tools/encrypt-signing-pwd.js <明文密码>');
    process.exit(1);
  }

  const materialDir = process.argv[3]
    || path.resolve(__dirname, '..', 'keystore', 'material');
  if (!fs.existsSync(materialDir)) {
    console.error(`找不到 material 目录: ${materialDir}`);
    console.error('从命令行工具链复制：');
    console.error('  cp -r $DEVECO_SDK_HOME/../../hvigor/hvigor-ohos-plugin/res/material keystore/material');
    process.exit(1);
  }

  // 必须用 readFd()：hvigor 的 readFd 读的是 material/fd 目录本身，
  // 用 readdirSync 的顺序取其中 3 个条目再逐个读 —— 顺序必须与 hvigor 一致，
  // 否则 xor 出来的派生串不同，pbkdf2 结果就全错。
  const fd = readFd(path.join(materialDir, 'fd'));
  const salt = readDirBytes(path.join(materialDir, 'ac'));
  const work = readDirBytes(path.join(materialDir, 'ce'));

  // hvigor 的 xorComponents 顺序：fd0 ^ fd1 ^ fd2 ^ COMPONENT
  const rootKeyMaterial = xorComponents(fd.concat([COMPONENT]));
  // salt 原样传入：Buffer.from(Int8Array) 会按有符号处理，高位字节（>127）
  // 会变负数，导致 pbkdf2 结果与 hvigor 不一致。
  const rootKey = crypto.pbkdf2Sync(rootKeyMaterial.toString(), salt, 10000, 16, 'sha256');
  const key = new Int8Array(decrypt(rootKey, work));

  if (process.env.DEBUG_KEY) {
    console.error('[debug] rootKey =', Buffer.from(rootKey).toString('hex'));
    console.error('[debug] key     =', Buffer.from(key).toString('hex'));
  }

  console.log(encrypt(key, plain));
}

main();
