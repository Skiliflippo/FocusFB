// Minimal Mach-O symbol rebinding (adapted from facebook/fishhook, BSD-3-Clause License)
// Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.

#pragma once
#include <stddef.h>
#include <stdint.h>
#include <mach-o/loader.h>

#ifdef __cplusplus
extern "C" {
#endif

struct ffb_rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

int ffb_rebind_symbols(struct ffb_rebinding rebindings[], size_t rebindings_nel);
int ffb_rebind_symbols_image(const struct mach_header *header,
                             intptr_t slide,
                             struct ffb_rebinding rebindings[],
                             size_t rebindings_nel);

#ifdef __cplusplus
}
#endif
