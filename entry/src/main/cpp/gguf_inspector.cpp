#include "gguf_inspector.h"

#include <sys/stat.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace camelhump {
namespace {

constexpr uint32_t kGgufMagic = 0x46554747u;  // "GGUF" little-endian
constexpr uint64_t kMaxStringLen = 64ull * 1024 * 1024;
constexpr size_t kBufferSize = 256 * 1024;

// GGUF metadata value types.
enum GgufType : uint32_t {
  GGUF_TYPE_UINT8 = 0,
  GGUF_TYPE_INT8 = 1,
  GGUF_TYPE_UINT16 = 2,
  GGUF_TYPE_INT16 = 3,
  GGUF_TYPE_UINT32 = 4,
  GGUF_TYPE_INT32 = 5,
  GGUF_TYPE_FLOAT32 = 6,
  GGUF_TYPE_BOOL = 7,
  GGUF_TYPE_STRING = 8,
  GGUF_TYPE_ARRAY = 9,
  GGUF_TYPE_UINT64 = 10,
  GGUF_TYPE_INT64 = 11,
  GGUF_TYPE_FLOAT64 = 12,
};

size_t ScalarSize(uint32_t t) {
  switch (t) {
    case GGUF_TYPE_UINT8:
    case GGUF_TYPE_INT8:
    case GGUF_TYPE_BOOL:
      return 1;
    case GGUF_TYPE_UINT16:
    case GGUF_TYPE_INT16:
      return 2;
    case GGUF_TYPE_UINT32:
    case GGUF_TYPE_INT32:
    case GGUF_TYPE_FLOAT32:
      return 4;
    case GGUF_TYPE_UINT64:
    case GGUF_TYPE_INT64:
    case GGUF_TYPE_FLOAT64:
      return 8;
    default:
      return 0;
  }
}

// ggml block layout: bytes per block / elements per block.
bool TypeLayout(uint32_t t, uint32_t* blockElems, uint32_t* blockBytes) {
  switch (t) {
    case GGML_TYPE_F32:  *blockElems = 1;   *blockBytes = 4;   return true;
    case GGML_TYPE_F16:  *blockElems = 1;   *blockBytes = 2;   return true;
    case GGML_TYPE_BF16: *blockElems = 1;   *blockBytes = 2;   return true;
    case GGML_TYPE_Q4_0: *blockElems = 32;  *blockBytes = 18;  return true;
    case GGML_TYPE_Q4_1: *blockElems = 32;  *blockBytes = 20;  return true;
    case GGML_TYPE_Q5_0: *blockElems = 32;  *blockBytes = 22;  return true;
    case GGML_TYPE_Q5_1: *blockElems = 32;  *blockBytes = 24;  return true;
    case GGML_TYPE_Q8_0: *blockElems = 32;  *blockBytes = 34;  return true;
    case GGML_TYPE_Q8_1: *blockElems = 32;  *blockBytes = 36;  return true;
    case GGML_TYPE_Q2_K: *blockElems = 256; *blockBytes = 84;  return true;
    case GGML_TYPE_Q3_K: *blockElems = 256; *blockBytes = 110; return true;
    case GGML_TYPE_Q4_K: *blockElems = 256; *blockBytes = 144; return true;
    case GGML_TYPE_Q5_K: *blockElems = 256; *blockBytes = 176; return true;
    case GGML_TYPE_Q6_K: *blockElems = 256; *blockBytes = 210; return true;
    case GGML_TYPE_Q8_K: *blockElems = 256; *blockBytes = 292; return true;
    case GGML_TYPE_IQ2_XXS: *blockElems = 256; *blockBytes = 66;  return true;
    case GGML_TYPE_IQ2_XS:  *blockElems = 256; *blockBytes = 74;  return true;
    case GGML_TYPE_IQ3_XXS: *blockElems = 256; *blockBytes = 98;  return true;
    case GGML_TYPE_IQ1_S:   *blockElems = 256; *blockBytes = 50;  return true;
    case GGML_TYPE_IQ4_NL:  *blockElems = 32;  *blockBytes = 18;  return true;
    case GGML_TYPE_IQ3_S:   *blockElems = 256; *blockBytes = 110; return true;
    case GGML_TYPE_IQ2_S:   *blockElems = 256; *blockBytes = 82;  return true;
    case GGML_TYPE_IQ4_XS:  *blockElems = 256; *blockBytes = 136; return true;
    default: return false;
  }
}

class Reader {
 public:
  explicit Reader(FILE* f) : f_(f) { buf_.resize(kBufferSize); }

