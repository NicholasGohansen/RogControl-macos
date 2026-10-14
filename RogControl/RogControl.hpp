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
#include <IOKit/IOInterruptEventSource.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/pwr_mgt/RootDomain.h>
#include <IOKit/hid/IOHIDDevice.h>
#include "RogControlKeys.hpp"
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

	// Power limits and NVIDIA settings (Linux asus-wmi / asusd "tunings")
	enum Tunable : uint8_t {
		TunePl1,        // PPT_PL1_SPL, sustained package power (W)
		TunePl2,        // PPT_PL2_SPPT, short boost power (W)
		TuneFppt,       // PPT_PL3_FPPT, fast boost power (W)
		TuneNvBoost,    // NV_DYN_BOOST, extra GPU power from the CPU budget (W)
		TuneNvTemp,     // NV_THERM_TARGET, GPU temperature target (C)
		TunableCount
	};
	struct TunableInfo {
		const char *name;
		uint32_t device;
		uint8_t min, max;
	};
	constexpr TunableInfo Tunables[TunableCount] = {
		{"PowerLimitPL1",   0x001200A3, 5, 150},
		{"PowerLimitPL2",   0x001200A0, 5, 150},
		{"PowerLimitFPPT",  0x001200C1, 5, 150},
		{"GPUDynamicBoost", 0x001200C0, 5, 25},
		{"GPUTempTarget",   0x001200C2, 75, 87},
	};

	// AMD CPPC (what Linux amd-pstate uses for scaling_max_freq and EPP)
	constexpr uint32_t MsrCppcCap1   = 0xC00102B0;
	constexpr uint32_t MsrCppcEnable = 0xC00102B1;
	constexpr uint32_t MsrCppcReq    = 0xC00102B3;
	constexpr uint32_t MsrHwcr       = 0xC0010015;
	constexpr uint64_t HwcrCpbDis    = 1ULL << 25;
	constexpr uint32_t MsrPState0    = 0xC0010064;
	constexpr uint8_t EppPerformance = 0x00, EppBalancePerformance = 0x80,
		EppBalancePower = 0xBF, EppPower = 0xFF;

	constexpr uint32_t DstsPresent = 0x00010000;
	constexpr uint32_t DstsUnsupported = 0xFFFFFFFE;

	// ATKD notify codes for the Fn+F5 "fan" key
	constexpr uint32_t EventFanBoost = 0x99;
	constexpr uint32_t EventThermalPolicy = 0xAE;
	// Fn+F3 / Fn+F2 keyboard backlight (EC queries 0x17 / 0x16)
	constexpr uint32_t EventKbdLightUp = 0xC4;
	constexpr uint32_t EventKbdLightDown = 0xC5;
	constexpr uint32_t EventTouchpadToggle = 0x6B;   // Fn+F10
	// The N-KEY keyboard reports the same codes in input report 0x5A (Linux hid-asus,
	// usage page 0xFF31), plus screen brightness, which the ATK path never sends here.
	constexpr uint32_t EventScreenDown = 0x10;       // Fn+F7
	constexpr uint32_t EventScreenUp = 0x20;         // Fn+F8
	constexpr uint32_t ScreenSteps = 16;             // like macOS brightness keys
	// The firmware re-initialises things for a while after boot (the first keyboard light write
	// is acknowledged and then lost), so stored settings are written again at these poll counts
	// after the keyboard shows up / after the mode was restored.
	constexpr uint32_t KbdReassertPolls[] = {3, 10, 30, 60};
	constexpr uint32_t PerfReassertPolls = 40;
	constexpr uint32_t PerfRestoreTries = 60;
	constexpr size_t EventLogSize = 24;

	// VoodooI2C(HID) multitouch driver messages (the AsusSMC / VoodooPS2 convention), data is bool *
	constexpr uint32_t MessageSetTouchStatus = iokit_vendor_specific_msg(100);
	constexpr uint32_t MessageGetTouchStatus = iokit_vendor_specific_msg(101);

	// N-KEY USB keyboard (Linux hid-asus): feature report 0x5A
	constexpr uint32_t AsusVendorID = 0x0B05;
	constexpr uint8_t KbdReportID = 0x5A;
	// The G713/G733 firmware sometimes sends consumer "Power" (report 0x02, usage 0x30) along with
	// ordinary key presses; macOS then opens the shut down dialog. hid-asus drops these reports.
	constexpr uint8_t KbdConsumerReportID = 0x02;
	constexpr uint8_t KbdConsumerPower = 0x30;
	// Aura lighting: output report 0x5D (asusd writes it padded to the 64-byte report size),
	// after a feature report "]ASUS Tech.Inc." like hid-asus sends at probe.
	constexpr uint8_t AuraReportID = 0x5D;
	constexpr unsigned AuraMaxReports = 16;
	constexpr uint8_t KbdMaxLevel = 3;
	constexpr uint32_t KbdRetrySeconds = 180;

	// Panel backlight in dGPU (MUX) mode: NVIDIA "WMI EC backlight" (Linux nvidia-wmi-ec-backlight),
	// WMAA(0, method, {u8 mode @0, u32 value @4}) on the PNP0C14 device whose _WDG has this GUID.
	constexpr uint8_t NvWmiBacklightGuid[16] = {0x13, 0x96, 0x3E, 0x60, 0x25, 0xEF, 0x38, 0x43,
		0xA3, 0xD0, 0xC4, 0x61, 0x77, 0x51, 0x6D, 0xB7};
	constexpr uint32_t BacklightMethodLevel = 1, BacklightMethodSource = 2;
	constexpr uint32_t BacklightGet = 0, BacklightSet = 1, BacklightGetMax = 2;
	// Source 1 = the GPU drives the panel (MUX in dGPU mode: the NVIDIA driver does brightness),
	// 2 = the EC does (WMAA level writes only work then).
	constexpr uint32_t BacklightSourceGpu = 1, BacklightSourceEc = 2;
	constexpr uint32_t BacklightSourceEC = 2;

	// Every ATK hotkey is also sent to user-space clients (rogd) with this message, code in the argument.
	constexpr uint32_t MessageHotkey = iokit_vendor_specific_msg(0x52);

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
	// Keyboard backlight through the N-KEY keyboard's HID feature report
	IOHIDDevice *kbd {nullptr};
	bool kbdReady {false};          // handshake sent to this keyboard instance
	bool kbdPending {false};        // level still to be written (keyboard not up yet)
	uint32_t kbdWaited {0};
	uint8_t kbdLevel {Rog::KbdMaxLevel};
	bool kbdLevelKnown {false};     // a level was saved or set; otherwise the keyboard is left alone
	OSArray *auraReports {nullptr}; // last Aura packets from rogd (OSData, report ID first)
	bool auraReady {false};         // LED handshake sent to this keyboard instance
	bool auraPending {false};       // packets still to be sent (keyboard not up yet)
	uint32_t auraWaited {0};
	uint32_t kbdFoundAt {0};        // pollCount when this keyboard instance was found
	IOACPIPlatformDevice *backlightWmi {nullptr};
	uint32_t screenMax {0};          // 0 = no WMI EC backlight
	uint32_t screenSource {0};
	uint32_t screenLevel {0};
	IOInterruptEventSource *hotkeySource {nullptr};
	RogControlKeys *keys {nullptr};
	uint64_t lastHotkeyTime {0};
	bool lastHotkeyFromKeyboard {false};
	bool touchpadEnabled {true};
	bool touchpadFound {false};
	uint32_t lastHotkey {0};
	uint32_t hotkeyCount {0};

	bool haveTunable[Rog::TunableCount] {};
	uint8_t tunable[Rog::TunableCount] {};  // 0 = firmware default
	bool tunablesDirty {false};

	// CPU frequency cap through CPPC
	bool cppcAllowed {true};
	bool cppcSupported {false};
	bool cppcActive {false};
	bool cpuDirty {false};
	uint32_t cpuMaxMHz {0};                 // 0 = no cap
	uint8_t cpuEpp {Rog::EppBalancePerformance};
	uint32_t nominalMHz {0};
	uint32_t cppcCores {0};
	uint32_t cppcFailedCores {0};
	uint8_t cppcHighest {0}, cppcNominal {0}, cppcLowestNonlinear {0}, cppcLowest {0}, cppcMaxPerf {0};
	bool bootArgsApplied {false};
	uint8_t perfMode {Rog::PerfBalanced};
	bool perfModeKnown {false};
	int32_t perfRestore {-1};        // saved mode not yet accepted by the firmware
	uint32_t perfRestoreTries {0};
	uint32_t perfRestoredAt {0};     // pollCount of the restore, to write it once more later
	char eventLog[Rog::EventLogSize][72] {};
	uint32_t eventCount {0};
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
	void writeTunables();
	IOHIDDevice *findKeyboard();
	bool sendKbdReport(const uint8_t *bytes, size_t len, IOHIDReportType type = kIOHIDReportTypeFeature);
	bool sendAuraReports();
	bool writeKbdLevel(uint8_t level);
	bool setTouchpad(bool enable);
	void findBacklight();
	bool backlightCall(uint32_t method, uint32_t mode, uint32_t value, uint32_t &result);
	bool setScreenLevel(uint32_t level);
	void handleHotkey(uint32_t code, bool fromKeyboard);
	void applyCpuLimit();

	void refreshSensors();
	void applyFanControl(bool force);
	void applyBootArgs();
	void publishStatus();
	void note(const char *format, ...) __printflike(2, 3);
	void cyclePerfMode();

	IOReturn setPropertiesGated(OSDictionary *dict);
	void handleAtkEvent(uint32_t code);

	static uint8_t curveModeForPolicy(uint8_t mode);
	static bool validCurve(const RogFanCurve &curve);
	static void flatCurve(RogFanCurve &curve, uint8_t percent);
	static bool eppFromObject(OSObject *obj, uint8_t &epp);

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
