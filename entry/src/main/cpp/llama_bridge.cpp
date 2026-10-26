#include "llama_bridge.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>

#ifdef CAMELHUMP_WITH_LLAMA
#include "llama.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#endif

namespace camelhump {
namespace {

using Clock = std::chrono::steady_clock;

int64_t MsSince(Clock::time_point t0) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - t0).count();
}

// A byte stream from llama_token_to_piece may split a multi-byte UTF-8
// character across tokens. Emitting a partial sequence produces mojibake in the
// UI, so we only forward the longest prefix that ends on a character boundary.
//
// An invalid lead byte used to terminate the scan and return the offset of the
// bad byte. Because the bad byte was never consumed, every later call hit the
// same byte again and the stream stalled permanently. Now the invalid byte is
// skipped as a single opaque byte, so the stream keeps moving.
size_t Utf8CompleteLen(const std::string& s) {
  size_t i = 0;
  while (i < s.size()) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t need = 0;
    if ((c & 0x80) == 0) {
      need = 1;
    } else if ((c & 0xE0) == 0xC0) {
      need = 2;
    } else if ((c & 0xF0) == 0xE0) {
      need = 3;
    } else if ((c & 0xF8) == 0xF0) {
      need = 4;
    } else {
      // Invalid lead byte: skip it as one byte instead of stalling.
      i += 1;
      continue;
    }
    if (i + need > s.size()) break;  // incomplete character, wait for next token
    // Continuation bytes must be 10xxxxxx; if not, the sequence is corrupt.
    bool valid = true;
    for (size_t k = 1; k < need; k++) {
      if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) {
        valid = false;
        break;
      }
    }
    if (!valid) {
      i += 1;
      continue;
    }
    i += need;
  }
  return i;
}

std::string EscapeJson(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:   out += c;
    }
  }
  return out;
}

#ifdef CAMELHUMP_WITH_LLAMA
// ---------------------------------------------------------------------------
// Core selection.
//
// big.LITTLE phones put the fast cores at the *highest* indices, but the exact
// split varies (Kirin 9000s: 0-3 A510, 4-6 A710, 7 Taishan). Reading each
// core's max frequency is the only portable way to tell them apart; index
// guessing breaks on the next SoC.
//
// Returns the number of cores written into `mask`. Zero means "could not
// determine", in which case the caller leaves affinity alone.
// ---------------------------------------------------------------------------
int BuildBigCoreMask(int want, bool* mask) {
  if (want <= 0) return 0;
  struct Core {
    long khz;
    int idx;
  };
  std::vector<Core> cores;
  for (int i = 0; i < GGML_MAX_N_THREADS; ++i) {
    char path[96];
    std::snprintf(path, sizeof(path),
                  "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", i);
    FILE* f = std::fopen(path, "r");
    if (f == nullptr) continue;
    long khz = 0;
    const int got = std::fscanf(f, "%ld", &khz);
    std::fclose(f);
    if (got == 1 && khz > 0) cores.push_back({khz, i});
  }
  if (cores.empty()) return 0;

  std::sort(cores.begin(), cores.end(),
            [](const Core& a, const Core& b) { return a.khz > b.khz; });

  // Only pin when the fast cluster is actually distinguishable. On a uniform
  // SoC this would otherwise pin to an arbitrary subset and lose throughput.
  const long topKhz = cores.front().khz;
  const size_t n = std::min<size_t>(cores.size(), static_cast<size_t>(want));
  int count = 0;
  for (size_t i = 0; i < n; ++i) {
    if (cores[i].khz * 10 < topKhz * 9) break;  // <90% of the fastest core
    mask[cores[i].idx] = true;
    count++;
  }
  return count;
}

