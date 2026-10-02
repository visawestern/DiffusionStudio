// SDPreviewShim: покадровое превью для готового бинаря sd-server.
//
// Подключение: DYLD_INSERT_LIBRARIES=.../SDPreviewShim.dylib
// Каталог вывода: DIFFUSION_STUDIO_PREVIEW_DIR (туда пишется preview.png).
//
// Как работает: конструктор регистрирует sd_set_preview_callback в режиме
// PREVIEW_PROJ с интервалом 1. Эта функция экспортирована самим бинарем
// sd-server, поэтому пересобирать движок не нужно — достаточно подгрузить шим.
// Колбэк вызывается из рабочего потока генерации на каждом шаге; кадр
// копируется синхронно (движок освобождает память сразу после возврата)
// и сохраняется в PNG через ImageIO.
//
// Qwen-Image 2.1 поддерживает PREVIEW_PROJ в движке. Проекция дешёвая —
// умножение крошечного латента на матрицу 64x3, на скорость шагов заметно
// не влияет. Разрешение превью — размер латента (десятки пикселей),
// это контроль композиции, а не деталей.

#include "sd_preview_png.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t channel;
    uint8_t* data;
} sd_image_t;

typedef void (*sd_preview_cb_t)(int step, int frame_count, sd_image_t* frames, bool is_noisy, void* data);

// Символ резолвится во время загрузки из главного исполняемого файла
// sd-server (dylib собирается с -undefined dynamic_lookup).
extern void sd_set_preview_callback(sd_preview_cb_t cb, int mode, int interval, bool denoised, bool noisy, void* data);

#define PREVIEW_PROJ 1

static void preview_callback(int step, int frame_count, sd_image_t* frames, bool is_noisy, void* data) {
    (void)step;
    (void)is_noisy;
    (void)data;
    if (frame_count < 1 || frames == NULL || frames[0].data == NULL) return;

    const char* dir = getenv("DIFFUSION_STUDIO_PREVIEW_DIR");
    if (dir == NULL || dir[0] == '\0') return;

    char final_path[4096];
    char tmp_path[4160];
    snprintf(final_path, sizeof(final_path), "%s/preview.png", dir);
    snprintf(tmp_path, sizeof(tmp_path), "%s/preview.tmp.%d.png", dir, (int)getpid());

    sd_preview_write_png(tmp_path, final_path,
                         frames[0].data, frames[0].width, frames[0].height, frames[0].channel);
}

__attribute__((constructor))
static void register_preview_callback(void) {
    sd_set_preview_callback(preview_callback, PREVIEW_PROJ, 1, true, false, NULL);
}