  bool Read(void* dst, size_t n) {
    uint8_t* out = static_cast<uint8_t*>(dst);
    while (n > 0) {
      if (buf_pos_ >= buf_len_ && !Fill()) return false;
      size_t avail = buf_len_ - buf_pos_;
      size_t take = std::min(avail, n);
      std::memcpy(out, buf_.data() + buf_pos_, take);
      buf_pos_ += take;
      out += take;
      n -= take;
      pos_ += take;
    }
    return true;
  }

  bool Skip(uint64_t n) {
    while (n > 0) {
      if (buf_pos_ >= buf_len_ && !Fill()) return false;
      size_t avail = buf_len_ - buf_pos_;
      uint64_t take = std::min<uint64_t>(avail, n);
      buf_pos_ += static_cast<size_t>(take);
      n -= take;
      pos_ += take;
    }
    return true;
  }

  bool ReadU32(uint32_t* v) { return Read(v, sizeof(*v)); }
  bool ReadU64(uint64_t* v) { return Read(v, sizeof(*v)); }

  // gguf_string = uint64 length + raw bytes (not NUL terminated)
  bool ReadStr(std::string* s) {
    uint64_t len = 0;
    if (!ReadU64(&len)) return false;
    if (len > kMaxStringLen) return false;
    s->resize(static_cast<size_t>(len));
    if (len == 0) return true;
    return Read(&(*s)[0], static_cast<size_t>(len));
  }

  bool SkipStr() {
    uint64_t len = 0;
    if (!ReadU64(&len)) return false;
    if (len > kMaxStringLen) return false;
    return Skip(len);
  }

  uint64_t Pos() const { return pos_; }

 private:
  bool Fill() {
    buf_len_ = std::fread(buf_.data(), 1, buf_.size(), f_);
    buf_pos_ = 0;
    return buf_len_ > 0;
  }

