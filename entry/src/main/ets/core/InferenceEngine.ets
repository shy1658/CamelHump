import native from 'libcamelhump.so';
import { AppSettings, ChatMsg, GenStatsLite, GgufInfo, ModelEntry } from './Types';
import { Log, describeError } from './Logger';

interface NativeParams {
  contextLength: number;
  threads: number;
  threadsBatch: number;
  maxTokens: number;
  temperature: number;
  topP: number;
  topK: number;
  repeatPenalty: number;
  useMmap: boolean;
}

interface NativeMessage {
  role: string;
  content: string;
}

/** End-of-stream sentinel pushed by the native token channel. */
export const EOF_TOKEN: string = '__CAMELEHUMP_EOF__';

/**
 * Owns exactly one loaded model at a time.
 *
 * Holding several sessions alive at once is technically possible but wrong on a
 * phone: each one pins its weights plus KV cache, and the system kills the whole
 * process when the quota is exceeded. Switching releases first.
 */
export class InferenceEngine {
  private sessionId: number = -1;
  private modelId: string = '';
  private generating: boolean = false;

  enginePresent(): boolean {
    return native.hasEngine();
  }

  isLoaded(): boolean {
    return this.sessionId >= 0;
  }

  currentModelId(): string {
    return this.modelId;
  }

  isBusy(): boolean {
    return this.generating;
  }

  async load(model: ModelEntry, settings: AppSettings): Promise<string> {
    this.release();
    const params: NativeParams = {
      contextLength: settings.contextLength,
      threads: settings.threads,
      threadsBatch: settings.threadsBatch,
      maxTokens: settings.maxTokens,
      temperature: settings.temperature,
      topP: settings.topP,
      topK: settings.topK,
      repeatPenalty: settings.repeatPenalty,
      useMmap: settings.useMmap
    };
    const id: number = await native.loadModel(model.filePath, params);
    this.sessionId = id;
    this.modelId = model.id;
    Log.info(`session ${id} ready for ${model.id}`);
    return native.describe(id);
  }

  async chat(
    messages: ChatMsg[],
    settings: AppSettings,
    onToken: (token: string) => void
  ): Promise<GenStatsLite> {
    if (this.sessionId < 0) {
      throw new Error('模型尚未加载，请先在「模型」页选择一个');
    }
    if (this.generating) {
      throw new Error('上一轮回答尚未结束');
    }

    const payload: NativeMessage[] = [];
    for (const m of messages) {
      const item: NativeMessage = { role: m.role, content: m.content };
      payload.push(item);
    }

    const params: NativeParams = {
      contextLength: settings.contextLength,
      threads: settings.threads,
      threadsBatch: settings.threadsBatch,
      maxTokens: settings.maxTokens,
      temperature: settings.temperature,
      topP: settings.topP,
      topK: settings.topK,
      repeatPenalty: settings.repeatPenalty,
      useMmap: settings.useMmap
    };

    this.generating = true;
    try {
      // The native side pushes an EOF sentinel after the last real token. The
      // promise it returns carries no ordering guarantee against the token
      // queue, so waiting for the sentinel is what guarantees the final
      // tokens have actually reached the UI before the caller stops rendering.
      let eofSeen = false;
      const raw: string = await native.generate(this.sessionId, payload, params, (token: string) => {
        if (token === EOF_TOKEN) {
          eofSeen = true;
          return;
        }
        onToken(token);
      });
      if (!eofSeen) {
        Log.warn('generate finished without EOF marker; tail tokens may be missing');
      }
      return JSON.parse(raw) as GenStatsLite;
    } catch (e) {
      Log.error(`generate failed: ${describeError(e)}`);
      throw new Error(describeError(e));
    } finally {
      this.generating = false;
    }
  }

  cancel(): void {
    if (this.sessionId >= 0) {
      native.cancel(this.sessionId);
    }
  }

  release(): void {
    if (this.sessionId >= 0) {
      // Stop first: an in-flight generate holds a reference to the session, and
      // letting it run to completion just to throw the result away keeps
      // several hundred MB resident for no reason.
      if (this.generating) {
        native.cancel(this.sessionId);
      }
      native.release(this.sessionId);
      this.sessionId = -1;
      this.modelId = '';
    }
  }

  /** Metadata-only read. Safe to call before any model is loaded. */
  inspect(path: string): GgufInfo {
    const raw: string = native.inspectGguf(path);
    return JSON.parse(raw) as GgufInfo;
  }

  previewPrompt(messages: ChatMsg[]): string {
    const payload: NativeMessage[] = [];
    for (const m of messages) {
      const item: NativeMessage = { role: m.role, content: m.content };
      payload.push(item);
    }
    return native.renderChatML(payload);
  }
}
