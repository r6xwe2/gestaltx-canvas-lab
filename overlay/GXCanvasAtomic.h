/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef GX_CANVAS_ATOMIC_H
#define GX_CANVAS_ATOMIC_H
#include <stddef.h>
/* 0 = replaced and byte-verified; -1 = not replaced; 1 = replaced, verification failed.
 * Caller MUST save a durable, authenticated original backup before calling.
 * Existing file only. No arbitrary filename, symlink or in-place truncation.
 */
int gxcl_atomic_replace(int dirfd, int originalfd,
                        const unsigned char *before, size_t before_length,
                        const unsigned char *after, size_t after_length,
                        char *message, size_t message_capacity);
#endif