  FILE* f_;
  std::vector<uint8_t> buf_;
  size_t buf_pos_ = 0;
  size_t buf_len_ = 0;
  uint64_t pos_ = 0;
};

// Reads a scalar metadata value, storing the integer form when asked.
bool ReadScalar(Reader& r, uint32_t type, uint64_t* out) {
  size_t n = ScalarSize(type);
  if (n == 0) return false;
  uint8_t tmp[8] = {0};
  if (!r.Read(tmp, n)) return false;
  if (out == nullptr) return true;
  switch (type) {
    case GGUF_TYPE_UINT8:   *out = *reinterpret_cast<uint8_t*>(tmp);  break;
    case GGUF_TYPE_INT8:    *out = static_cast<uint64_t>(*reinterpret_cast<int8_t*>(tmp)); break;
    case GGUF_TYPE_UINT16:  *out = *reinterpret_cast<uint16_t*>(tmp); break;
    case GGUF_TYPE_INT16:   *out = static_cast<uint64_t>(*reinterpret_cast<int16_t*>(tmp)); break;
    case GGUF_TYPE_UINT32:  *out = *reinterpret_cast<uint32_t*>(tmp); break;
    case GGUF_TYPE_INT32:   *out = static_cast<uint64_t>(*reinterpret_cast<int32_t*>(tmp)); break;
    case GGUF_TYPE_UINT64:  *out = *reinterpret_cast<uint64_t*>(tmp); break;
    case GGUF_TYPE_INT64:   *out = static_cast<uint64_t>(*reinterpret_cast<int64_t*>(tmp)); break;
    case GGUF_TYPE_BOOL:    *out = tmp[0] ? 1 : 0; break;
    default: break;  // float types: caller does not need the value
  }
  return true;
}

bool SkipValue(Reader& r, uint32_t type) {
  if (type == GGUF_TYPE_STRING) return r.SkipStr();
  if (type == GGUF_TYPE_ARRAY) {
    uint32_t elem_type = 0;
    uint64_t count = 0;
    if (!r.ReadU32(&elem_type) || !r.ReadU64(&count)) return false;
    if (elem_type == GGUF_TYPE_STRING) {
      for (uint64_t i = 0; i < count; ++i) {
        if (!r.SkipStr()) return false;
      }
      return true;
    }
    if (elem_type == GGUF_TYPE_ARRAY) return false;  // nested arrays are not valid
    size_t esz = ScalarSize(elem_type);
    if (esz == 0) return false;
    if (count > (UINT64_MAX / esz)) return false;
    return r.Skip(count * esz);
  }
  size_t n = ScalarSize(type);
  if (n == 0) return false;
  return r.Skip(n);
}

bool EndsWith(const std::string& s, const char* suffix) {
  const size_t n = std::strlen(suffix);
  return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

// Which numeric keys we care about. Architecture-specific keys are prefixed
// (e.g. "llama.context_length", "qwen2.attention.head_count"), so suffix match
// is the only portable rule — never hard-code prefix lengths.
enum class NumField { kNone, kFileType, kAlignment, kContextLength, kBlockCount, kHeadCount, kEmbeddingLength };

NumField ClassifyKey(const std::string& key) {
  if (key == "general.file_type") return NumField::kFileType;
  if (key == "general.alignment") return NumField::kAlignment;
  // Order matters: "attention.head_count" also ends in a count-ish suffix.
  if (EndsWith(key, ".attention.head_count")) return NumField::kHeadCount;
  if (EndsWith(key, ".context_length")) return NumField::kContextLength;
  if (EndsWith(key, ".block_count")) return NumField::kBlockCount;
  if (EndsWith(key, ".embedding_length")) return NumField::kEmbeddingLength;
  return NumField::kNone;
}

std::string EscapeJson(const std::string& s, size_t limit = 4096) {  std::string out;
  size_t n = std::min(s.size(), limit);
  out.reserve(n + 16);
  for (size_t i = 0; i < n; ++i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    switch (c) {
      case '"':  out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n";  break;
      case '\r': out += "\\r";  break;
      case '\t': out += "\\t";  break;
      default:
        if (c < 0x20) {
          char tmp[8];
          std::snprintf(tmp, sizeof(tmp), "\\u%04x", c);
          out += tmp;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  if (s.size() > limit) out += "...[truncated]";
  return out;
}

}  // namespace

std::string QuantLabel(uint32_t fileType) {
  // llama_ftype enum (as written by convert_hf_to_gguf.py)
  switch (fileType) {
    case 0:  return "F32";
    case 1:  return "F16";
    case 2:  return "Q4_0";
    case 3:  return "Q4_1";
    case 7:  return "Q8_0";
    case 8:  return "Q5_0";
    case 9:  return "Q5_1";
    case 10: return "Q2_K";
    case 11: return "Q3_K_S";
    case 12: return "Q3_K_M";
    case 13: return "Q3_K_L";
    case 14: return "Q4_K_S";
    case 15: return "Q4_K_M";
    case 16: return "Q5_K_S";
    case 17: return "Q5_K_M";
    case 18: return "Q6_K";
    case 19: return "IQ2_XXS";
    case 20: return "IQ2_XS";
    case 21: return "Q2_K_S";
    case 22: return "IQ3_XS";
    case 23: return "IQ3_XXS";
    case 24: return "IQ1_S";
    case 25: return "IQ4_NL";
    case 26: return "IQ3_S";
    case 27: return "IQ2_S";
    case 28: return "IQ4_XS";
    case 29: return "IQ1_M";
    case 30: return "BF16";
    case 31: return "Q4_0_4_4";
    case 32: return "Q4_0_4_8";
    case 33: return "Q4_0_8_8";
    case 34: return "TQ1_0";
    case 35: return "TQ2_0";
    default: return "UNKNOWN";
  }
}

GgufInfo InspectGguf(const std::string& path) {
  GgufInfo info;

  struct stat st;
  if (::stat(path.c_str(), &st) != 0) {
    info.error = "cannot stat file";
    return info;
  }
  info.fileSize = static_cast<uint64_t>(st.st_size);

  FILE* f = std::fopen(path.c_str(), "rb");
  if (f == nullptr) {
    info.error = "cannot open file";
    return info;
  }

  Reader r(f);

  uint32_t magic = 0;
  if (!r.ReadU32(&magic)) {
    info.error = "file too small to be GGUF";
    std::fclose(f);
    return info;
  }
  if (magic != kGgufMagic) {
    info.error = "not a GGUF file (bad magic)";
    std::fclose(f);
    return info;
  }

  if (!r.ReadU32(&info.version)) {
    info.error = "truncated header";
    std::fclose(f);
    return info;
  }
  if (info.version < 2 || info.version > 3) {
    info.error = "unsupported GGUF version " + std::to_string(info.version);
    std::fclose(f);
    return info;
  }

  if (!r.ReadU64(&info.tensorCount) || !r.ReadU64(&info.kvCount)) {
    info.error = "truncated header";
    std::fclose(f);
    return info;
  }

  // Sanity bound: a 200k-vocab tokenizer plus metadata is well under 1M keys.
  if (info.kvCount > 1000000ull) {
    info.error = "implausible metadata count (file likely corrupt)";
    std::fclose(f);
    return info;
  }

  uint64_t alignment = 32;
  bool ok = true;

  for (uint64_t i = 0; i < info.kvCount && ok; ++i) {
    std::string key;
    uint32_t type = 0;
    if (!r.ReadStr(&key) || !r.ReadU32(&type)) {
      ok = false;
      break;
    }

    if (type == GGUF_TYPE_STRING) {
      if (key == "general.architecture") {
        ok = r.ReadStr(&info.architecture);
      } else if (key == "general.name") {
        ok = r.ReadStr(&info.name);
      } else if (key == "general.size_label") {
        ok = r.ReadStr(&info.sizeLabel);
      } else if (key == "tokenizer.chat_template") {
        ok = r.ReadStr(&info.chatTemplate);
        info.hasChatTemplate = ok && !info.chatTemplate.empty();
      } else {
        ok = r.SkipStr();
      }
    } else if (type == GGUF_TYPE_ARRAY) {
      // Tokenizer vocabularies live here and are large — always skipped.
      ok = SkipValue(r, type);
    } else {
      uint64_t value = 0;
      const NumField field = ClassifyKey(key);
      const bool capture = field != NumField::kNone;

      ok = ReadScalar(r, type, capture ? &value : nullptr);
      if (ok && capture) {
        switch (field) {
          case NumField::kFileType:
            info.fileType = static_cast<uint32_t>(value);
            break;
          case NumField::kAlignment:
            if (value >= 8 && value <= 4096) alignment = value;
            break;
          case NumField::kContextLength:
            info.contextLength = static_cast<uint32_t>(value);
            break;
          case NumField::kBlockCount:
            info.blockCount = static_cast<uint32_t>(value);
            break;
          case NumField::kHeadCount:
            info.headCount = static_cast<uint32_t>(value);
            break;
          case NumField::kEmbeddingLength:
            info.embeddingLength = static_cast<uint32_t>(value);
            break;
          default:
            break;
        }
      }
    }
  }

  if (!ok) {
    info.error = "truncated or corrupt metadata section";
    std::fclose(f);
    return info;
  }

  // Tensor descriptors: name, n_dims, dims[], type, offset.
  uint64_t max_end = 0;
  for (uint64_t i = 0; i < info.tensorCount; ++i) {
    std::string tname;
    uint32_t n_dims = 0;
    if (!r.ReadStr(&tname) || !r.ReadU32(&n_dims)) {
      ok = false;
      break;
    }
    if (n_dims > 8) {
      ok = false;
      break;
    }
    uint64_t elements = 1;
    bool dim_ok = true;
    for (uint32_t d = 0; d < n_dims; ++d) {
      uint64_t dim = 0;
      if (!r.ReadU64(&dim)) {
        dim_ok = false;
        break;
      }
      if (dim != 0 && elements > UINT64_MAX / dim) {
        dim_ok = false;
        break;
      }
      elements *= dim;
    }
    if (!dim_ok) {
      ok = false;
      break;
    }

    uint32_t ttype = 0;
    uint64_t offset = 0;
    if (!r.ReadU32(&ttype) || !r.ReadU64(&offset)) {
      ok = false;
      break;
    }

    uint32_t block_elems = 0;
    uint32_t block_bytes = 0;
    if (!TypeLayout(ttype, &block_elems, &block_bytes)) {
      // Unknown tensor type: the file is still readable, but we cannot size
      // this tensor. Counting it as zero bytes would make `complete` true for
      // a file that is actually truncated, so the file is marked incomplete
      // and the unknown type code is recorded for diagnosis.
      info.unknownTensorTypes.push_back(ttype);
      ok = false;
      break;
    }
    if (elements % block_elems != 0) {
      ok = false;
      break;
    }
    uint64_t bytes = (elements / block_elems) * block_bytes;
    info.tensorBytes += bytes;
    max_end = std::max(max_end, offset + bytes);
  }

  if (!ok) {
    info.error = "corrupt tensor descriptor table";
    std::fclose(f);
    return info;
  }

  // Tensor payload starts at the next alignment boundary after the descriptors.
  uint64_t info_end = r.Pos();
  info.dataOffset = ((info_end + alignment - 1) / alignment) * alignment;

  if (info.fileSize >= info.dataOffset + max_end &&
      info.fileSize >= info.dataOffset + info.tensorBytes) {
    info.complete = true;
  }

  info.valid = true;
  std::fclose(f);
  return info;
}

std::string ToJson(const GgufInfo& info) {
  std::string j = "{";
  j += "\"valid\":" + std::string(info.valid ? "true" : "false");
  j += ",\"error\":\"" + EscapeJson(info.error, 256) + "\"";
  j += ",\"version\":" + std::to_string(info.version);
  j += ",\"tensorCount\":" + std::to_string(info.tensorCount);
  j += ",\"kvCount\":" + std::to_string(info.kvCount);
  j += ",\"fileSize\":" + std::to_string(info.fileSize);
  j += ",\"architecture\":\"" + EscapeJson(info.architecture, 128) + "\"";
  j += ",\"name\":\"" + EscapeJson(info.name, 256) + "\"";
  j += ",\"sizeLabel\":\"" + EscapeJson(info.sizeLabel, 128) + "\"";
  j += ",\"fileType\":" + std::to_string(info.fileType);
  j += ",\"quant\":\"" + QuantLabel(info.fileType) + "\"";
  j += ",\"contextLength\":" + std::to_string(info.contextLength);
  j += ",\"blockCount\":" + std::to_string(info.blockCount);
  j += ",\"headCount\":" + std::to_string(info.headCount);
  j += ",\"embeddingLength\":" + std::to_string(info.embeddingLength);
  j += ",\"hasChatTemplate\":" + std::string(info.hasChatTemplate ? "true" : "false");
  j += ",\"chatTemplate\":\"" + EscapeJson(info.chatTemplate) + "\"";
  j += ",\"tensorBytes\":" + std::to_string(info.tensorBytes);
  j += ",\"dataOffset\":" + std::to_string(info.dataOffset);
  j += ",\"complete\":" + std::string(info.complete ? "true" : "false");
  j += "}";
  return j;
}

}  // namespace camelhump