// ggml creates its own worker threads, so the only way to keep them off the
// little cores is to hand llama.cpp a pool built with an explicit mask.
// The constructor is fetched through the backend registry rather than linked
// directly: it is a GGML_BACKEND_API symbol and may not be exported in every
// build flavour.
struct ggml_threadpool* NewThreadpool(int nThreads, int* pinned) {
  if (nThreads <= 0) return nullptr;
  ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
  if (dev == nullptr) return nullptr;
  ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
  if (reg == nullptr) return nullptr;
  auto newFn = reinterpret_cast<struct ggml_threadpool* (*)(struct ggml_threadpool_params*)>(
      ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_new"));
  if (newFn == nullptr) return nullptr;

  struct ggml_threadpool_params tpp;
  ggml_threadpool_params_init(&tpp, nThreads);
  const int cnt = BuildBigCoreMask(nThreads, tpp.cpumask);
  if (cnt > 0 && cnt < nThreads) {
    // One worker per selected core; a pool larger than the mask leaves the
    // surplus threads unpinned, which defeats the point.
    tpp.n_threads = cnt;
  }
  if (pinned != nullptr) *pinned = cnt > 0 ? tpp.n_threads : 0;
  // strict_cpu makes placement mandatory and can fail outright on schedulers
  // that disagree with the mask; a soft hint still lands on the fast cluster.
  tpp.strict_cpu = false;
  return newFn(&tpp);
}

void FreeThreadpool(struct ggml_threadpool* tp) {
  if (tp == nullptr) return;
  ggml_backend_dev_t dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
  if (dev == nullptr) return;
  ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
  if (reg == nullptr) return;
  auto freeFn = reinterpret_cast<void (*)(struct ggml_threadpool*)>(
      ggml_backend_reg_get_proc_address(reg, "ggml_threadpool_free"));
  if (freeFn != nullptr) freeFn(tp);
}
#endif


}  // namespace

// ---------------------------------------------------------------------------
// ChatML fallback. Used for the UI preview and when a GGUF carries no template.
// ---------------------------------------------------------------------------
std::string RenderChatML(const std::vector<ChatMessage>& messages, bool addAssistantPrefix) {
  std::string out;
  for (const auto& m : messages) {
    out += "<|im_start|>" + m.role + "\n" + m.content + "<|im_end|>\n";
  }
  if (addAssistantPrefix) out += "<|im_start|>assistant\n";
  return out;
}

bool HasEngine() {
#ifdef CAMELHUMP_WITH_LLAMA
  return true;
#else
  return false;
#endif
}

// ---------------------------------------------------------------------------
// Session implementation
// ---------------------------------------------------------------------------
struct Session::Impl {
#ifdef CAMELHUMP_WITH_LLAMA
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;

  // Bytes of KV cache one token occupies: K and V, each n_layer * n_head_kv *
  // head_dim elements at 2 bytes (f16). Exposed to the UI so the context slider
  // can show what the setting actually costs instead of guessing.
  int64_t KvBytesPerToken() const {
    if (model == nullptr) return 0;
    const int32_t nLayer = llama_model_n_layer(model);
    const int32_t nHead = llama_model_n_head(model);
    const int32_t nHeadKv = llama_model_n_head_kv(model);
    const int32_t nEmbd = llama_model_n_embd(model);
    if (nLayer <= 0 || nHead <= 0 || nHeadKv <= 0 || nEmbd <= 0) return 0;
    const int32_t headDim = nEmbd / nHead;
    return 2LL * nLayer * nHeadKv * headDim * 2;
  }

  int64_t KvCacheBytes(int32_t nCtx) const {
    return KvBytesPerToken() * static_cast<int64_t>(nCtx);
  }

  // ---- prompt cache -------------------------------------------------------
  // Tokens currently resident in the KV cache, in position order. Multi-turn
  // chat re-sends the whole history every time; without this the engine
  // re-prefills N thousand tokens to answer "嗯" .
  std::vector<llama_token> cached;

  // ---- core pinning -------------------------------------------------------
  // ggml spawns its own worker threads, so affinity has to be handed over as a
  // threadpool built with an explicit cpumask -- there is no "set affinity"
  // knob on the context itself.
  struct ggml_threadpool* tp = nullptr;
  struct ggml_threadpool* tpBatch = nullptr;
  int32_t pinnedCores = 0;
#endif
  std::string path;
  GenParams params;
  int32_t nCtx = 0;
  int32_t nCtxTrain = 0;
  int32_t nBatch = 512;
  int64_t kvBytesPerToken = 0;
  bool flashAttn = false;
  bool kvQuantized = false;
  std::mutex mu;

