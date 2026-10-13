// rogctl: command line control for RogControl.kext
//
//   rogctl                         show fans, temperatures and settings
//   rogctl watch                   same, refreshed every second
//   rogctl mode silent|balanced|turbo
//   rogctl charge <20-100>         battery charge limit
//   rogctl fan <0-100>             force both fans to a duty cycle
//   rogctl fan auto                return fans to firmware control
//   rogctl curve cpu|gpu T:P,...   custom curve, 8 points of temperature:percent
//   rogctl curve reset             drop custom curves
//
// Settings changes need root (sudo). Mode and charge limit persist across reboots.

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static io_service_t findService(void) {
	io_service_t svc = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("RogControl"));
	if (!svc) {
		fprintf(stderr, "RogControl.kext is not loaded\n");
		exit(1);
	}
	return svc;
}

static long numberProp(CFDictionaryRef props, const char *key) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFNumberRef n = CFDictionaryGetValue(props, k);
	CFRelease(k);
	long v = -1;
	if (n && CFGetTypeID(n) == CFNumberGetTypeID())
		CFNumberGetValue(n, kCFNumberLongType, &v);
	return v;
}

static const char *stringProp(CFDictionaryRef props, const char *key, char *buf, size_t len) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFStringRef s = CFDictionaryGetValue(props, k);
	CFRelease(k);
	if (s && CFGetTypeID(s) == CFStringGetTypeID() && CFStringGetCString(s, buf, (CFIndex)len, kCFStringEncodingUTF8))
		return buf;
	return "?";
}

static void printCurve(CFDictionaryRef props, const char *key, const char *label) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFDataRef d = CFDictionaryGetValue(props, k);
	CFRelease(k);
	if (!d || CFGetTypeID(d) != CFDataGetTypeID() || CFDataGetLength(d) != 16)
		return;
	const UInt8 *b = CFDataGetBytePtr(d);
	printf("  %s curve:", label);
	for (int i = 0; i < 8; i++)
		printf(" %u°C:%u%%", b[i], b[8 + i]);
	printf("\n");
}

static void showStatus(io_service_t svc) {
	CFMutableDictionaryRef props = NULL;
	if (IORegistryEntryCreateCFProperties(svc, &props, NULL, 0) != KERN_SUCCESS || !props) {
		fprintf(stderr, "cannot read RogControl properties\n");
		exit(1);
	}
	char buf[64], buf2[64];
	printf("Performance mode : %s\n", stringProp(props, "PerformanceMode", buf, sizeof(buf)));
	printf("Fan control      : %s\n", stringProp(props, "FanControl", buf2, sizeof(buf2)));
	printf("CPU fan          : %ld RPM\n", numberProp(props, "CPU Fan RPM"));
	printf("GPU fan          : %ld RPM\n", numberProp(props, "GPU Fan RPM"));
	printf("CPU temperature  : %ld °C\n", numberProp(props, "CPU Temperature"));
	printf("GPU temperature  : %ld °C\n", numberProp(props, "GPU Temperature"));
	long charge = numberProp(props, "ChargeLimit");
	if (charge > 0)
		printf("Charge limit     : %ld%%\n", charge);
	printCurve(props, "AppliedCurveCPU", "CPU");
	printCurve(props, "AppliedCurveGPU", "GPU");
	CFRelease(props);
}

static void setProps(io_service_t svc, CFDictionaryRef dict) {
	kern_return_t kr = IORegistryEntrySetCFProperties(svc, dict);
	if (kr == kIOReturnNotPrivileged) {
		fprintf(stderr, "permission denied, run with sudo\n");
		exit(1);
	}
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "RogControl rejected the setting (0x%x)\n", kr);
		exit(1);
	}
}

static void setNumber(io_service_t svc, const char *key, int value) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberIntType, &value);
	CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&n, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	setProps(svc, d);
	CFRelease(d);
	CFRelease(n);
	CFRelease(k);
}

static void setObject(io_service_t svc, const char *key, CFTypeRef value) {
	CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
	CFDictionaryRef d = CFDictionaryCreate(NULL, (const void **)&k, (const void **)&value, 1,
		&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	setProps(svc, d);
	CFRelease(d);
	CFRelease(k);
}

static int parseCurve(const char *spec, UInt8 out[16]) {
	int n = 0;
	const char *p = spec;
	while (*p && n < 8) {
		unsigned t, pct;
		int used = 0;
		if (sscanf(p, "%u:%u%n", &t, &pct, &used) != 2 || t > 120 || pct > 100)
			return 0;
		out[n] = (UInt8)t;
		out[8 + n] = (UInt8)pct;
		n++;
		p += used;
		if (*p == ',')
			p++;
	}
	if (n != 8 || *p)
		return 0;
	for (int i = 1; i < 8; i++)
		if (out[i] < out[i - 1] || out[8 + i] < out[8 + i - 1])
			return 0;
	return 1;
}

static void usage(void) {
	fprintf(stderr,
		"usage: rogctl [watch]\n"
		"       rogctl mode silent|balanced|turbo\n"
		"       rogctl charge <20-100>\n"
		"       rogctl fan <0-100>|auto\n"
		"       rogctl curve cpu|gpu T:P,T:P,T:P,T:P,T:P,T:P,T:P,T:P\n"
		"       rogctl curve reset\n");
	exit(2);
}

int main(int argc, char **argv) {
	io_service_t svc = findService();

	if (argc == 1) {
		showStatus(svc);
	} else if (!strcmp(argv[1], "watch")) {
		for (;;) {
			printf("\033[H\033[2J");
			showStatus(svc);
			fflush(stdout);
			sleep(1);
		}
	} else if (!strcmp(argv[1], "mode") && argc == 3) {
		CFStringRef m = CFStringCreateWithCString(NULL, argv[2], kCFStringEncodingUTF8);
		setObject(svc, "PerformanceMode", m);
		CFRelease(m);
		showStatus(svc);
	} else if (!strcmp(argv[1], "charge") && argc == 3) {
		int v = atoi(argv[2]);
		if (v < 20 || v > 100)
			usage();
		setNumber(svc, "ChargeLimit", v);
		showStatus(svc);
	} else if (!strcmp(argv[1], "fan") && argc == 3) {
		int v = !strcmp(argv[2], "auto") ? -1 : atoi(argv[2]);
		if (v > 100 || (v < 0 && strcmp(argv[2], "auto")))
			usage();
		setNumber(svc, "FanSpeedPercent", v);
		showStatus(svc);
	} else if (!strcmp(argv[1], "curve") && argc == 3 && !strcmp(argv[2], "reset")) {
		setObject(svc, "FanCurvesReset", kCFBooleanTrue);
		showStatus(svc);
	} else if (!strcmp(argv[1], "curve") && argc == 4) {
		const char *key = !strcmp(argv[2], "cpu") ? "FanCurveCPU" : !strcmp(argv[2], "gpu") ? "FanCurveGPU" : NULL;
		UInt8 curve[16];
		if (!key || !parseCurve(argv[3], curve)) {
			fprintf(stderr, "curve needs 8 ascending points like 40:10,50:20,60:30,70:45,75:55,80:70,90:90,100:100\n");
			return 2;
		}
		CFDataRef d = CFDataCreate(NULL, curve, sizeof(curve));
		setObject(svc, key, d);
		CFRelease(d);
		showStatus(svc);
	} else {
		usage();
	}

	IOObjectRelease(svc);
	return 0;
}
