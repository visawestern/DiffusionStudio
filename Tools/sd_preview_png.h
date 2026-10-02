#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Кодирует RGB/RGBA-кадр в PNG и атомарно кладёт по final_path
// (сначала пишет tmp_path, затем rename). Возвращает true при успехе.
bool sd_preview_write_png(const char* tmp_path,
                          const char* final_path,
                          const uint8_t* pixels,
                          uint32_t width,
                          uint32_t height,
                          uint32_t channel);
