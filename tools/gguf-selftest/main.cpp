// Off-device harness for the GGUF header parser.
// The parser has no OHOS dependencies precisely so it can be tested here,
// on a laptop, in under a second.

#include <cstdio>
#include <string>

#include "gguf_inspector.h"

namespace {

int g_failures = 0;

void expect(bool cond, const char* what) {
  if (!cond) {
    std::printf("  FAIL  %s\n", what);
    ++g_failures;
  } else {
    std::printf("  ok    %s\n", what);
  }
}

const camelhump::GgufInfo& inspect(const std::string& path) {
  static camelhump::GgufInfo info;
  info = camelhump::InspectGguf(path);
  return info;
}

}  // namespace

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : "./fixtures";

  std::printf("well-formed v3\n");
  {
    const auto& i = inspect(dir + "/good.gguf");
    expect(i.valid, "parses");
    expect(i.version == 3, "version 3");
    expect(i.architecture == "llama", "architecture");
    expect(camelhump::QuantLabel(i.fileType) == "Q4_K_M", "quant from file_type 15");
    expect(i.contextLength == 2048, "context_length 2048");
    expect(i.hasChatTemplate, "chat template detected");
    expect(i.tensorBytes == 4096, "tensor bytes = 32*32*4");
    expect(i.complete, "complete");
    expect(i.dataOffset + i.tensorBytes == i.fileSize, "data ends exactly at EOF");
  }

  std::printf("truncated payload\n");
  {
    const auto& i = inspect(dir + "/truncated.gguf");
    expect(i.valid, "metadata still parses");
    expect(!i.complete, "flagged incomplete");
  }

  std::printf("wrong file type\n");
  {
    const auto& i = inspect(dir + "/notgguf.gguf");
    expect(!i.valid, "rejected");
    expect(i.error.find("bad magic") != std::string::npos, "reason mentions magic");
  }

  std::printf("v2 with 2000-entry tokenizer array\n");
  {
    const auto& i = inspect(dir + "/v2_array.gguf");
    expect(i.valid, "parses");
    expect(i.version == 2, "version 2");
    // If the array skip is off by even one byte these three all break, which is
    // exactly what makes this fixture worth keeping.
    expect(i.architecture == "qwen2", "architecture after array skip");
    expect(i.contextLength == 4096, "context_length after array skip");
    expect(i.headCount == 12, "head_count after array skip");
    expect(camelhump::QuantLabel(i.fileType) == "Q4_K_S", "quant after array skip");
    expect(i.tensorBytes == 64 * 64 * 2 + 144, "mixed tensor sizes summed");
    expect(i.complete, "complete");
  }

  std::printf("\n%s\n", g_failures == 0 ? "ALL PASS" : "FAILURES PRESENT");
  return g_failures == 0 ? 0 : 1;
}
