/*
 * napi_init.cpp — the only surface ArkTS sees.
 *
 * Design rules enforced here:
 *   1. No inference work ever runs on the JS thread. Prefill, decode and model
 *      loading all go through napi_async_work.
 *   2. Tokens are pushed with a blocking threadsafe function, so ordering is
 *      guaranteed and nothing is dropped under load.
 *   3. Every native failure returns a sentence a user can act on, never a code.
 */

#include <napi/native_api.h>

#include <hilog/log.h>

#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "gguf_inspector.h"
#include "llama_bridge.h"

#define LOG_DOMAIN 0x3200
#define LOG_TAG "CamelHump"

// Sentinel pushed through the token channel right before the stream ends.
// The ArkTS side recognises it and knows every real token has been delivered.
constexpr const char* kEofToken = "__CAMELEHUMP_EOF__";

namespace {

using camelhump::ChatMessage;
using camelhump::GenParams;
using camelhump::GenStats;
using camelhump::Session;

std::mutex g_sessions_mu;
// shared_ptr, not unique_ptr: an async generation task may still be running on
// the worker thread when the UI releases the session. With unique_ptr the
// erase() would destroy the Session while the task is mid-Generate(), which is
// a use-after-free that only shows up as a random crash mid-answer.
// Every async task keeps its own reference alive for the duration.
std::unordered_map<int32_t, std::shared_ptr<Session>> g_sessions;
int32_t g_next_session_id = 1;

// Returns a strong reference so the caller can safely use the session after
// the lock is dropped.
std::shared_ptr<Session> FindSession(int32_t id) {
  std::lock_guard<std::mutex> lock(g_sessions_mu);
  auto it = g_sessions.find(id);
  return it == g_sessions.end() ? nullptr : it->second;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
std::string GetString(napi_env env, napi_value value) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) return "";
  std::string out(len, '\0');
  size_t copied = 0;
  napi_get_value_string_utf8(env, value, &out[0], len + 1, &copied);
  return out;
}

bool GetProp(napi_env env, napi_value obj, const char* name, napi_value* out) {
  return napi_get_named_property(env, obj, name, out) == napi_ok;
}

int32_t GetIntProp(napi_env env, napi_value obj, const char* name, int32_t fallback) {
  napi_value v;
  if (!GetProp(env, obj, name, &v)) return fallback;
  int32_t out = fallback;
  if (napi_get_value_int32(env, v, &out) != napi_ok) return fallback;
  return out;
}

double GetDoubleProp(napi_env env, napi_value obj, const char* name, double fallback) {
  napi_value v;
  if (!GetProp(env, obj, name, &v)) return fallback;
  double out = fallback;
  if (napi_get_value_double(env, v, &out) != napi_ok) return fallback;
  return out;
}

bool GetBoolProp(napi_env env, napi_value obj, const char* name, bool fallback) {
  napi_value v;
  if (!GetProp(env, obj, name, &v)) return fallback;
  bool out = fallback;
  if (napi_get_value_bool(env, v, &out) != napi_ok) return fallback;
  return out;
}

GenParams ParseParams(napi_env env, napi_value obj) {
  GenParams p;
  if (obj == nullptr) return p;
  napi_valuetype t = napi_undefined;
  if (napi_typeof(env, obj, &t) != napi_ok || t != napi_object) return p;

  p.nCtx = GetIntProp(env, obj, "contextLength", p.nCtx);
  p.nThreads = GetIntProp(env, obj, "threads", p.nThreads);
  p.nThreadsBatch = GetIntProp(env, obj, "threadsBatch", p.nThreadsBatch);
  p.maxTokens = GetIntProp(env, obj, "maxTokens", p.maxTokens);
  p.topK = GetIntProp(env, obj, "topK", p.topK);
  p.temperature = static_cast<float>(GetDoubleProp(env, obj, "temperature", p.temperature));
  p.topP = static_cast<float>(GetDoubleProp(env, obj, "topP", p.topP));
  p.repeatPenalty = static_cast<float>(GetDoubleProp(env, obj, "repeatPenalty", p.repeatPenalty));
  p.useMmap = GetBoolProp(env, obj, "useMmap", p.useMmap);

  // Clamp to values a phone can survive. A 32k context on a 1.5B model allocates
  // KV cache the app will never get from the system.
  if (p.nCtx < 512) p.nCtx = 512;
  if (p.nCtx > 8192) p.nCtx = 8192;
  if (p.nThreads < 1) p.nThreads = 1;
  if (p.nThreads > 8) p.nThreads = 8;
  if (p.maxTokens < 16) p.maxTokens = 16;
  if (p.maxTokens > 4096) p.maxTokens = 4096;
  return p;
}

