/* SPDX-License-Identifier: GPL-3.0-only
 * Experimental canvas-file replacement. Written for this kit, not upstream.
 * Apple-only metadata handling is NOT covered by the portable host tests.
 */
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#define _POSIX_C_SOURCE 200809L
#include "GXCanvasAtomic.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <copyfile.h>
#endif

#define GXCL_NAME "com.apple.iokit.IOMobileGraphicsFamily.plist"
#define GXCL_LIMIT (4u * 1024u * 1024u)

static void say(char *out, size_t n, const char *stage, int code) {
    if (out && n) snprintf(out, n, "%s (errno=%d: %s)", stage, code, strerror(code));
}
static int equal_fd(int fd, const unsigned char *bytes, size_t length) {
    struct stat s;
    if (fstat(fd, &s) || !S_ISREG(s.st_mode) || s.st_size != (off_t)length) return 0;
    unsigned char buffer[4096];
    size_t offset = 0;
    while (offset < length) {
        size_t want = length - offset;
        if (want > sizeof(buffer)) want = sizeof(buffer);
        ssize_t got = pread(fd, buffer, want, (off_t)offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0 || memcmp(buffer, bytes + offset, (size_t)got)) return 0;
        offset += (size_t)got;
    }
    return 1;
}
static int still_original(int directory, int original, const struct stat *start,
                          const unsigned char *before, size_t length) {
    struct stat path, opened;
    if (fstatat(directory, GXCL_NAME, &path, AT_SYMLINK_NOFOLLOW) || fstat(original, &opened)) return 0;
    return S_ISREG(path.st_mode) && path.st_nlink == 1 && opened.st_nlink == 1 &&
           path.st_dev == start->st_dev && path.st_ino == start->st_ino &&
           path.st_size == start->st_size && path.st_mode == start->st_mode &&
           path.st_uid == start->st_uid && path.st_gid == start->st_gid &&
           opened.st_mode == start->st_mode && opened.st_uid == start->st_uid &&
           opened.st_gid == start->st_gid && equal_fd(original, before, length);
}
int gxcl_atomic_replace(int directory, int original,
                        const unsigned char *before, size_t before_length,
                        const unsigned char *after, size_t after_length,
                        char *message, size_t capacity) {
    int tmp = -1, check = -1, renamed = 0, result = -1, locked = 0;
    int failure = 0;
    const char *stage = "invalid input";
    char temporary[128] = {0};
    struct stat initial, parent, fresh;
    if (!before || !after || !before_length || !after_length ||
        before_length > GXCL_LIMIT || after_length > GXCL_LIMIT) {
        say(message, capacity, stage, EINVAL); return -1;
    }
    stage = "validate directory";
    if (fstat(directory, &parent)) goto done;
    if (!S_ISDIR(parent.st_mode)) { errno = ENOTDIR; goto done; }
    stage = "validate original";
    if (fstat(original, &initial) || !S_ISREG(initial.st_mode) || initial.st_nlink != 1 ||
        initial.st_uid != geteuid() || (initial.st_mode & (0022 | 07000))) {
        errno = EPERM; goto done;
    }
    stage = "lock original";
    if (flock(original, LOCK_EX | LOCK_NB)) goto done;
    locked = 1;
    stage = "original changed before preparation";
    if (!still_original(directory, original, &initial, before, before_length)) {
        errno = EBUSY; goto done;
    }
    /* O_EXCL prevents following or overwriting an existing item. */
    stage = "create same-directory temporary file";
    for (unsigned attempt = 0; attempt < 128; attempt++) {
        snprintf(temporary, sizeof(temporary), ".gestaltx-canvas-%ld-%u.tmp", (long)getpid(), attempt);
        tmp = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (tmp >= 0 || errno != EEXIST) break;
    }
    if (tmp < 0) { temporary[0] = 0; goto done; }
    stage = "preserve ownership";
    if (fstat(tmp, &fresh)) goto done;
    if ((fresh.st_uid != initial.st_uid || fresh.st_gid != initial.st_gid) &&
        fchown(tmp, initial.st_uid, initial.st_gid)) goto done;
#ifdef __APPLE__
    stage = "preserve ACL and extended attributes";
    if (fcopyfile(original, tmp, NULL, COPYFILE_ACL | COPYFILE_XATTR)) goto done;
#if defined(F_GETPROTECTIONCLASS) && defined(F_SETPROTECTIONCLASS)
    stage = "preserve file protection class";
    int protection_class = fcntl(original, F_GETPROTECTIONCLASS);
    if (protection_class < 0 || fcntl(tmp, F_SETPROTECTIONCLASS, protection_class) < 0) goto done;
    if (fcntl(tmp, F_GETPROTECTIONCLASS) != protection_class) { errno = EIO; goto done; }
#endif
    stage = "preserve file flags";
    if (fchflags(tmp, initial.st_flags)) goto done;
#endif
    stage = "preserve mode";
    if (fchmod(tmp, initial.st_mode & 0777)) goto done;
    stage = "write temporary file";
    size_t offset = 0;
    while (offset < after_length) {
        ssize_t wrote = write(tmp, after + offset, after_length - offset);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { if (!wrote) errno = EIO; goto done; }
        offset += (size_t)wrote;
    }
    stage = "sync temporary file";
    if (fsync(tmp)) goto done;
    stage = "verify temporary file and metadata";
    if (!equal_fd(tmp, after, after_length) || fstat(tmp, &fresh) ||
        fresh.st_uid != initial.st_uid || fresh.st_gid != initial.st_gid ||
        (fresh.st_mode & 07777) != (initial.st_mode & 07777)) { errno = EIO; goto done; }
    stage = "original changed before commit";
    if (!still_original(directory, original, &initial, before, before_length)) {
        errno = EBUSY; goto done;
    }
    stage = "atomic rename";
    if (renameat(directory, temporary, directory, GXCL_NAME)) goto done;
    renamed = 1;
    temporary[0] = 0;
    /* Some iOS filesystems reject fsync(directory). Do not mislabel a completed
       rename as an untouched file. Report durability uncertainty separately. */
    int directory_sync_error = fsync(directory) ? errno : 0;
    stage = "read back committed file";
    check = openat(directory, GXCL_NAME, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (check < 0 || !equal_fd(check, after, after_length)) { errno = EIO; goto done; }
    result = 0;
    if (message && capacity) {
        if (directory_sync_error)
            snprintf(message, capacity, "REPLACED_AND_VERIFIED; directory fsync not confirmed (errno=%d)", directory_sync_error);
        else snprintf(message, capacity, "REPLACED_AND_VERIFIED");
    }
done:
    failure = errno;
    if (check >= 0) close(check);
    if (tmp >= 0) close(tmp);
    if (temporary[0]) unlinkat(directory, temporary, 0);
    if (locked) flock(original, LOCK_UN);
    if (result != 0) {
        result = renamed ? 1 : -1;
        say(message, capacity, stage, failure ? failure : EIO);
    }
    return result;
}
