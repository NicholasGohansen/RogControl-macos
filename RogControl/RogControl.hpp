//
//  RogControl.hpp
//  VirtualSMC plugin for ASUS ROG laptops (built for the Strix G17 G713PV).
//
//  Sensors:  fan RPM, CPU and GPU temperatures from the embedded controller.
//  Control:  SMC fan mode/target (Macs Fan Control etc.), ASUS performance modes
//            (Silent/Balanced/Turbo, also bound to Fn+F5), custom fan curves and
//            the battery charge limit, all through the firmware's own WMI methods
//            (\_SB.ATKD.WMNB), the same calls Linux asus-wmi makes.
//

#ifndef RogControl_hpp
#define RogControl_hpp

#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/IOCommandGate.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <stdatomic.h>

#include <VirtualSMCSDK/kern_vsmcapi.hpp>
#include <Headers/kern_util.hpp>

namespace Rog {
	// WMNB method ids
	constexpr uint32_t MethodInit = 0x54494E49; // 'INIT'
	constexpr uint32_t MethodDsts = 0x53545344; // 'DSTS'
	constexpr uint32_t MethodDevs = 0x53564544; // 'DEVS'

	// WMNB device ids (see Linux include/linux/platform_data/x86/asus-wmi.h)
	constexpr uint32_t DevCpuFanSpeed   = 0x00110013;
	constexpr uint32_t DevGpuFanSpeed   = 0x00110014;
	constexpr uint32_t DevCpuFanCurve   = 0x00110024;
	constexpr uint32_t DevGpuFanCurve   = 0x00110025;
	constexpr uint32_t DevThermalPolicy = 0x00120075;
	constexpr uint32_t DevChargeLimit   = 0x00120057;
	constexpr uint32_t DevCpuTemp       = 0x00120094;

	constexpr uint32_t DstsPresent = 0x00010000;
	constexpr uint32_t DstsUnsupported = 0xFFFFFFFE;

	// ATKD notify codes for the Fn+F5 "fan" key
	constexpr uint32_t EventFanBoost = 0x99;
	constexpr uint32_t EventThermalPolicy = 0xAE;

	// Thermal policy values accepted by DEVS 0x00120075
	enum PerfMode : uint8_t {
		PerfBalanced = 0,
		PerfTurbo    = 1,
		PerfSilent   = 2,
		PerfModeCount
	};

	constexpr size_t CurvePoints = 8;
	constexpr size_t MaxFans = 2;           // CPU and GPU fan
	constexpr size_t MaxTemps = 2;          // CPU (EC), GPU (EC)
	constexpr uint32_t PollIntervalMS = 1000;
}

struct RogFanCurve {
	uint8_t temp[Rog::CurvePoints];     // degrees C, ascending
	uint8_t percent[Rog::CurvePoints];  // duty 0-100
};

/**
 *  State shared between the SMC key handlers (any context) and the work loop.
 *  Key handlers only touch atomics; all ACPI work happens on the work loop.
 */
struct RogSharedState {
	_Atomic(uint32_t) rpm[Rog::MaxFans];
	_Atomic(int32_t)  temp[Rog::MaxTemps];
	_Atomic(uint32_t) manualMask;               // F?Md / FS! requests
	_Atomic(uint32_t) target[Rog::MaxFans];     // F?Tg requests, RPM
	_Atomic(uint32_t) minRpm[Rog::MaxFans];
	_Atomic(uint32_t) maxRpm[Rog::MaxFans];
	_Atomic(bool)     controlDirty;
};

class EXPORT RogControl : public IOService {
	OSDeclareDefaultStructors(RogControl)

	static constexpr const char *KeyIndexes = "0123456789ABCDEF";

