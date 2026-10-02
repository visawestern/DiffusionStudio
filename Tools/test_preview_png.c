// Проверка PNG-райтера шима: кодирует синтетические RGB/RGBA-кадры
// и убеждается, что на диске лежат читаемые PNG нужного размера.
#include "sd_preview_png.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

static int check_file(const char* path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        printf("FAIL нет файла %s\n", path);
        return 1;
    }
    if (st.st_size == 0) {
        printf("FAIL пустой файл %s\n", path);
        return 1;
    }
    printf("ok   %s (%lld байт)\n", path, (long long)st.st_size);
    return 0;
}

int main(void) {
    int failures = 0;

    uint8_t rgb[16 * 12 * 3];
    for (int y = 0; y < 12; y++) {
        for (int x = 0; x < 16; x++) {
            rgb[(y * 16 + x) * 3 + 0] = (uint8_t)(x * 16);
            rgb[(y * 16 + x) * 3 + 1] = (uint8_t)(y * 21);
            rgb[(y * 16 + x) * 3 + 2] = 128;
        }
    }
    if (!sd_preview_write_png("/tmp/shimtest/rgb.tmp.png", "/tmp/shimtest/rgb.png", rgb, 16, 12, 3)) {
        printf("FAIL запись RGB PNG\n");
        failures++;
    } else {
        failures += check_file("/tmp/shimtest/rgb.png");
    }

    uint8_t rgba[4 * 4 * 4];
    for (int i = 0; i < 4 * 4; i++) {
        rgba[i * 4 + 0] = 200;
        rgba[i * 4 + 1] = 100;
        rgba[i * 4 + 2] = 50;
        rgba[i * 4 + 3] = 255;
    }
    if (!sd_preview_write_png("/tmp/shimtest/rgba.tmp.png", "/tmp/shimtest/rgba.png", rgba, 4, 4, 4)) {
        printf("FAIL запись RGBA PNG\n");
        failures++;
    } else {
        failures += check_file("/tmp/shimtest/rgba.png");
    }

    if (sd_preview_write_png("/tmp/shimtest/bad.tmp.png", "/tmp/shimtest/bad.png", rgb, 16, 12, 2)) {
        printf("FAIL двухканальный кадр должен отклоняться\n");
        failures++;
    } else {
        printf("ok   двухканальный кадр отклонён\n");
    }

    printf(failures == 0 ? "ИТОГ PNG-РАЙТЕРА: пройдено\n" : "ИТОГ PNG-РАЙТЕРА: провалено\n");
    return failures == 0 ? 0 : 1;
}
