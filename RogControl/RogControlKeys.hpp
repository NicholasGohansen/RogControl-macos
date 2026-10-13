//
//  RogControlKeys.hpp
//  RogControl
//
//  A keyboard-like HID event service for keys that the N-KEY keyboard reports in its vendor
//  report (0x5A) and macOS would never see: Fn+F7/F8 become the brightness keys Apple
//  keyboards send, so macOS changes the panel brightness itself and shows its indicator.
//

#ifndef RogControlKeys_hpp
#define RogControlKeys_hpp

#include <IOKit/hid/IOHIDEventService.h>

class RogControlKeys : public IOHIDEventService {
	OSDeclareDefaultStructors(RogControlKeys)

	OSString *transport {nullptr};
	OSString *product {nullptr};
	OSString *manufacturer {nullptr};

public:
	// Presses and releases one key.
	void press(uint32_t usagePage, uint32_t usage);

	void free() override;

protected:
	bool handleStart(IOService *provider) override;
	OSString *getTransport() override;
	OSString *getManufacturer() override;
	OSString *getProduct() override;
	UInt32 getVendorID() override;
	UInt32 getProductID() override;
	UInt32 getPrimaryUsagePage() override;
	UInt32 getPrimaryUsage() override;
};

#endif /* RogControlKeys_hpp */
