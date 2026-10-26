/*
 * gguf_inspector.h — GGUF v2/v3 header reader.
 *
 * Purpose: never trust a filename. Users download weights from mirrors where
 * "qwen1.5b-q4.gguf" may actually hold Q5_K_M, a different architecture, or a
 * truncated file. Everything the UI claims about a model must come from here.
 */

#ifndef CAMELHUMP_GGUF_INSPECTOR_H
#define CAMELHUMP_GGUF_INSPECTOR_H

#include <cstdint>
#include <string>
#include <vector>

namespace camelhump {

// ggml tensor element types (subset that matters for size accounting).
enum GgmlType : uint32_t {
  GGML_TYPE_F32 = 0,
  GGML_TYPE_F16 = 1,
  GGML_TYPE_Q4_0 = 2,
  GGML_TYPE_Q4_1 = 3,
  GGML_TYPE_Q5_0 = 6,
  GGML_TYPE_Q5_1 = 7,
  GGML_TYPE_Q8_0 = 8,
  GGML_TYPE_Q8_1 = 9,
  GGML_TYPE_Q2_K = 10,
  GGML_TYPE_Q3_K = 11,
  GGML_TYPE_Q4_K = 12,
  GGML_TYPE_Q5_K = 13,
  GGML_TYPE_Q6_K = 14,
  GGML_TYPE_Q8_K = 15,
  GGML_TYPE_IQ2_XXS = 16,
  GGML_TYPE_IQ2_XS = 17,
  GGML_TYPE_IQ3_XXS = 18,
  GGML_TYPE_IQ1_S = 19,
  GGML_TYPE_IQ4_NL = 20,
  GGML_TYPE_IQ3_S = 21,
  GGML_TYPE_IQ2_S = 22,
  GGML_TYPE_IQ4_XS = 23,
  GGML_TYPE_BF16 = 30,
};

struct GgufInfo {
  bool valid = false;
  std::string error;

  uint32_t version = 0;
  uint64_t tensorCount = 0;
  uint64_t kvCount = 0;
  uint64_t fileSize = 0;

  std::string architecture;     // general.architecture
  std::string name;             // general.name
  std::string sizeLabel;        // general.size_label
  uint32_t fileType = 0xFFFFFFFFu;  // general.file_type
  uint32_t contextLength = 0;
  uint32_t blockCount = 0;
  uint32_t headCount = 0;
  uint32_t embeddingLength = 0;

  bool hasChatTemplate = false;
  std::string chatTemplate;

  uint64_t tensorBytes = 0;      // sum of all tensor payloads
  uint64_t dataOffset = 0;       // where tensor data begins
  bool complete = false;         // file covers dataOffset + tensorBytes

  // Tensor type codes we could not size. Non-empty means the layout table
  // is out of date and the file cannot be fully validated.
  std::vector<uint32_t> unknownTensorTypes;
};

// Reads only headers and tensor descriptors — never the weights themselves.
// Safe to call on multi-gigabyte files; cost is proportional to metadata size.
GgufInfo InspectGguf(const std::string& path);

// Human-readable quantization label from general.file_type (e.g. "Q4_K_M").
std::string QuantLabel(uint32_t fileType);

// Rendered as the JSON string handed back to ArkTS.
std::string ToJson(const GgufInfo& info);

}  // namespace camelhump

#endif  // CAMELHUMP_GGUF_INSPECTOR_H
