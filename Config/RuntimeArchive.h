#ifndef PUFFLET_RUNTIME_ARCHIVE_H
#define PUFFLET_RUNTIME_ARCHIVE_H
#include <sys/types.h>
#include <libproc.h>
#include <ApplicationServices/ApplicationServices.h>

// Swift cannot call the public Process Manager APIs directly. Keep the small
// process-type assertion here for native integration tests.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline int pufflet_process_is_background(pid_t pid) {
    ProcessSerialNumber serial;
    if (GetProcessForPID(pid, &serial) != noErr) return 0;
    CFDictionaryRef info = ProcessInformationCopyDictionary(&serial, kProcessDictionaryIncludeAllInformationMask);
    if (!info) return 0;
    int result = CFDictionaryGetValue(info, CFSTR("LSBackgroundOnly")) == kCFBooleanTrue;
    CFRelease(info);
    return result;
}
#pragma clang diagnostic pop
#include <sys/stat.h>
#include <stdint.h>
#include <stddef.h>
// Stable libarchive read ABI, documented in macOS archive_read(3)/archive_entry(3).
// The system ships libarchive but omits its headers from the public macOS SDK.
struct archive;
struct archive_entry;
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_format_tar(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data(struct archive *, void *, size_t);
const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
const char *archive_entry_symlink_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
#define ARCHIVE_OK 0
#define ARCHIVE_EOF 1
#define AE_IFREG S_IFREG
#define AE_IFDIR S_IFDIR
#define AE_IFLNK S_IFLNK
#endif