  std::string RenderWithModel(const std::vector<ChatMessage>& messages) {
#ifdef CAMELHUMP_WITH_LLAMA
    std::vector<llama_chat_message> chat;
    chat.reserve(messages.size());
    for (const auto& m : messages) {
      chat.push_back({m.role.c_str(), m.content.c_str()});
    }
    const char* tmpl = llama_model_chat_template(model, nullptr);
    std::vector<char> buf(8192);
    int32_t need = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true,
                                             buf.data(), static_cast<int32_t>(buf.size()));
    if (need > static_cast<int32_t>(buf.size())) {
      buf.resize(static_cast<size_t>(need) + 1);
      need = llama_chat_apply_template(tmpl, chat.data(), chat.size(), true,
                                       buf.data(), static_cast<int32_t>(buf.size()));
    }
    if (need > 0) return std::string(buf.data(), static_cast<size_t>(need));
#endif
    return RenderChatML(messages, true);
  }

  void ClearKv() {
#ifdef CAMELHUMP_WITH_LLAMA
    if (ctx == nullptr) return;
#if defined(CAMELHUMP_LEGACY_KV_API)
    llama_kv_cache_clear(ctx);
#else
    llama_memory_clear(llama_get_memory(ctx), true);
#endif
    cached.clear();
#endif
  }

  // Drops everything from `pos` onwards, keeping the reusable prefix. Returns
  // false when the runtime cannot do a partial removal, in which case the
  // caller has to start over from an empty cache.
  bool TrimKvFrom(int32_t pos) {
#ifdef CAMELHUMP_WITH_LLAMA
    if (ctx == nullptr || pos < 0) return false;
#if defined(CAMELHUMP_LEGACY_KV_API)
    if (!llama_kv_cache_seq_rm(ctx, 0, pos, -1)) return false;
#else
    llama_memory_t mem = llama_get_memory(ctx);
    if (mem == nullptr) return false;
    if (!llama_memory_seq_rm(mem, 0, pos, -1)) return false;
#endif
    if (static_cast<size_t>(pos) < cached.size()) {
      cached.resize(static_cast<size_t>(pos));
    }
    return true;
#endif
    return false;
  }
};

Session::Session() : impl_(new Impl()) {}

Session::~Session() {
#ifdef CAMELHUMP_WITH_LLAMA
  // Pools must outlive the context, so they are released last.
  if (impl_->ctx != nullptr) llama_free(impl_->ctx);
  if (impl_->tpBatch != nullptr && impl_->tpBatch != impl_->tp) FreeThreadpool(impl_->tpBatch);
  if (impl_->tp != nullptr) FreeThreadpool(impl_->tp);
  if (impl_->model != nullptr) llama_model_free(impl_->model);
#endif
}

bool Session::IsLoaded() const {
#ifdef CAMELHUMP_WITH_LLAMA
  return impl_->model != nullptr && impl_->ctx != nullptr;
#else
  return false;
#endif
}

