// Minimal Mach-O arm64 symbol rebinding (adapted from facebook/fishhook, BSD-3-Clause License)
// Copyright (c) Meta Platforms, Inc. and affiliates. All rights reserved.
// Clean C++17 / Objective-C++ port for Xcode 26+ arm64 builds without CydiaSubstrate.

#import "FocusFBFishhook.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <mach-o/dyld.h>
#include <mach-o/nlist.h>

#ifdef __LP64__
typedef struct mach_header_64 ffb_mach_header_t;
typedef struct segment_command_64 ffb_segment_command_t;
typedef struct section_64 ffb_section_t;
typedef struct nlist_64 ffb_nlist_t;
#define FFB_LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header ffb_mach_header_t;
typedef struct segment_command ffb_segment_command_t;
typedef struct section ffb_section_t;
typedef struct nlist ffb_nlist_t;
#define FFB_LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif

struct ffb_rebindings_entry {
    struct ffb_rebinding *rebindings;
    size_t rebindings_nel;
    struct ffb_rebindings_entry *next;
};

static struct ffb_rebindings_entry *g_rebindings_head = nullptr;

static int ffb_prepend_rebindings(struct ffb_rebindings_entry **head,
                                  struct ffb_rebinding rebindings[],
                                  size_t nel) {
    auto *new_entry = static_cast<struct ffb_rebindings_entry *>(malloc(sizeof(struct ffb_rebindings_entry)));
    if (!new_entry) {
        return -1;
    }
    new_entry->rebindings = static_cast<struct ffb_rebinding *>(malloc(sizeof(struct ffb_rebinding) * nel));
    if (!new_entry->rebindings) {
        free(new_entry);
        return -1;
    }
    memcpy(new_entry->rebindings, rebindings, sizeof(struct ffb_rebinding) * nel);
    new_entry->rebindings_nel = nel;
    new_entry->next = *head;
    *head = new_entry;
    return 0;
}

static void ffb_perform_rebinding_with_section(struct ffb_rebindings_entry *rebindings,
                                               ffb_section_t *section,
                                               intptr_t slide,
                                               ffb_nlist_t *symtab,
                                               char *strtab,
                                               uint32_t *indirect_symtab) {
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = reinterpret_cast<void **>(static_cast<uintptr_t>(slide) + section->addr);

    for (uint i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        if (!symbol_name[0] || !symbol_name[1]) {
            continue;
        }

        struct ffb_rebindings_entry *cur = rebindings;
        while (cur) {
            for (size_t j = 0; j < cur->rebindings_nel; j++) {
                if (strcmp(&symbol_name[1], cur->rebindings[j].name) == 0) {
                    if (cur->rebindings[j].replaced != nullptr &&
                        indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
                        *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
                    }
                    kern_return_t err = vm_protect(mach_task_self(),
                                                   reinterpret_cast<vm_address_t>(indirect_symbol_bindings),
                                                   section->size,
                                                   0,
                                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    if (err == KERN_SUCCESS) {
                        indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
                    }
                    goto symbol_loop;
                }
            }
            cur = cur->next;
        }
    symbol_loop:;
    }
}

static void ffb_rebind_symbols_for_image(struct ffb_rebindings_entry *rebindings,
                                         const struct mach_header *header,
                                         intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) == 0 || !info.dli_fname) {
        return;
    }
    // Non modificare mai i puntatori interni di FocusFB stesso o dei framework di sistema Apple
    if (strstr(info.dli_fname, "FocusFB.dylib") != nullptr ||
        strstr(info.dli_fname, "/System/Library/") != nullptr ||
        strstr(info.dli_fname, "/usr/lib/") != nullptr) {
        return;
    }
    // Non toccare LiveContainer stesso se presente nel processo
    if (strstr(info.dli_fname, "LiveContainer") != nullptr ||
        strstr(info.dli_fname, "TweakLoader") != nullptr) {
        return;
    }

    ffb_segment_command_t *cur_seg_cmd = nullptr;
    ffb_segment_command_t *linkedit_segment = nullptr;
    struct symtab_command *symtab_cmd = nullptr;
    struct dysymtab_command *dysymtab_cmd = nullptr;

    uintptr_t cur = reinterpret_cast<uintptr_t>(header) + sizeof(ffb_mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = reinterpret_cast<ffb_segment_command_t *>(cur);
        if (cur_seg_cmd->cmd == FFB_LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg_cmd;
            }
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = reinterpret_cast<struct symtab_command *>(cur_seg_cmd);
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = reinterpret_cast<struct dysymtab_command *>(cur_seg_cmd);
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment || !dysymtab_cmd->nindirectsyms) {
        return;
    }

    uintptr_t linkedit_base = static_cast<uintptr_t>(slide) + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    auto *symtab = reinterpret_cast<ffb_nlist_t *>(linkedit_base + symtab_cmd->symoff);
    char *strtab = reinterpret_cast<char *>(linkedit_base + symtab_cmd->stroff);
    auto *indirect_symtab = reinterpret_cast<uint32_t *>(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = reinterpret_cast<uintptr_t>(header) + sizeof(ffb_mach_header_t);
    for (uint i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
        cur_seg_cmd = reinterpret_cast<ffb_segment_command_t *>(cur);
        if (cur_seg_cmd->cmd == FFB_LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
                strcmp(cur_seg_cmd->segname, SEG_DATA_CONST) != 0) {
                continue;
            }
            for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
                auto *sect = reinterpret_cast<ffb_section_t *>(cur + sizeof(ffb_segment_command_t)) + j;
                uint32_t flags = sect->flags & SECTION_TYPE;
                if (flags == S_LAZY_SYMBOL_POINTERS || flags == S_NON_LAZY_SYMBOL_POINTERS) {
                    ffb_perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
                }
            }
        }
    }
}

static void ffb_dyld_callback(const struct mach_header *header, intptr_t slide) {
    ffb_rebind_symbols_for_image(g_rebindings_head, header, slide);
}

int ffb_rebind_symbols_image(const struct mach_header *header,
                             intptr_t slide,
                             struct ffb_rebinding rebindings[],
                             size_t rebindings_nel) {
    struct ffb_rebindings_entry *local_head = nullptr;
    int retval = ffb_prepend_rebindings(&local_head, rebindings, rebindings_nel);
    if (retval < 0) {
        return retval;
    }
    ffb_rebind_symbols_for_image(local_head, header, slide);
    if (local_head) {
        free(local_head->rebindings);
        free(local_head);
    }
    return retval;
}

int ffb_rebind_symbols(struct ffb_rebinding rebindings[], size_t rebindings_nel) {
    int retval = ffb_prepend_rebindings(&g_rebindings_head, rebindings, rebindings_nel);
    if (retval < 0) {
        return retval;
    }
    if (!g_rebindings_head->next) {
        _dyld_register_func_for_add_image(ffb_dyld_callback);
    } else {
        uint32_t c = _dyld_image_count();
        for (uint32_t i = 0; i < c; i++) {
            ffb_dyld_callback(_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
        }
    }
    return retval;
}
