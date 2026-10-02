#include "sd_preview_png.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void release_pixels(void* info, const void* data, size_t size) {
    (void)info;
    (void)size;
    free((void*)data);
}

bool sd_preview_write_png(const char* tmp_path,
                          const char* final_path,
                          const uint8_t* pixels,
                          uint32_t width,
                          uint32_t height,
                          uint32_t channel) {
    if (tmp_path == NULL || final_path == NULL || pixels == NULL) return false;
    if (width == 0 || height == 0) return false;
    if (channel != 3 && channel != 4) return false;

    const size_t row_bytes = (size_t)width * channel;
    const size_t total = row_bytes * height;
    uint8_t* copy = (uint8_t*)malloc(total);
    if (copy == NULL) return false;
    memcpy(copy, pixels, total);

    bool ok = false;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = NULL;
    CGImageRef image = NULL;
    CGImageDestinationRef dest = NULL;
    CFURLRef url = NULL;

    if (cs == NULL) goto done;
    provider = CGDataProviderCreateWithData(NULL, copy, total, release_pixels);
    copy = NULL; // теперь памятью владеет провайдер
    if (provider == NULL) goto done;

    CGBitmapInfo bitmap = (channel == 4) ? kCGImageAlphaLast : kCGImageAlphaNone;
    image = CGImageCreate(width, height, 8, channel * 8, row_bytes, cs,
                          bitmap, provider, NULL, false, kCGRenderingIntentDefault);
    if (image == NULL) goto done;

    url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)tmp_path,
                                                  strlen(tmp_path), false);
    if (url == NULL) goto done;
    dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dest == NULL) goto done;
    CGImageDestinationAddImage(dest, image, NULL);
    if (!CGImageDestinationFinalize(dest)) goto done;

    ok = (rename(tmp_path, final_path) == 0);

done:
    if (!ok) unlink(tmp_path);
    if (copy != NULL) free(copy);
    if (dest != NULL) CFRelease(dest);
    if (url != NULL) CFRelease(url);
    if (image != NULL) CGImageRelease(image);
    if (provider != NULL) CGDataProviderRelease(provider);
    if (cs != NULL) CGColorSpaceRelease(cs);
    return ok;
}