bool Session::Load(const std::string& modelPath, const GenParams& params, std::string* error) {
#ifndef CAMELHUMP_WITH_LLAMA
  if (error) {
    *error = "engine not compiled in: run 'git submodule update --init' then rebuild";
  }
  return false;
#else
  std::lock_guard<std::mutex> lock(impl_->mu);

  static std::once_flag backend_once;
  std::call_once(backend_once, []() { llama_backend_init(); });

  llama_model_params mp = llama_model_default_params();
  // HarmonyOS mmap on Kirin is the single biggest cold-start cost measured in
  // the field (tens of seconds). Default is off; see docs/PERF-NOTES.md.
  //
  // 2025-10 前后 llama.cpp 把 use_mmap / use_mlock 两个 bool 合并成了
  // load_mode 枚举, 单独开 mlock 或 mlock+mmap 现在是一等公民。
  if (params.useMmap && params.useMlock) {
    mp.load_mode = LLAMA_LOAD_MODE_MMAP_MLOCK;
  } else if (params.useMmap) {
    mp.load_mode = LLAMA_LOAD_MODE_MMAP;
  } else if (params.useMlock) {
    mp.load_mode = LLAMA_LOAD_MODE_MLOCK;
  } else {
    mp.load_mode = LLAMA_LOAD_MODE_NONE;
  }
  mp.n_gpu_layers = 0;

  impl_->model = llama_model_load_from_file(modelPath.c_str(), mp);
  if (impl_->model == nullptr) {
    if (error) *error = "failed to load model (unsupported arch or corrupt file)";
    return false;
  }
  impl_->vocab = llama_model_get_vocab(impl_->model);
  if (impl_->vocab == nullptr) {
    if (error) *error = "model has no vocabulary";
    llama_model_free(impl_->model);
    impl_->model = nullptr;
    return false;
  }

  // Never ask for more context than the model was trained on. llama.cpp will
  // honour a larger n_ctx, but without RoPE scaling the extra positions are
  // extrapolation and the output degrades into repetition rather than failing
  // loudly -- which is the worst possible behaviour.
  const int32_t trainCtx = llama_model_n_ctx_train(impl_->model);
  int32_t wantCtx = params.nCtx > 0 ? params.nCtx : 2048;
  if (trainCtx > 0 && wantCtx > trainCtx) {
    wantCtx = trainCtx;
  }

  // Two optimisations that are not universally supported, so they are tried in
  // order and degrade instead of failing the load:
  //
  //   1. flash attention + Q8_0 KV cache  -- fastest, half the cache memory
  //   2. flash attention + F16 KV         -- V quantization needs FA on some archs
  //   3. baseline                          -- whatever the model can actually do
  //
  // Note that quantized V only works together with flash attention in llama.cpp;
  // asking for Q8 KV without FA is rejected at context creation.
  struct Attempt {
    bool attn;
    bool kvQuant;
  };
  const Attempt attempts[] = {{true, true}, {true, false}, {false, false}};

  for (const Attempt& a : attempts) {
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = static_cast<uint32_t>(wantCtx);
    cp.n_batch = 512;
    cp.n_ubatch = 256;
    cp.n_threads = params.nThreads;
    cp.n_threads_batch = params.nThreadsBatch;
    cp.no_perf = true;
    cp.flash_attn_type = a.attn ? LLAMA_FLASH_ATTN_TYPE_ENABLED
                                : LLAMA_FLASH_ATTN_TYPE_DISABLED;
    if (a.kvQuant) {
      cp.type_k = GGML_TYPE_Q8_0;
      cp.type_v = GGML_TYPE_Q8_0;
    }
    impl_->ctx = llama_init_from_model(impl_->model, cp);
    if (impl_->ctx != nullptr) {
      impl_->flashAttn = a.attn;
      impl_->kvQuantized = a.kvQuant;
      break;
    }
  }

  if (impl_->ctx == nullptr) {
    if (error) {
      *error = "failed to create context for n_ctx=" + std::to_string(wantCtx) +
               ". The KV cache alone would be " +
               std::to_string(impl_->KvCacheBytes(wantCtx) / (1024 * 1024)) +
               " MB -- lower the context in settings or pick a smaller model.";
    }
    llama_model_free(impl_->model);
    impl_->model = nullptr;
    return false;
  }

  // Keep the math threads on the fast cluster. This is a hint, not a
  // requirement: when the frequency table is unreadable the pools are still
  // created with the default affinity, which is exactly the old behaviour.
  impl_->tp = NewThreadpool(params.nThreads, &impl_->pinnedCores);
  if (impl_->tp != nullptr) {
    if (params.nThreadsBatch == params.nThreads) {
      impl_->tpBatch = impl_->tp;
    } else {
      impl_->tpBatch = NewThreadpool(params.nThreadsBatch, nullptr);
    }
    llama_attach_threadpool(impl_->ctx, impl_->tp,
                            impl_->tpBatch != nullptr ? impl_->tpBatch : impl_->tp);
  }

  impl_->path = modelPath;
  impl_->params = params;
  impl_->nCtx = static_cast<int32_t>(llama_n_ctx(impl_->ctx));
  impl_->nBatch = static_cast<int32_t>(llama_n_batch(impl_->ctx));
  impl_->nCtxTrain = trainCtx;
  impl_->kvBytesPerToken = impl_->KvBytesPerToken();
  // Q8_0 halves the per-token cost the UI shows on the context slider.
  if (impl_->kvQuantized) impl_->kvBytesPerToken /= 2;
  impl_->cached.clear();
  return true;
#endif
}

