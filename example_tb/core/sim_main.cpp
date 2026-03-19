#include "Vtb_top.h"
#include "Vtb_top_mm_ram__R16_I20.h"
#include "verilated.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <string>

namespace {

std::string resolve_dump_path(const char* plusarg, const char* def) {
  std::string path = def;
  if (const char* arg = Verilated::commandArgsPlusMatch(plusarg)) {
    if (const char* eq = std::strchr(arg, '=')) {
      const char* candidate = eq + 1;
      if (*candidate != '\0') {
        path.assign(candidate);
      }
    }
  }
  return path;
}

void dump_ram_to_bin(Vtb_top* top, const std::string& path) {
  if (!top || path.empty()) {
    return;
  }

  auto* ram = top->__PVT__tb_top__DOT__wrapper_i__DOT__ram_i;
  if (!ram) {
    std::cerr << "RAM instance not found; skipping memory dump\n";
    return;
  }

  std::ofstream ofs(path, std::ios::binary | std::ios::out);
  if (!ofs) {
    std::cerr << "Failed to open '" << path << "' for RAM dump\n";
    return;
  }

  const auto* mem_begin = std::begin(ram->dp_ram_i__DOT__mem.m_storage);
  const auto* mem_end = std::end(ram->dp_ram_i__DOT__mem.m_storage);
  const std::size_t byte_count = static_cast<std::size_t>(mem_end - mem_begin);

  ofs.write(reinterpret_cast<const char*>(mem_begin),
            static_cast<std::streamsize>(byte_count));
  ofs.close();

  std::cout << "Binary RAM dump written to '" << path << "' (" << byte_count
            << " bytes)\n";
}

void dump_ram_to_hex(Vtb_top* top, const std::string& path) {
  if (!top || path.empty()) {
    return;
  }

  auto* ram = top->__PVT__tb_top__DOT__wrapper_i__DOT__ram_i;
  if (!ram) {
    std::cerr << "RAM instance not found; skipping hex memory dump\n";
    return;
  }

  std::ofstream ofs(path, std::ios::out);
  if (!ofs) {
    std::cerr << "Failed to open '" << path << "' for hex RAM dump\n";
    return;
  }

  const auto* mem_begin = std::begin(ram->dp_ram_i__DOT__mem.m_storage);
  const auto* mem_end = std::end(ram->dp_ram_i__DOT__mem.m_storage);
  const std::size_t byte_count = static_cast<std::size_t>(mem_end - mem_begin);
  const std::size_t word_count = (byte_count + 3U) / 4U;

  ofs << std::hex << std::setfill('0');
  for (std::size_t word_idx = 0; word_idx < word_count; ++word_idx) {
    uint32_t word = 0;
    for (std::size_t byte = 0; byte < 4; ++byte) {
      const std::size_t addr = word_idx * 4 + byte;
      const uint32_t value = (addr < byte_count) ? mem_begin[addr] : 0U;
      word |= (value << (8 * byte));
    }
    ofs << std::setw(8) << word << '\n';
  }
  ofs.close();

  std::cout << "Hex RAM dump written to '" << path << "' (" << word_count
            << " words)\n";
}

}  // namespace

int main(int argc, char** argv) {
  VerilatedContext* contextp = new VerilatedContext;
  contextp->commandArgs(argc, argv);

  Vtb_top* top = new Vtb_top{contextp};

  while (!contextp->gotFinish()) {
    top->eval();
    contextp->timeInc(1);
  }

  top->final();

  const std::string bin_path = resolve_dump_path("memdump=", "sim_ram.bin");
  const std::string hex_path = resolve_dump_path("memdump_hex=", "sim_ram.hex");

  dump_ram_to_bin(top, bin_path);
  dump_ram_to_hex(top, hex_path);

  delete top;
  delete contextp;
  return 0;
}
