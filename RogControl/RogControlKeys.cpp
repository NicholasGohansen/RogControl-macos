//
//  RogControlKeys.cpp
//  RogControl
//

#include "RogControlKeys.hpp"
#include <IOKit/hid/IOHIDUsageTables.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <kern/clock.h>

OSDefineMetaClassAndStructors(RogControlKeys, IOHIDEventService)

bool RogControlKeys::handleStart(IOService *provider) {
	if (!IOHIDEventService::handleStart(provider))
		return false;
	transport = OSString::withCString("ACPI");
	product = OSString::withCString("RogControl Keys");
	manufacturer = OSString::withCString("ASUSTeK");
	// hidd treats a service as a keyboard (and its brightness keys as such) by its usage pairs.
	auto pairs = OSArray::withCapacity(2);
	static const uint32_t usages[][2] = {
		{kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard},
		{kHIDPage_Consumer, kHIDUsage_Csmr_ConsumerControl},
	};
	for (auto &u : usages) {
		auto pair = OSDictionary::withCapacity(2);
		auto page = OSNumber::withNumber(u[0], 32);
		auto usage = OSNumber::withNumber(u[1], 32);
		if (pairs && pair && page && usage) {
			pair->setObject(kIOHIDDeviceUsagePageKey, page);
			pair->setObject(kIOHIDDeviceUsageKey, usage);
			pairs->setObject(pair);
		}
		OSSafeReleaseNULL(page);
		OSSafeReleaseNULL(usage);
		OSSafeReleaseNULL(pair);
	}
	if (pairs)
		setProperty(kIOHIDDeviceUsagePairsKey, pairs);
	OSSafeReleaseNULL(pairs);
	return transport && product && manufacturer;
}

void RogControlKeys::free() {
	OSSafeReleaseNULL(transport);
	OSSafeReleaseNULL(product);
	OSSafeReleaseNULL(manufacturer);
	IOHIDEventService::free();
}

void RogControlKeys::press(uint32_t usagePage, uint32_t usage) {
	dispatchKeyboardEvent(mach_absolute_time(), usagePage, usage, 1);
	dispatchKeyboardEvent(mach_absolute_time(), usagePage, usage, 0);
}

OSString *RogControlKeys::getTransport() {
	return transport;
}

OSString *RogControlKeys::getManufacturer() {
	return manufacturer;
}

OSString *RogControlKeys::getProduct() {
	return product;
}

UInt32 RogControlKeys::getVendorID() {
	return 0x0B05;  // ASUS
}

UInt32 RogControlKeys::getProductID() {
	return 0;
}

UInt32 RogControlKeys::getPrimaryUsagePage() {
	return kHIDPage_GenericDesktop;
}

UInt32 RogControlKeys::getPrimaryUsage() {
	return kHIDUsage_GD_Keyboard;
}