bool Session::SmokeTest(const std::string& userText, std::string* outText, std::string* error) {
  std::vector<ChatMessage> msgs;
  msgs.push_back({"user", userText});
  GenParams p = impl_->params;
  p.maxTokens = 8;
  p.temperature = 0.0f;

  std::string acc;
  GenStats stats;
  TokenCallback cb = [&acc](const std::string& piece) {
    acc += piece;
    return acc.size() < 64;  // enough to prove the model emits real text
  };
  bool ok = Generate(msgs, p, cb, &stats, error);
  if (outText) *outText = acc;
  return ok && !acc.empty();
}

bool Session::Generate(const std::vector<ChatMessage>& messages,
                       const GenParams& params,
                       const TokenCallback& onToken,
                       GenStats* stats,
                       std::string* error) {
#ifndef CAMELHUMP_WITH_LLAMA
  if (error) *error = "engine not compiled in";
  return false;
#else
  std::lock_guard<std::mutex> lock(impl_->mu);
  cancelled_ = false;

  if (!IsLoaded()) {
    if (error) *error = "model not loaded";
    return false;
  }

  auto t_start = Clock::now();
  GenStats local;
  GenStats* st = stats ? stats : &local;

  const std::string prompt = impl_->RenderWithModel(messages);

  // ---- tokenize (real count, never estimated on the ArkTS side) ----
  int32_t n_tokens = -llama_tokenize(impl_->vocab, prompt.c_str(),
                                     static_cast<int32_t>(prompt.size()),
                                     nullptr, 0, true, true);
  if (n_tokens <= 0) {
    if (error) *error = "tokenize failed";
    return false;
  }
  std::vector<llama_token> tokens(static_cast<size_t>(n_tokens));
  if (llama_tokenize(impl_->vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()),
                     tokens.data(), n_tokens, true, true) < 0) {
    if (error) *error = "tokenize failed on second pass";
    return false;
  }
  st->promptTokens = n_tokens;

  // Two different limits were being conflated here, and the result was a
  // nonsensical rejection: with context 2048 and an output cap of 2048 the
  // computed budget was 0, so a 21-token prompt was refused with "this model
  // allows 0 tokens".
  //
  // The only hard limit is that the prompt has to fit in the context window --
  // llama.cpp aborts the whole process on a batch overflow, which a user reads
  // as "the app randomly closes". The output cap is a soft budget: whatever
  // room is left after the prompt.
  if (n_tokens >= impl_->nCtx) {
    if (error) {
      *error = "conversation is " + std::to_string(n_tokens) + " tokens but the model context is " +
               std::to_string(impl_->nCtx) + ". Shorten the chat or raise the context in settings.";
    }
    return false;
  }

  // Clamp rather than reject: asking for more output than the window can hold
  // is a preference, not an error -- the answer just ends sooner.
  const int32_t room = impl_->nCtx - n_tokens;
  int32_t outputBudget = std::min(params.maxTokens, room);
  if (outputBudget < 1) outputBudget = 1;

  // ---- prompt cache --------------------------------------------------------
  // Multi-turn chat re-sends the whole history every turn. Reusing the KV for
  // the unchanged prefix turns a re-prefill of several thousand tokens into a
  // decode of the handful that actually changed -- usually the difference
  // between a 3 s first token and a 200 ms one.
  size_t reuse = 0;
  while (reuse < impl_->cached.size() && reuse < tokens.size() &&
         impl_->cached[reuse] == tokens[reuse]) {
    ++reuse;
  }
  // Identical prompt (a retry, say): leave the last token out of the cache so
  // this turn still has logits to sample from.
  if (reuse == tokens.size() && reuse > 0) --reuse;

  if (reuse == 0) {
    impl_->ClearKv();
  } else if (!impl_->TrimKvFrom(static_cast<int32_t>(reuse))) {
    // Partial removal refused: fall back to a full prefill rather than risk
    // decoding on top of a stale cache.
    impl_->ClearKv();
    reuse = 0;
  }
  st->reusedTokens = static_cast<int32_t>(reuse);

  // ---- chunked prefill, with explicit positions ----
  // Positions are written by hand instead of relying on llama_decode's
  // auto-numbering: with a partially filled cache the start offset matters, and
  // being explicit keeps reuse independent of the runtime's bookkeeping.
  const int32_t prefillFrom = static_cast<int32_t>(reuse);
  llama_batch pre = llama_batch_init(
      std::max(1, std::min(impl_->nBatch, n_tokens - prefillFrom)), 0, 1);
  for (int32_t i = prefillFrom; i < n_tokens; ) {
    if (cancelled_) {
      llama_batch_free(pre);
      st->cancelled = true;
      st->finish = FINISH_CANCELLED;
      return true;
    }
    const int32_t cur = std::min(impl_->nBatch, n_tokens - i);
    pre.n_tokens = cur;
    for (int32_t k = 0; k < cur; ++k) {
      pre.token[k] = tokens[i + k];
      pre.pos[k] = i + k;
      pre.n_seq_id[k] = 1;
      pre.seq_id[k][0] = 0;
      pre.logits[k] = (k == cur - 1) ? 1 : 0;
    }
    if (llama_decode(impl_->ctx, pre) != 0) {
      llama_batch_free(pre);
      if (error) *error = "decode failed during prefill (model may need more RAM)";
      return false;
    }
    // Track the cache block by block rather than once at the end: a cancel can
    // land between two chunks, and `cached` has to describe what is really in
    // the KV cache at that moment or the next turn's prefix match is wrong.
    impl_->cached.insert(impl_->cached.end(),
                         tokens.begin() + i, tokens.begin() + i + cur);
    i += cur;
  }
  llama_batch_free(pre);

  // ---- sampler chain ----
  llama_sampler_chain_params sp = llama_sampler_chain_default_params();
  sp.no_perf = true;
  llama_sampler* smpl = llama_sampler_chain_init(sp);
  if (params.topK > 0) llama_sampler_chain_add(smpl, llama_sampler_init_top_k(params.topK));
  if (params.topP > 0.0f && params.topP < 1.0f) {
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(params.topP, 1));
  }
  if (params.repeatPenalty > 1.0f) {
    // 2025-09 之后 llama_sampler_init_penalties 多了首个 n_vocab 参数。
    llama_sampler_chain_add(smpl, llama_sampler_init_penalties(
                                      llama_vocab_n_tokens(impl_->vocab), 64,
                                      params.repeatPenalty, 0.0f, 0.0f));
  }
  if (params.temperature <= 0.0f) {
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
  } else {
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(params.temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(static_cast<uint32_t>(
                                      params.seed < 0 ? LLAMA_DEFAULT_SEED : params.seed)));
  }

  // ---- decode loop ----
  std::string pending;
  bool user_stopped = false;
  int64_t first_token_ms = -1;
  FinishReason finish = FINISH_MAX_TOKENS;
  // One reusable single-token batch; allocating per token would mean a malloc
  // and free on every step of the answer.
  llama_batch one = llama_batch_init(1, 0, 1);

  // outputBudget, not params.maxTokens: the window may have less room left than
  // the user asked for, and running past the end of the KV cache aborts.
  for (int32_t i = 0; i < outputBudget; ++i) {
    if (cancelled_) {
      st->cancelled = true;
      finish = FINISH_CANCELLED;
      break;
    }

    const llama_token id = llama_sampler_sample(smpl, impl_->ctx, -1);
    if (llama_vocab_is_eog(impl_->vocab, id)) {
      finish = FINISH_EOS;
      break;
    }

    char piece[512];
    const int32_t len = llama_token_to_piece(impl_->vocab, id, piece, sizeof(piece), 0, true);
    if (len > 0) {
      pending.append(piece, static_cast<size_t>(len));
      const size_t safe = Utf8CompleteLen(pending);
      if (safe > 0) {
        std::string chunk = pending.substr(0, safe);
        pending.erase(0, safe);
        if (first_token_ms < 0) first_token_ms = MsSince(t_start);
        if (onToken && !onToken(chunk)) {
          user_stopped = true;
          finish = FINISH_STOPPED;
          break;
        }
      }
    }

    st->decodedTokens++;

    // Feed the token just sampled back in so the next one can be sampled. The
    // position is explicit, and mirrors what is already in the cache.
    one.n_tokens = 1;
    one.token[0] = id;
    one.pos[0] = static_cast<llama_pos>(impl_->cached.size());
    one.n_seq_id[0] = 1;
    one.seq_id[0][0] = 0;
    one.logits[0] = 1;
    if (llama_decode(impl_->ctx, one) != 0) {
      // Previously this broke out silently and the caller got a truncated
      // answer with no indication that anything went wrong.
      finish = FINISH_DECODE_ERROR;
      break;
    }
    impl_->cached.push_back(id);
  }
  llama_batch_free(one);

  if (!pending.empty() && onToken && !user_stopped) {
    if (first_token_ms < 0) first_token_ms = MsSince(t_start);
    onToken(pending);
  }

  llama_sampler_free(smpl);

  st->finish = finish;
  if (finish == FINISH_CANCELLED) st->cancelled = true;

  const int64_t total = MsSince(t_start);
  st->firstTokenMs = first_token_ms < 0 ? 0 : first_token_ms;
  st->totalMs = total;
  if (st->decodedTokens > 0 && total > 0) {
    st->tokensPerSecond = st->decodedTokens * 1000.0 / static_cast<double>(total);
  }

  // Zero tokens plus an immediate EOG is a prompt-format problem far more often
  // than a broken model. Reporting success with an empty string left the user
  // staring at a blank bubble with nothing to act on, so this surfaces as a
  // real error instead.
  if (st->decodedTokens == 0 && !st->cancelled) {
    if (finish == FINISH_EOS) {
      if (error) {
        *error = "the model ended the answer immediately (chat template mismatch, or the "
                 "context window is already full)";
      }
      return false;
    }
    if (finish == FINISH_DECODE_ERROR) {
      if (error) {
        *error = "the engine failed before producing any token (model likely too large "
                 "for this device's memory)";
      }
      return false;
    }
  }
  return true;
