#ifndef NV_LOG_H
#define NV_LOG_H

#import <Foundation/Foundation.h>
#import <os/log.h>

//dynamic strings stay <private> unless a format marks them {public}; never mark note text, titles, file names or paths public
#define NV_LOG_CATEGORY(function, category) \
static inline os_log_t function(void) { \
    static os_log_t log; \
    static dispatch_once_t once; \
    dispatch_once(&once, ^{ log = os_log_create("net.notational.velocity", category); }); \
    return log; \
}

NV_LOG_CATEGORY(NVLogApplication, "application")
NV_LOG_CATEGORY(NVLogEditor, "editor")
NV_LOG_CATEGORY(NVLogExternalEditing, "external-editing")
NV_LOG_CATEGORY(NVLogImportExport, "import-export")
NV_LOG_CATEGORY(NVLogNoteList, "note-list")
NV_LOG_CATEGORY(NVLogNotes, "notes")
NV_LOG_CATEGORY(NVLogStorage, "storage")
NV_LOG_CATEGORY(NVLogPreferences, "preferences")

#endif