bool ParseMessages(napi_env env, napi_value arr, std::vector<ChatMessage>* out) {
  bool isArray = false;
  if (napi_is_array(env, arr, &isArray) != napi_ok || !isArray) return false;
  uint32_t len = 0;
  if (napi_get_array_length(env, arr, &len) != napi_ok) return false;
  for (uint32_t i = 0; i < len; ++i) {
    napi_value item;
    if (napi_get_element(env, arr, i, &item) != napi_ok) return false;
    napi_value role, content;
    if (!GetProp(env, item, "role", &role) || !GetProp(env, item, "content", &content)) return false;
    out->push_back({GetString(env, role), GetString(env, content)});
  }
  return true;
}

napi_value MakeString(napi_env env, const std::string& s) {
  napi_value out = nullptr;
  napi_create_string_utf8(env, s.c_str(), s.size(), &out);
  return out;
}

// ---------------------------------------------------------------------------
// inspectGguf(path) -> JSON string   (synchronous: metadata only, no weights)
// ---------------------------------------------------------------------------
napi_value NapiInspectGguf(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) return MakeString(env, "{\"valid\":false,\"error\":\"missing path\"}");

  const std::string path = GetString(env, args[0]);
  const camelhump::GgufInfo result = camelhump::InspectGguf(path);
  if (!result.valid) {
    OH_LOG_WARN(LOG_APP, "inspect failed: %{public}s", result.error.c_str());
  }
  return MakeString(env, camelhump::ToJson(result));
}

// ---------------------------------------------------------------------------
// loadModel(path, params) -> Promise<sessionId>
// ---------------------------------------------------------------------------
struct LoadWork {
  napi_env env = nullptr;
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::string path;
  GenParams params;
  std::string error;
  int32_t sessionId = -1;
  int64_t elapsedMs = 0;
};

void LoadExecute(napi_env, void* data) {
  auto* w = static_cast<LoadWork*>(data);
  auto session = std::make_unique<Session>();
  const auto t0 = std::chrono::steady_clock::now();
  if (!session->Load(w->path, w->params, &w->error)) {
    return;
  }
  w->elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                     std::chrono::steady_clock::now() - t0)
                     .count();
  std::lock_guard<std::mutex> lock(g_sessions_mu);
  w->sessionId = g_next_session_id++;
  g_sessions[w->sessionId] = std::move(session);
}
void LoadComplete(napi_env env, napi_status status, void* data) {
  auto* w = static_cast<LoadWork*>(data);
  if (w->sessionId < 0) {
    napi_value msg = MakeString(env, w->error.empty() ? "load failed" : w->error);
    napi_value err = nullptr;
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, w->deferred, err);
  } else {
    napi_value result = nullptr;
    napi_create_int32(env, w->sessionId, &result);
    napi_resolve_deferred(env, w->deferred, result);
    OH_LOG_INFO(LOG_APP, "model loaded in %{public}lld ms as session %{public}d",
                static_cast<long long>(w->elapsedMs), w->sessionId);
  }
  napi_delete_async_work(env, w->work);
  delete w;
}

napi_value NapiLoadModel(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  napi_create_promise(env, &deferred, &promise);

  if (argc < 1) {
    napi_value msg = MakeString(env, "loadModel requires a model path");
    napi_value err = nullptr;
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, deferred, err);
    return promise;
  }

  auto* w = new LoadWork();
  w->env = env;
  w->deferred = deferred;
  w->path = GetString(env, args[0]);
  w->params = ParseParams(env, argc >= 2 ? args[1] : nullptr);

  napi_value resourceName = MakeString(env, "CamelHumpLoad");
  napi_create_async_work(env, nullptr, resourceName, LoadExecute, LoadComplete, w, &w->work);
  napi_queue_async_work(env, w->work);
  return promise;
}

