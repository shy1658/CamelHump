import { fileIo as fs, picker, statfs } from '@kit.CoreFileKit';
import { GgufInfo, ModelEntry, ModelMeta } from './Types';
import { ContextHolder } from './ContextHolder';
import { META_FILE, MODELS_DIR, MODEL_FILE, STORAGE_HEADROOM_RATIO } from './Config';
import { InferenceEngine } from './InferenceEngine';
import { Log, describeError } from './Logger';

const COPY_CHUNK = 4 * 1024 * 1024;

export interface ImportResult {
  entry: ModelEntry;
  info: GgufInfo;
}

/**
 * Owns everything under `<filesDir>/models`.
 *
 * Layout per model:
 *   models/<id>/model.gguf
 *   models/<id>/meta.json
 *
 * A model only becomes visible once meta.json exists, so a copy interrupted
 * mid-flight never shows up as a half-usable entry.
 */
export class ModelRepository {
  private root: string = '';

  constructor() {
    this.root = `${ContextHolder.filesDir()}/${MODELS_DIR}`;
  }

  private ensureRoot(): void {
    if (!fs.accessSync(this.root)) {
      fs.mkdirSync(this.root);
    }
  }

  modelPath(id: string): string {
    return `${this.root}/${id}/${MODEL_FILE}`;
  }

