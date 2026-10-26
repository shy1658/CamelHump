/**
 * Shared types. Kept in one file so page code and services never drift apart.
 */

export type Role = 'system' | 'user' | 'assistant';

/**
 * A chat message.
 *
 * Streaming mutates `content` in place on every flush. ArkUI only re-renders a
 * ForEach item when its key changes, so the message carries a `rev` counter that
 * is bumped on every mutation and folded into the key. Without it the bubble was
 * created empty and never redrawn -- the model was answering, but the screen
 * stayed blank for the whole turn.
 */
@Observed
export class ChatMsg {
  id: string = '';
  role: Role = 'user';
  content: string = '';
  createdAt: number = 0;
  /** Bumped whenever `content` / `stats` change; used to force a redraw. */
  rev: number = 0;
  stats?: GenStatsLite;
  pending?: boolean;
  failed?: boolean;

  constructor(id: string, role: Role, content: string, createdAt: number) {
    this.id = id;
    this.role = role;
    this.content = content;
    this.createdAt = createdAt;
  }
}

export interface GenStatsLite {
  promptTokens: number;
  /** Prompt tokens answered from the KV cache instead of re-prefilled. */
  reusedTokens: number;
  decodedTokens: number;
  firstTokenMs: number;
  totalMs: number;
  tokensPerSecond: number;
  cancelled: boolean;
  /** "eos" | "max_tokens" | "cancelled" | "decode_error" | "stopped" | "none" */
  finish: string;
}

/** Result of reading a GGUF header. Mirrors camelhump::GgufInfo. */
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

/** Subset of the payload returned by the native `describe()` call. */
export interface EngineInfo {
  /** Context actually allocated; may be below what settings asked for. */
  nCtx: number;
  /** What the model was trained on. Asking for more degrades output quality. */
  nCtxTrain: number;
  /** Bytes of KV cache a single token costs with this model. */
  kvBytesPerToken: number;
  /** Flash attention actually enabled for this context. */
  flashAttn: boolean;
  /** KV cache quantized to Q8_0 (halves the per-token cost). */
  kvQuantized: boolean;
  /** Worker threads pinned to the fast cluster; 0 when pinning was skipped. */
  pinnedCores: number;
}

/** A model the app has adopted into its own storage. */
export interface ModelEntry {
  id: string;
  displayName: string;
  dirPath: string;
  filePath: string;
  sizeBytes: number;
  architecture: string;
  quant: string;
  contextLength: number;
  blockCount: number;
  hasChatTemplate: boolean;
  importedAt: number;
  /** false when the file is shorter than its own tensor table claims. */
  complete: boolean;
  /** true when the model came from the built-in download flow. */
  curated: boolean;
}

export interface ModelMeta {
  version: number;
  id: string;
  displayName: string;
  architecture: string;
  quant: string;
  contextLength: number;
  blockCount: number;
  hasChatTemplate: boolean;
  importedAt: number;
  curated: boolean;
}

export interface AppSettings {
  contextLength: number;
  threads: number;
  threadsBatch: number;
  temperature: number;
  topP: number;
  topK: number;
  maxTokens: number;
  repeatPenalty: number;
  systemPrompt: string;
  useMmap: boolean;
}

/** One entry in the curated model list. */
export interface CuratedModel {
  id: string;
  name: string;
  params: string;
  quant: string;
  sizeMb: number;
  url: string;
  sha256: string;
  note: string;
  minRamGb: number;
}