	static constexpr SMC_KEY KeyFNum = SMC_MAKE_IDENTIFIER('F','N','u','m');
	static constexpr SMC_KEY KeyFS__ = SMC_MAKE_IDENTIFIER('F','S','!',' ');
	static constexpr SMC_KEY KeyF0ID(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'I','D'); }
	static constexpr SMC_KEY KeyF0Ac(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'A','c'); }
	static constexpr SMC_KEY KeyF0Mn(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'M','n'); }
	static constexpr SMC_KEY KeyF0Mx(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'M','x'); }
	static constexpr SMC_KEY KeyF0Md(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'M','d'); }
	static constexpr SMC_KEY KeyF0Tg(size_t i) { return SMC_MAKE_IDENTIFIER('F',KeyIndexes[i],'T','g'); }
	// CPU temperature keys TC0E/F/J/P/T/p belong to SMCAMDProcessor, so the EC reading uses TC0H.
	static constexpr SMC_KEY KeyTC0H = SMC_MAKE_IDENTIFIER('T','C','0','H');
	static constexpr SMC_KEY KeyTG0P = SMC_MAKE_IDENTIFIER('T','G','0','P');
	static constexpr SMC_KEY KeyTG0D = SMC_MAKE_IDENTIFIER('T','G','0','D');
	static constexpr SMC_KEY KeyTGDD = SMC_MAKE_IDENTIFIER('T','G','D','D');

	VirtualSMCAPI::Plugin vsmcPlugin {
		xStringify(PRODUCT_NAME),
		parseModuleVersion(xStringify(MODULE_VERSION)),
		VirtualSMCAPI::Version,
	};

	IONotifier *vsmcNotifier {nullptr};
	IONotifier *sleepNotifier {nullptr};
	IOACPIPlatformDevice *atkd {nullptr};
	IOWorkLoop *workLoop {nullptr};
	IOCommandGate *commandGate {nullptr};
	IOTimerEventSource *poller {nullptr};

	RogSharedState shared {};

	// Work loop state
	bool haveSensorMethod {false};
	bool haveFanCurves {false};
	bool havePolicy {false};
	bool haveChargeLimit {false};
	bool nvramLoaded {false};
	uint8_t perfMode {Rog::PerfBalanced};
	bool perfModeKnown {false};
	uint8_t chargeLimit {0};
	RogFanCurve factoryCurve[Rog::PerfModeCount][Rog::MaxFans] {};
	bool factoryCurveValid[Rog::PerfModeCount][Rog::MaxFans] {};
	RogFanCurve userCurve[Rog::MaxFans] {};
	bool userCurveValid[Rog::MaxFans] {};
	RogFanCurve appliedCurve[Rog::MaxFans] {};
	bool customApplied {false};
	bool forceReapply {false};
	uint32_t pollCount {0};

	bool wmnb(uint32_t method, uint32_t device, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4, OSObject **result);
	bool wmnbInt(uint32_t method, uint32_t device, uint32_t arg, uint32_t &value);
	bool readFactoryCurve(uint8_t mode, size_t fan, RogFanCurve &curve);
	bool writeCurve(size_t fan, const RogFanCurve &curve);
	bool writePerfMode(uint8_t mode);
	bool writeChargeLimit(uint8_t limit);

	void refreshSensors();
	void applyFanControl(bool force);
	void loadNvramSettings();
	void storeNvramByte(const char *name, uint8_t value);
	void publishStatus();
	void cyclePerfMode();

	IOReturn setPropertiesGated(OSDictionary *dict);
	void handleAtkEvent(uint32_t code);

	static uint8_t curveModeForPolicy(uint8_t mode);
	static bool validCurve(const RogFanCurve &curve);
	static void flatCurve(RogFanCurve &curve, uint8_t percent);

	static bool vsmcNotificationHandler(void *sensors, void *refCon, IOService *vsmc, IONotifier *notifier);
	static IOReturn sleepHandler(void *target, void *refCon, UInt32 messageType, IOService *provider, void *messageArgument, vm_size_t argSize);

public:
	IOService *probe(IOService *provider, SInt32 *score) override;
	bool start(IOService *provider) override;
	void stop(IOService *provider) override;
	IOReturn message(UInt32 type, IOService *provider, void *argument) override;
	IOReturn setProperties(OSObject *properties) override;
};

#endif /* RogControl_hpp */