#endif
}

void Session::Cancel() { cancelled_ = true; }

std::string Session::Describe() const {
  std::string j = "{";
#ifdef CAMELHUMP_WITH_LLAMA
  j += "\"loaded\":true";
  j += ",\"nCtx\":" + std::to_string(impl_->nCtx);
  j += ",\"nCtxTrain\":" + std::to_string(impl_->nCtxTrain);
  j += ",\"nBatch\":" + std::to_string(impl_->nBatch);
  j += ",\"kvBytesPerToken\":" + std::to_string(impl_->kvBytesPerToken);
  j += ",\"flashAttn\":" + std::string(impl_->flashAttn ? "true" : "false");
  j += ",\"kvQuantized\":" + std::string(impl_->kvQuantized ? "true" : "false");
  j += ",\"pinnedCores\":" + std::to_string(impl_->pinnedCores);
  j += ",\"modelSize\":" + std::to_string(llama_model_size(impl_->model));
  j += ",\"modelParams\":" + std::to_string(llama_model_n_params(impl_->model));
  j += ",\"quant\":\"";
  char desc[128] = {0};
  llama_model_desc(impl_->model, desc, sizeof(desc));
  j += EscapeJson(desc);
  j += "\"";
#else
  j += "\"loaded\":false,\"engine\":\"stub\"";
#endif
  j += ",\"path\":\"" + EscapeJson(impl_->path) + "\"";
  j += "}";
  return j;
}

}  // namespace camelhump