  async list(): Promise<ModelEntry[]> {
    this.ensureRoot();
    const out: ModelEntry[] = [];
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.root);
    } catch (e) {
      Log.warn(`list models failed: ${describeError(e)}`);
      return out;
    }

    for (const name of names) {
      if (name.startsWith('.')) {
        continue;
      }
      const dirPath = `${this.root}/${name}`;
      const metaPath = `${dirPath}/${META_FILE}`;
      const filePath = `${dirPath}/${MODEL_FILE}`;
      if (!fs.accessSync(metaPath) || !fs.accessSync(filePath)) {
        continue;
      }
      try {
        const meta = JSON.parse(fs.readTextSync(metaPath)) as ModelMeta;
        const st = fs.statSync(filePath);
        const entry: ModelEntry = {
          id: meta.id,
          displayName: meta.displayName,
          dirPath: dirPath,
          filePath: filePath,
          sizeBytes: st.size,
          architecture: meta.architecture,
          quant: meta.quant,
          contextLength: meta.contextLength,
          blockCount: meta.blockCount,
          hasChatTemplate: meta.hasChatTemplate,
          importedAt: meta.importedAt,
          complete: true,
          curated: meta.curated
        };
        out.push(entry);
      } catch (e) {
        Log.warn(`skip broken model dir ${name}: ${describeError(e)}`);
      }
    }

    out.sort((a: ModelEntry, b: ModelEntry) => b.importedAt - a.importedAt);
    return out;
  }

  /**
   * Copies a user-picked file into the sandbox, then validates it.
   *
   * Copy-before-validate is deliberate: the URI handed back by the picker is
   * only readable for the current session, and mmap on an external URI is not
   * reliable. A 4 MB streaming buffer keeps peak memory flat regardless of the
   * model size.
   */
  async importFromUri(
    uri: string,
    displayName: string,
    onProgress?: (ratio: number) => void
  ): Promise<ImportResult> {
    this.ensureRoot();
    const incoming = `${this.root}/.incoming`;
    if (!fs.accessSync(incoming)) {
      fs.mkdirSync(incoming);
    }

    const tempPath = `${incoming}/pending-${Date.now()}.gguf`;
    let srcFile: fs.File | undefined = undefined;
    let dstFile: fs.File | undefined = undefined;

    try {
      srcFile = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const total = fs.statSync(srcFile.fd).size;
      this.assertSpace(total);

      dstFile = fs.openSync(tempPath,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);

      const buffer = new ArrayBuffer(COPY_CHUNK);
      let written = 0;
      let lastReport = 0;

      while (written < total) {
        const want = Math.min(COPY_CHUNK, total - written);
        const readLen = fs.readSync(srcFile.fd, buffer, { offset: written, length: want });
        if (readLen <= 0) {
          break;
        }
        fs.writeSync(dstFile.fd, buffer, { offset: written, length: readLen });
        written += readLen;

        const pct = Math.floor((written / total) * 100);
        if (onProgress !== undefined && pct >= lastReport + 2) {
          lastReport = pct;
          onProgress(written / total);
        }
      }

      if (written !== total) {
        throw new Error(`复制中断：应为 ${this.mb(total)}，实际写入 ${this.mb(written)}。`
          + `设备存储空间可能不足。`);
      }
    } finally {
      if (dstFile !== undefined) {
        fs.closeSync(dstFile);
      }
      if (srcFile !== undefined) {
        fs.closeSync(srcFile);
      }
    }

    try {
      const engine = new InferenceEngine();
      const info = engine.inspect(tempPath);
      const checked = this.validate(info);
      if (checked !== '') {
        throw new Error(checked);
      }
      const entry = this.adopt(tempPath, info, displayName, false);
      if (onProgress !== undefined) {
        onProgress(1);
      }
      return { entry: entry, info: info };
    } catch (e) {
      this.safeUnlink(tempPath);
      throw new Error(describeError(e));
    }
  }

  /**
   * Turns a message into something the user can act on. These three failures
   * account for almost every bad import, so each gets its own sentence.
   */
  validate(info: GgufInfo): string {
    if (!info.valid) {
      const raw = info.error;
      if (raw.indexOf('bad magic') >= 0) {
        return '这个文件不是 GGUF 格式。请下载文件名以 .gguf 结尾的版本'
          + '（例如 Qwen2.5-1.5B-Instruct-Q4_K_M.gguf），原版 safetensors 权重无法在手机上直接加载。';
      }
      if (raw.indexOf('unsupported GGUF version') >= 0) {
        return `文件使用的是 GGUF v${info.version}，本应用支持 v2 / v3。请用较新的转换工具重新导出。`;
      }
      if (raw.indexOf('truncated') >= 0 || raw.indexOf('corrupt') >= 0) {
        return `文件不完整或已损坏，元数据读取失败（${raw}）。请重新下载。`;
      }
      return `无法读取模型：${raw}`;
    }

    if (!info.complete) {
      return `文件不完整，可能下载中断。张量表声明需要 ${this.mb(info.dataOffset + info.tensorBytes)}，`
        + `实际文件只有 ${this.mb(info.fileSize)}。请重新下载。`;
    }

    if (info.architecture.length === 0) {
      return '文件缺少 general.architecture 字段，无法判断模型结构。请换一个来源。';
    }

    return '';
  }

  /**
   * Moves a validated temp file into its final directory and writes metadata.
   * `info` is trusted here because validate() already passed.
   */
  adopt(tempPath: string, info: GgufInfo, displayName: string, curated: boolean): ModelEntry {
    const id = this.makeId(info.architecture, info.quant);
    const dirPath = `${this.root}/${id}`;
    if (!fs.accessSync(dirPath)) {
      fs.mkdirSync(dirPath);
    }
    const filePath = `${dirPath}/${MODEL_FILE}`;

    fs.renameSync(tempPath, filePath);

    const name = displayName.trim().length > 0
      ? displayName.trim()
      : (info.name.length > 0 ? info.name : `${info.architecture} ${info.quant}`);

    const meta: ModelMeta = {
      version: 1,
      id: id,
      displayName: name,
      architecture: info.architecture,
      quant: info.quant,
      contextLength: info.contextLength,
      blockCount: info.blockCount,
      hasChatTemplate: info.hasChatTemplate,
      importedAt: Date.now(),
      curated: curated
    };

    const metaFile = fs.openSync(`${dirPath}/${META_FILE}`,
      fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(metaFile.fd, JSON.stringify(meta));
    } finally {
      fs.closeSync(metaFile);
    }

    const st = fs.statSync(filePath);
    const entry: ModelEntry = {
      id: id,
      displayName: name,
      dirPath: dirPath,
      filePath: filePath,
      sizeBytes: st.size,
      architecture: info.architecture,
      quant: info.quant,
      contextLength: info.contextLength,
      blockCount: info.blockCount,
      hasChatTemplate: info.hasChatTemplate,
      importedAt: meta.importedAt,
      complete: true,
      curated: curated
    };
    Log.info(`adopted model ${id} (${this.mb(st.size)})`);
    return entry;
  }

  async remove(id: string): Promise<void> {
    const dirPath = `${this.root}/${id}`;
    if (fs.accessSync(dirPath)) {
      this.removeTree(dirPath);
      Log.info(`removed model ${id}`);
    }
  }

  /** Bytes free on the volume that holds the sandbox. */
  freeBytes(): number {
    try {
      this.ensureRoot();
      return statfs.getFreeSizeSync(this.root);
    } catch (e) {
      Log.warn(`statfs failed: ${describeError(e)}`);
      return 0;
    }
  }

  usedBytes(entries: ModelEntry[]): number {
    let sum = 0;
    for (const e of entries) {
      sum += e.sizeBytes;
    }
    return sum;
  }

  private assertSpace(needBytes: number): void {
    const free = this.freeBytes();
    if (free === 0) {
      return;  // statfs unavailable: let the copy fail with its own message
    }
    const required = needBytes * STORAGE_HEADROOM_RATIO;
    if (free < required) {
      throw new Error(`存储空间不足：这个模型需要约 ${this.mb(needBytes)}，`
        + `当前可用 ${this.mb(free)}。请先删除其他模型或清理设备空间。`);
    }
  }

  private makeId(arch: string, quant: string): string {
    const base = `${arch}-${quant}`.toLowerCase().replace(/[^a-z0-9]+/g, '-');
    return `${base}-${Date.now().toString(36)}`;
  }

  private removeTree(path: string): void {
    const st = fs.statSync(path);
    if (st.isDirectory()) {
      const names = fs.listFileSync(path);
      for (const n of names) {
        this.removeTree(`${path}/${n}`);
      }
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
  }

  private safeUnlink(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (e) {
      Log.warn(`cleanup failed: ${describeError(e)}`);
    }
  }

  mb(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    }
    return `${Math.round(bytes / (1024 * 1024))} MB`;
  }
}

/** Opens the system file picker and returns the chosen URI, or '' if cancelled. */
export async function pickGgufFile(): Promise<string> {
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  options.fileSuffixFilters = ['.gguf', '.GGUF'];

  const documentPicker = new picker.DocumentViewPicker(ContextHolder.get());
  const uris = await documentPicker.select(options);
  return uris.length > 0 ? uris[0] : '';
}