// ---------------------------------------------------------------------------
// generate(sessionId, messages, params, onToken) -> Promise<statsJson>
// ---------------------------------------------------------------------------
struct GenWork;

// Settles the promise exactly once. Called from the JS thread only.
void SettleGenPromise(napi_env env, napi_deferred deferred, const GenStats& stats,
                       const std::string& error, bool ok) {
  if (!ok) {
    napi_value msg = MakeString(env, error.empty() ? "generation failed" : error);
    napi_value err = nullptr;
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, deferred, err);
    return;
  }
  std::string json = "{";
  json += "\"promptTokens\":" + std::to_string(stats.promptTokens);
  json += ",\"reusedTokens\":" + std::to_string(stats.reusedTokens);
  json += ",\"decodedTokens\":" + std::to_string(stats.decodedTokens);
  json += ",\"firstTokenMs\":" + std::to_string(stats.firstTokenMs);
  json += ",\"totalMs\":" + std::to_string(stats.totalMs);
  json += ",\"tokensPerSecond\":" + std::to_string(stats.tokensPerSecond);
  json += ",\"cancelled\":" + std::string(stats.cancelled ? "true" : "false");
  json += ",\"finish\":\"";
  json += FinishName(stats.finish);
  json += "\"";
  json += "}";
  napi_value result = MakeString(env, json);
  napi_resolve_deferred(env, deferred, result);
}

struct GenWork {
  napi_env env = nullptr;
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  napi_threadsafe_function tsfn = nullptr;
  // Strong reference: keeps the Session alive even if the UI releases it
  // while this task is still generating.
  std::shared_ptr<Session> session;
  std::vector<ChatMessage> messages;
  GenParams params;
  GenStats stats;
  std::string error;
  bool ok = false;
  // The EOF sentinel has been queued, so the promise will be settled by the
  // token callback.
  bool eofQueued = false;
  // The token channel is exhausted: every real token has reached the JS
  // thread and the promise has been settled.
  bool eofDelivered = false;
};

// Called when the token channel is fully released. The GenWork reference it
// holds is what keeps the work item alive until the last token callback has
// run -- the async work alone is not enough, because the work can complete
// while the token queue is still draining.
void TokenChannelFinalize(napi_env, void* finalize_data, void*) {
  delete static_cast<std::shared_ptr<GenWork>*>(finalize_data);
}

// The token callback runs on the JS thread. The EOF sentinel is the last
// item in the queue, so by the time it is delivered every real token has
// already been handed to the UI. Settling the promise from here removes the
// race that used to drop the tail of an answer: the promise used to be
// settled from the async-work completion callback, which has no ordering
// guarantee relative to the token queue.
void TokenCallJs(napi_env env, napi_value js_cb, void* context, void* data) {
  auto* piece = static_cast<std::string*>(data);
  auto* work = static_cast<GenWork*>(context);

  if (work != nullptr && piece != nullptr && piece->compare(kEofToken) == 0) {
    work->eofDelivered = true;
    // Copy everything we need before releasing the channel: the release can
    // run the finalizer, which drops the last reference to the work item.
    napi_threadsafe_function tsfn = work->tsfn;
    work->tsfn = nullptr;
    GenStats stats = work->stats;
    std::string error = work->error;
    bool ok = work->ok;
    napi_deferred deferred = work->deferred;
    if (tsfn != nullptr) {
      napi_release_threadsafe_function(tsfn, napi_tsfn_release);
    }
    SettleGenPromise(env, deferred, stats, error, ok);
    delete piece;
    return;
  }

  if (env != nullptr && js_cb != nullptr) {
    napi_value arg = nullptr;
    napi_create_string_utf8(env, piece->c_str(), piece->size(), &arg);
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value ignored = nullptr;
    napi_call_function(env, undefined, js_cb, 1, &arg, &ignored);
  }
  delete piece;
}

