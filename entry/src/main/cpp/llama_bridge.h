/*
 * llama_bridge.h — thin, stable wrapper over llama.cpp.
 *
 * Everything above this line (NAPI, ArkTS) talks to these few symbols only, so
 * swapping the engine later (MindSpore Lite NPU, or the system model API when
 * Huawei opens it) means writing one more implementation of Session, not
 * touching the UI.
 */

#ifndef CAMELHUMP_LLAMA_BRIDGE_H
#define CAMELHUMP_LLAMA_BRIDGE_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace camelhump {

struct ChatMessage {
  std::string role;     // "system" | "user" | "assistant"
  std::string content;
};

struct GenParams {
  int32_t nCtx = 2048;
  int32_t nThreads = 4;       // small-core cluster by default; raising this heats the SoC
  int32_t nThreadsBatch = 2;
  int32_t maxTokens = 512;
  float temperature = 0.7f;
  float topP = 0.9f;
  int32_t topK = 40;
  float repeatPenalty = 1.1f;
  int64_t seed = -1;
  bool useMmap = false;       // HarmonyOS mmap cold start is pathological; see docs
  bool useMlock = false;
};

/** Why generation stopped. Surfaced to the UI so an empty answer is diagnosable. */
enum FinishReason {
  FINISH_NONE = 0,
  FINISH_EOS,           // the model emitted its end-of-generation token
  FINISH_MAX_TOKENS,    // hit the output budget
  FINISH_CANCELLED,     // the user pressed stop
  FINISH_DECODE_ERROR,  // llama_decode failed mid-generation
  FINISH_STOPPED,       // the token consumer asked to stop
};

inline const char* FinishName(FinishReason r) {
  switch (r) {
    case FINISH_EOS:          return "eos";
    case FINISH_MAX_TOKENS:   return "max_tokens";
    case FINISH_CANCELLED:    return "cancelled";
    case FINISH_DECODE_ERROR: return "decode_error";
    case FINISH_STOPPED:      return "stopped";
    default:                  return "none";
  }
}

struct GenStats {
  int32_t promptTokens = 0;
  /** Prompt tokens served from the KV cache instead of being re-prefilled. */
  int32_t reusedTokens = 0;
  int32_t decodedTokens = 0;
  int64_t loadMs = 0;
  int64_t firstTokenMs = 0;
  int64_t totalMs = 0;
  double tokensPerSecond = 0.0;
  bool cancelled = false;
  // Why the loop stopped. Without this a run that produced zero tokens is
  // indistinguishable from a run that produced nothing the UI could show --
  // the user just sees an empty bubble and has nothing to report.
  FinishReason finish = FINISH_NONE;
};

// Return false from the callback to stop generation early.
using TokenCallback = std::function<bool(const std::string&)>;

class Session {
 public:
  Session();
  ~Session();

  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  bool Load(const std::string& modelPath, const GenParams& params, std::string* error);
  bool IsLoaded() const;

  // Non-streaming helper for the tokenizer smoke test: renders the chat, runs
  // one decode step, returns whether the model produced something sane.
  bool SmokeTest(const std::string& userText, std::string* outText, std::string* error);

  bool Generate(const std::vector<ChatMessage>& messages,
                const GenParams& params,
                const TokenCallback& onToken,
                GenStats* stats,
                std::string* error);

  void Cancel();
  std::string Describe() const;  // JSON: model path, n_ctx, backend, etc.

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
  std::atomic<bool> cancelled_{false};
};

// Render a chat with ChatML. Used by the UI to preview what will be sent, and
// as the fallback when a GGUF carries no tokenizer.chat_template. Real
// generation prefers the model's own template inside Session.
std::string RenderChatML(const std::vector<ChatMessage>& messages, bool addAssistantPrefix);

// True when the library was compiled with llama.cpp available.
bool HasEngine();

}  // namespace camelhump

#endif  // CAMELHUMP_LLAMA_BRIDGE_H
