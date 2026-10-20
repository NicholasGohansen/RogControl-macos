/*
 * tufrgb: set the ASUS TUF keyboard RGB through RogControl.kext.
 *
 *   sudo ./tufrgb static ff0000
 *   sudo ./tufrgb breathe 00ff00 fast
 *   sudo ./tufrgb cycle [slow|mid|fast]
 *   sudo ./tufrgb strobe [slow|mid|fast]
 *
 * Build: clang -o tufrgb tufrgb.c -framework IOKit -framework CoreFoundation
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

static int speed_of(const char *s) {
	if (!s || !strcmp(s, "fast")) return 0xF5;
	if (!strcmp(s, "mid")) return 0xEB;
	if (!strcmp(s, "slow")) return 0xE1;
	return -1;
}

int main(int argc, char **argv) {
	if (argc < 2) {
		fprintf(stderr, "usage: tufrgb static|breathe RRGGBB [slow|mid|fast] | cycle|strobe [slow|mid|fast]\n");
		return 1;
	}
	int mode, speed = 0xF5;
	unsigned rgb = 0xFFFFFF;
	int next = 2;
	if (!strcmp(argv[1], "static") || !strcmp(argv[1], "breathe")) {
		mode = argv[1][0] == 's' ? 0 : 1;
		if (argc < 3 || strlen(argv[2]) != 6) { fprintf(stderr, "need a colour like ff0000\n"); return 1; }
		rgb = (unsigned)strtoul(argv[2], NULL, 16);
		next = 3;
	} else if (!strcmp(argv[1], "cycle")) {
		mode = 2;
	} else if (!strcmp(argv[1], "strobe")) {
		mode = 10;
	} else {
		fprintf(stderr, "unknown mode %s\n", argv[1]);
		return 1;
	}
	if (argc > next && (speed = speed_of(argv[next])) < 0) { fprintf(stderr, "speed: slow|mid|fast\n"); return 1; }

	io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RogControl"));
	if (!svc) { fprintf(stderr, "RogControl service not found (is the kext loaded?)\n"); return 1; }

	uint8_t bytes[5] = {(uint8_t)mode, (uint8_t)(rgb >> 16), (uint8_t)(rgb >> 8), (uint8_t)rgb, (uint8_t)speed};
	CFDataRef data = CFDataCreate(NULL, bytes, sizeof(bytes));
	CFStringRef key = CFSTR("TufRgb");
	CFDictionaryRef dict = CFDictionaryCreate(NULL, (const void **)&key, (const void **)&data, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);
	CFRelease(dict);
	CFRelease(data);
	IOObjectRelease(svc);
	if (kr != KERN_SUCCESS) { fprintf(stderr, "failed: 0x%x (run with sudo)\n", kr); return 1; }
	printf("ok\n");
	return 0;
}