void GenExecute(napi_env, void* data) {
  auto* holder = static_cast<std::shared_ptr<GenWork>*>(data);
  GenWork* w = holder->get();
  if (w->session == nullptr) {
    w->error = "session released";
    return;
  }
  camelhump::TokenCallback cb = [w](const std::string& piece) {
    auto* copy = new std::string(piece);
    // Non-blocking on purpose. The queue is unbounded (max_queue_size 0), so
    // nothing is ever dropped, and a blocking call would deadlock outright if
    // the runtime happened to run this async work on the JS thread itself --
    // which presents as "the model never says anything" rather than an error.
    napi_status st = napi_call_threadsafe_function(w->tsfn, copy, napi_tsfn_nonblocking);
    if (st != napi_ok) {
      delete copy;
      return false;
    }
    return true;
  };
  w->ok = w->session->Generate(w->messages, w->params, cb, &w->stats, &w->error);

  // End-of-stream marker. The promise is settled from the token callback that
  // receives this marker, which guarantees every real token was delivered
  // first. Settling it from the async-work completion callback instead had no
  // ordering guarantee against the token queue, so the last few tokens could
  // arrive after the promise resolved and be dropped by the UI.
  auto* eof = new std::string(kEofToken);
  w->eofQueued = true;
  napi_call_threadsafe_function(w->tsfn, eof, napi_tsfn_nonblocking);
}

void GenComplete(napi_env env, napi_status /*status*/, void* data) {
  auto* holder = static_cast<std::shared_ptr<GenWork>*>(data);
  GenWork* w = holder->get();

  // The promise is settled by the EOF token callback, not here: this
  // completion callback has no ordering guarantee relative to the token
  // queue, so settling here could resolve the promise before the last
  // tokens were delivered.
  //
  // The token channel is deliberately NOT released here when the EOF marker
  // was queued. Releasing it would close the queue and discard the tokens
  // still waiting to be delivered, which is exactly the bug this ordering
  // fix removes.
  if (!w->eofQueued) {
    // Generation failed before it could queue the marker. Settle here so the
    // promise never hangs.
    if (w->tsfn != nullptr) {
      napi_release_threadsafe_function(w->tsfn, napi_tsfn_release);
      w->tsfn = nullptr;
    }
    SettleGenPromise(env, w->deferred, w->stats, w->error, w->ok);
  }

  napi_delete_async_work(env, w->work);
  delete holder;
}

napi_value NapiGenerate(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

  napi_value promise = nullptr;
  napi_deferred deferred = nullptr;
  napi_create_promise(env, &deferred, &promise);

  auto reject = [&](const std::string& message) {
    napi_value msg = MakeString(env, message);
    napi_value err = nullptr;
    napi_create_error(env, nullptr, msg, &err);
    napi_reject_deferred(env, deferred, err);
    return promise;
  };

  if (argc < 4) return reject("generate requires (sessionId, messages, params, onToken)");

  int32_t sessionId = -1;
  if (napi_get_value_int32(env, args[0], &sessionId) != napi_ok) {
    return reject("sessionId must be a number");
  }
  auto session = FindSession(sessionId);
  if (session == nullptr) return reject("session is not loaded");

  // GenWork is owned by a shared_ptr because two independent parties hold a
  // reference to it: the async work item and the token channel callback. The
  // work item finishes first, but the token queue may still be draining.
  auto w = std::make_shared<GenWork>();
  w->env = env;
  w->deferred = deferred;
  w->session = session;
  w->params = ParseParams(env, args[2]);

  if (!ParseMessages(env, args[1], &w->messages) || w->messages.empty()) {
    return reject("messages must be a non-empty array of {role, content}");
  }

  napi_valuetype cbType = napi_undefined;
  napi_typeof(env, args[3], &cbType);
  if (cbType != napi_function) {
    return reject("onToken must be a function");
  }

  napi_value tsfnName = MakeString(env, "CamelHumpToken");
  // The finalizer holds the reference that keeps the work item alive until
  // the token queue is drained.
  auto* tsfnHolder = new std::shared_ptr<GenWork>(w);
  napi_status tsfnStatus = napi_create_threadsafe_function(
      env, args[3], nullptr, tsfnName,
      0,   // unlimited queue: never drop a token
      1,   // one native thread produces tokens
      tsfnHolder, TokenChannelFinalize,
      w.get(),   // context: lets the token callback reach the work item
      TokenCallJs, &w->tsfn);
  if (tsfnStatus != napi_ok) {
    delete tsfnHolder;
    return reject("failed to create token channel");
  }

  napi_value resourceName = MakeString(env, "CamelHumpGenerate");
  // The async work keeps its own reference for the duration of the task, so
  // the work item stays alive even after the token channel is done with it.
  auto* holder = new std::shared_ptr<GenWork>(w);
  napi_status workStatus = napi_create_async_work(env, nullptr, resourceName, GenExecute,
                                                  GenComplete, holder, &w->work);
  if (workStatus != napi_ok || w->work == nullptr) {
    // Without this the promise would never settle and the UI would spin
    // forever on a "generating" state that no completion ever clears.
    napi_release_threadsafe_function(w->tsfn, napi_tsfn_release);
    w->tsfn = nullptr;
    return reject("failed to schedule generation");
  }
  napi_status queueStatus = napi_queue_async_work(env, w->work);
  if (queueStatus != napi_ok) {
    napi_delete_async_work(env, w->work);
    napi_release_threadsafe_function(w->tsfn, napi_tsfn_release);
    w->tsfn = nullptr;
    return reject("failed to queue generation");
  }
  return promise;
}

