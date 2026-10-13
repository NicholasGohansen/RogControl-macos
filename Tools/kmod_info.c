// The kmod_info metadata Xcode normally generates for a kernel extension.
#include <mach/kmod.h>

extern kern_return_t RogControl_kern_start(kmod_info_t *, void *);
extern kern_return_t RogControl_kern_stop(kmod_info_t *, void *);
extern kern_return_t _start(kmod_info_t *, void *);
extern kern_return_t _stop(kmod_info_t *, void *);

__attribute__((visibility("default"))) kmod_start_func_t *_realmain = RogControl_kern_start;
__attribute__((visibility("default"))) kmod_stop_func_t *_antimain = RogControl_kern_stop;

__attribute__((visibility("default"))) kmod_info_t KMOD_INFO_NAME = {
	0, KMOD_INFO_VERSION, -1U, KMOD_BUNDLE_ID, KMOD_BUNDLE_VERSION, -1, 0, 0, 0, 0, _start, _stop,
};
