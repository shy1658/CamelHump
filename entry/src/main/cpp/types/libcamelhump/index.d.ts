/**
 * camelhump native bridge.
 *
 * Every function that can take longer than a frame is async. `inspectGguf` is
 * the exception: it reads metadata only, never weights, so it returns inline.
 */

export interface GenParams {
  /** Context window in tokens. Clamped to [512, 8192] in native code. */
  contextLength?: number;
  /** Decode threads. 4 keeps work on the small-core cluster and limits heat. */
  threads?: number;
  /** Prefill threads, usually lower than `threads`. */
  threadsBatch?: number;
  maxTokens?: number;
  temperature?: number;
  topP?: number;
  topK?: number;
  repeatPenalty?: number;
  /** Leave false on HarmonyOS: mmap cold start on Kirin is very slow. */
  useMmap?: boolean;
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface GenStats {
  promptTokens: number;
  decodedTokens: number;
  firstTokenMs: number;
  totalMs: number;
  tokensPerSecond: number;
  cancelled: boolean;
}

/** Mirrors camelhump::GgufInfo. All fields come from the file header. */
export interface GgufInfo {
  valid: boolean;
  error: string;
  version: number;
  tensorCount: number;
  kvCount: number;
  fileSize: number;
  architecture: string;
  name: string;
  sizeLabel: string;
  fileType: number;
  quant: string;
  contextLength: number;
  blockCount: number;
  headCount: number;
  embeddingLength: number;
  hasChatTemplate: boolean;
  chatTemplate: string;
  tensorBytes: number;
  dataOffset: number;
  complete: boolean;
}

/**
 * Reads GGUF metadata. Returns the JSON form of GgufInfo.
 * Never loads tensor data, so a 4 GB file costs the same as a 400 MB one.
 */
export const inspectGguf: (path: string) => string;

/** Resolves with a session id. Rejects with a human-readable reason. */
export const loadModel: (path: string, params?: GenParams) => Promise<number>;

/**
 * Streams tokens through `onToken`. Resolves with the JSON form of GenStats.
 * Cancellation goes through `cancel(sessionId)`, not through onToken's return.
 */
export const generate: (
  sessionId: number,
  messages: ChatMessage[],
  params: GenParams,
  onToken: (token: string) => void
) => Promise<string>;

export const cancel: (sessionId: number) => boolean;

export const release: (sessionId: number) => boolean;

/** JSON describing the loaded model: nCtx, parameter count, quant. */
export const describe: (sessionId: number) => string;

/** False when built without llama.cpp — the UI shows a setup hint instead. */
export const hasEngine: () => boolean;

/** ChatML rendering, for the prompt preview panel. */
export const renderChatML: (messages: ChatMessage[]) => string;