// ---------------------------------------------------------------------------
// cancel / release / describe / hasEngine
// ---------------------------------------------------------------------------
napi_value NapiCancel(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = -1;
  if (argc >= 1 && napi_get_value_int32(env, args[0], &id) == napi_ok) {
    auto s = FindSession(id);
    if (s != nullptr) s->Cancel();
  }
  napi_value out = nullptr;
  napi_get_boolean(env, true, &out);
  return out;
}

napi_value NapiRelease(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = -1;
  bool released = false;
  if (argc >= 1 && napi_get_value_int32(env, args[0], &id) == napi_ok) {
    std::lock_guard<std::mutex> lock(g_sessions_mu);
    released = g_sessions.erase(id) > 0;
  }
  napi_value out = nullptr;
  napi_get_boolean(env, released, &out);
  return out;
}

napi_value NapiDescribe(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int32_t id = -1;
  if (argc < 1 || napi_get_value_int32(env, args[0], &id) != napi_ok) {
    return MakeString(env, "{\"loaded\":false}");
  }
  auto s = FindSession(id);
  if (s == nullptr) return MakeString(env, "{\"loaded\":false}");
  return MakeString(env, s->Describe());
}

napi_value NapiHasEngine(napi_env env, napi_callback_info) {
  napi_value out = nullptr;
  napi_get_boolean(env, camelhump::HasEngine(), &out);
  return out;
}

napi_value NapiRenderChatML(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  std::vector<ChatMessage> messages;
  if (argc < 1 || !ParseMessages(env, args[0], &messages)) {
    return MakeString(env, "");
  }
  return MakeString(env, camelhump::RenderChatML(messages, true));
}

napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"inspectGguf", nullptr, NapiInspectGguf, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"loadModel", nullptr, NapiLoadModel, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"generate", nullptr, NapiGenerate, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"cancel", nullptr, NapiCancel, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"release", nullptr, NapiRelease, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"describe", nullptr, NapiDescribe, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"hasEngine", nullptr, NapiHasEngine, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"renderChatML", nullptr, NapiRenderChatML, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  OH_LOG_INFO(LOG_APP, "camelhump native module registered, engine=%{public}d",
              static_cast<int>(camelhump::HasEngine()));
  return exports;
}

// Positional init: designated initializers are a GNU extension before C++20 and
// the OHOS toolchain warns on them.
napi_module g_module = {
    1,          // nm_version
    0,          // nm_flags
    nullptr,    // nm_filename
    Init,       // nm_register_func
    "camelhump",// nm_modname
    nullptr,    // nm_priv
    {0},        // reserved
};

}  // namespace

extern "C" __attribute__((constructor)) void RegisterCamelHumpModule() {
  napi_module_register(&g_module);
}
