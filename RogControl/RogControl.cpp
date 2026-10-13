//
//  RogControl.cpp
//  RogControl
//

#include "RogControl.hpp"
#include "KeyImplementations.hpp"

#include <IOKit/IOUserClient.h>
#include <IOKit/IOBufferMemoryDescriptor.h>
#include <IOKit/IODeviceTreeSupport.h>
#include <IOKit/acpi/IOACPITypes.h>
#include <kern/task.h>
#include <pexpert/pexpert.h>
#include <Headers/kern_version.hpp>

OSDefineMetaClassAndStructors(RogControl, IOService)

bool ADDPR(debugEnabled) = false;
uint32_t ADDPR(debugPrintDelay) = 0;

// Custom curves never go below this duty at or above this temperature.
static constexpr uint8_t SafetyTemp = 90;
static constexpr uint8_t SafetyPercent = 80;
static bool safetyFloor = true;

static const char *const PerfModeNames[Rog::PerfModeCount] = {"balanced", "turbo", "silent"};

// Kernel functions from com.apple.kpi.unsupported (AMDRyzenCPUPowerManagement uses the same ones).
extern "C" {
	int cpu_number(void);
	void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);
	int rdmsr_carefully(uint32_t msr, uint32_t *lo, uint32_t *hi);
}

static inline void rogWrmsr(uint32_t msr, uint64_t value) {
	asm volatile("wrmsr" :: "c"(msr), "a"(static_cast<uint32_t>(value)), "d"(static_cast<uint32_t>(value >> 32)));
}

static bool rogRdmsr(uint32_t msr, uint64_t &value) {
	uint32_t lo = 0, hi = 0;
	if (rdmsr_carefully(msr, &lo, &hi) != 0)
		return false;
	value = (static_cast<uint64_t>(hi) << 32) | lo;
	return true;
}

namespace {
// One request for every core: Linux amd-pstate (active mode) does the same per CPU,
// enable CPPC, then MSR_AMD_CPPC_REQ = max_perf | min_perf << 8 | desired 0 (autonomous) | EPP << 24.
struct CppcJob {
	uint32_t maxMHz;
	uint32_t nominalMHz;
	uint8_t epp;
	_Atomic(uint32_t) ok;
	_Atomic(uint32_t) failed;
	_Atomic(bool) recorded;
	uint8_t highest, nominal, lowestNonlinear, lowest, maxPerf;
};
}

static void cppcApplyOnCpu(void *arg) {
	auto job = static_cast<CppcJob *>(arg);
	uint64_t cap = 0;
	if (!rogRdmsr(Rog::MsrCppcCap1, cap) || (cap & 0xFFFFFFFF) == 0) {
		atomic_fetch_add_explicit(&job->failed, 1, memory_order_relaxed);
		return;
	}
	uint8_t lowest = cap & 0xFF, lowestNonlinear = (cap >> 8) & 0xFF;
	uint8_t nominal = (cap >> 16) & 0xFF, highest = (cap >> 24) & 0xFF;
	uint32_t maxPerf = highest;
	if (job->maxMHz && job->nominalMHz && nominal) {
		maxPerf = job->maxMHz * nominal / job->nominalMHz;
		if (maxPerf > highest)
			maxPerf = highest;
		if (maxPerf < lowest)
			maxPerf = lowest;
	}
	rogWrmsr(Rog::MsrCppcEnable, 1);
	rogWrmsr(Rog::MsrCppcReq, maxPerf | (static_cast<uint64_t>(lowest) << 8) |
		(static_cast<uint64_t>(job->epp) << 24));
	// Frequencies above nominal need Core Performance Boost; the cap is CPPC's job now.
	uint64_t hwcr = 0;
	if (rogRdmsr(Rog::MsrHwcr, hwcr) && (hwcr & Rog::HwcrCpbDis))
		rogWrmsr(Rog::MsrHwcr, hwcr & ~Rog::HwcrCpbDis);
	bool expected = false;
	if (atomic_compare_exchange_strong(&job->recorded, &expected, true)) {
		job->highest = highest;
		job->nominal = nominal;
		job->lowestNonlinear = lowestNonlinear;
		job->lowest = lowest;
		job->maxPerf = static_cast<uint8_t>(maxPerf);
	}
	atomic_fetch_add_explicit(&job->ok, 1, memory_order_relaxed);
}

static inline uint32_t pack4(const uint8_t *v) {
	return v[0] | (v[1] << 8) | (v[2] << 16) | (static_cast<uint32_t>(v[3]) << 24);
}

uint8_t RogControl::curveModeForPolicy(uint8_t mode) {
	// The fan curve DSTS index swaps silent and turbo compared to the thermal policy.
	if (mode == Rog::PerfTurbo) return 2;
	if (mode == Rog::PerfSilent) return 1;
	return 0;
}

bool RogControl::validCurve(const RogFanCurve &curve) {
	for (size_t i = 0; i < Rog::CurvePoints; i++) {
		if (curve.temp[i] > 120 || curve.percent[i] > 100)
			return false;
		if (i > 0 && (curve.temp[i] < curve.temp[i - 1] || curve.percent[i] < curve.percent[i - 1]))
			return false;
	}
	return true;
}

void RogControl::flatCurve(RogFanCurve &curve, uint8_t percent) {
	static constexpr uint8_t temps[Rog::CurvePoints] = {30, 40, 50, 60, 70, 80, 90, 100};
	for (size_t i = 0; i < Rog::CurvePoints; i++) {
		curve.temp[i] = temps[i];
		curve.percent[i] = percent;
	}
}

bool RogControl::eppFromObject(OSObject *obj, uint8_t &epp) {
	if (auto num = OSDynamicCast(OSNumber, obj)) {
		auto v = num->unsigned32BitValue();
		if (v > 255)
			return false;
		epp = static_cast<uint8_t>(v);
		return true;
	}
	static const struct { const char *name; uint8_t value; } names[] = {
		{"performance", Rog::EppPerformance}, {"balance_performance", Rog::EppBalancePerformance},
		{"balance_power", Rog::EppBalancePower}, {"power", Rog::EppPower},
	};
	if (auto str = OSDynamicCast(OSString, obj))
		for (auto &n : names)
			if (str->isEqualTo(n.name)) {
				epp = n.value;
				return true;
			}
	return false;
}

bool RogControl::wmnb(uint32_t method, uint32_t device, uint32_t a1, uint32_t a2, uint32_t a3, uint32_t a4, OSObject **result) {
	// Same layout as Linux asus-wmi struct bios_args: six little-endian dwords.
	uint32_t args[6] = {device, a1, a2, a3, a4, 0};
	OSObject *params[3] = {
		OSNumber::withNumber(0ULL, 32),
		OSNumber::withNumber(method, 32),
		OSData::withBytes(args, sizeof(args)),
	};

	IOReturn ret = kIOReturnNoMemory;
	if (params[0] && params[1] && params[2])
		ret = atkd->evaluateObject("WMNB", result, params, 3);

	for (auto &p : params)
		OSSafeReleaseNULL(p);

	if (ret != kIOReturnSuccess)
		DBGLOG("rog", "WMNB %08X dev %08X failed %08X", method, device, ret);
	return ret == kIOReturnSuccess;
}

bool RogControl::wmnbInt(uint32_t method, uint32_t device, uint32_t arg, uint32_t &value) {
	OSObject *result = nullptr;
	if (!wmnb(method, device, arg, 0, 0, 0, &result))
		return false;
	auto num = OSDynamicCast(OSNumber, result);
	if (num)
		value = num->unsigned32BitValue();
	OSSafeReleaseNULL(result);
	return num != nullptr;
}

bool RogControl::readFactoryCurve(uint8_t mode, size_t fan, RogFanCurve &curve) {
	OSObject *result = nullptr;
	if (!wmnb(Rog::MethodDsts, Rog::DevCpuFanCurve + static_cast<uint32_t>(fan), curveModeForPolicy(mode), 0, 0, 0, &result))
		return false;
	bool ok = false;
	auto buf = OSDynamicCast(OSData, result);
	if (buf && buf->getLength() >= sizeof(RogFanCurve)) {
		lilu_os_memcpy(&curve, buf->getBytesNoCopy(), sizeof(RogFanCurve));
		ok = validCurve(curve);
	}
	OSSafeReleaseNULL(result);
	return ok;
}

bool RogControl::writeCurve(size_t fan, const RogFanCurve &requested) {
	RogFanCurve curve = requested;
	if (safetyFloor) {
		for (size_t i = 0; i < Rog::CurvePoints; i++)
			if (curve.temp[i] >= SafetyTemp && curve.percent[i] < SafetyPercent)
				curve.percent[i] = SafetyPercent;
		// Keep percentages non-decreasing after the floor was applied.
		for (size_t i = 1; i < Rog::CurvePoints; i++)
			if (curve.percent[i] < curve.percent[i - 1])
				curve.percent[i] = curve.percent[i - 1];
	}

	uint32_t value = 0;
	OSObject *result = nullptr;
	bool ok = wmnb(Rog::MethodDevs, Rog::DevCpuFanCurve + static_cast<uint32_t>(fan),
		pack4(&curve.temp[0]), pack4(&curve.temp[4]), pack4(&curve.percent[0]), pack4(&curve.percent[4]), &result);
	auto num = OSDynamicCast(OSNumber, result);
	if (num)
		value = num->unsigned32BitValue();
	OSSafeReleaseNULL(result);
	DBGLOG("rog", "fan %zu curve %u/%u..%u/%u -> %d (%08X)", fan, curve.temp[0], curve.percent[0],
		curve.temp[7], curve.percent[7], ok, value);
	(void)value;
	if (ok)
		appliedCurve[fan] = curve;
	return ok;
}

bool RogControl::writePerfMode(uint8_t mode) {
	if (!havePolicy || mode >= Rog::PerfModeCount)
		return false;
	uint32_t value = 0;
	if (!wmnbInt(Rog::MethodDevs, Rog::DevThermalPolicy, mode, value))
		return false;
	SYSLOG("rog", "performance mode -> %s", PerfModeNames[mode]);
	perfMode = mode;
	perfModeKnown = true;
	// The firmware drops custom curves and power limits on a policy change; put ours back.
	forceReapply = true;
	tunablesDirty = true;
	return true;
}

bool RogControl::writeChargeLimit(uint8_t limit) {
	if (!haveChargeLimit || limit < 20 || limit > 100)
		return false;
	uint32_t value = 0;
	if (!wmnbInt(Rog::MethodDevs, Rog::DevChargeLimit, limit, value))
		return false;
	SYSLOG("rog", "battery charge limit -> %u%%", limit);
	chargeLimit = limit;
	return true;
}

IOHIDDevice *RogControl::findKeyboard() {
	if (kbd && !kbd->isInactive())
		return kbd;
	OSSafeReleaseNULL(kbd);
	kbdReady = false;

	// The N-KEY keyboard is served by a DriverKit HID driver that starts after launchd,
	// so it shows up some seconds after this kext.
	auto match = IOService::serviceMatching("IOHIDDevice");
	auto props = OSDictionary::withCapacity(1);
	auto vendor = OSNumber::withNumber(Rog::AsusVendorID, 32);
	if (match && props && vendor) {
		props->setObject("VendorID", vendor);
		match->setObject(gIOPropertyMatchKey, props);
		if (auto it = IOService::getMatchingServices(match)) {
			while (auto obj = it->getNextObject()) {
				auto dev = OSDynamicCast(IOHIDDevice, obj);
				auto product = dev ? OSDynamicCast(OSString, dev->getProperty("Product")) : nullptr;
				auto feature = dev ? OSDynamicCast(OSNumber, dev->getProperty("MaxFeatureReportSize")) : nullptr;
				if (product && product->isEqualTo("N-KEY Device") && feature && feature->unsigned32BitValue() >= 16) {
					dev->retain();
					kbd = dev;
					break;
				}
			}
			it->release();
		}
	}
	OSSafeReleaseNULL(vendor);
	OSSafeReleaseNULL(props);
	OSSafeReleaseNULL(match);
	if (kbd)
		DBGLOG("rog", "N-KEY keyboard found");
	return kbd;
}

bool RogControl::sendKbdReport(const uint8_t *bytes, size_t len) {
	auto dev = findKeyboard();
	if (!dev)
		return false;
	auto feature = OSDynamicCast(OSNumber, dev->getProperty("MaxFeatureReportSize"));
	size_t size = feature ? feature->unsigned32BitValue() : 64;
	if (len > size)
		return false;
	// The buffer starts with the report ID, like Linux hid_hw_raw_request().
	auto md = IOBufferMemoryDescriptor::withCapacity(size, kIODirectionOut);
	if (!md)
		return false;
	memset(md->getBytesNoCopy(), 0, size);
	lilu_os_memcpy(md->getBytesNoCopy(), bytes, len);
	md->setLength(size);
	IOReturn ret = dev->setReport(md, kIOHIDReportTypeFeature, bytes[0]);
	md->release();
	if (ret != kIOReturnSuccess)
		SYSLOG("rog", "keyboard report %02X %02X failed %08X", bytes[0], len > 1 ? bytes[1] : 0, ret);
	return ret == kIOReturnSuccess;
}

bool RogControl::writeKbdLevel(uint8_t level) {
	if (level > Rog::KbdMaxLevel)
		return false;
	if (!kbdReady) {
		// hid-asus asus_kbd_init(): the keyboard wants this before taking commands.
		static const uint8_t init[] = {Rog::KbdReportID, 'A', 'S', 'U', 'S', ' ', 'T', 'e', 'c', 'h', '.', 'I', 'n', 'c', '.', 0};
		if (!sendKbdReport(init, sizeof(init)))
			return false;
		kbdReady = true;
	}
	// hid-asus asus_kbd_backlight_work()
	const uint8_t cmd[] = {Rog::KbdReportID, 0xBA, 0xC5, 0xC4, level};
	if (!sendKbdReport(cmd, sizeof(cmd)))
		return false;
	kbdLevel = level;
	kbdPending = false;
	return true;
}

void RogControl::writeTunables() {
	for (size_t i = 0; i < Rog::TunableCount; i++) {
		if (!haveTunable[i] || !tunable[i])
			continue;
		uint32_t value = 0;
		bool ok = wmnbInt(Rog::MethodDevs, Rog::Tunables[i].device, tunable[i], value);
		DBGLOG("rog", "%s -> %u: %d (%08X)", Rog::Tunables[i].name, tunable[i], ok, value);
		(void)ok;
	}
}

void RogControl::applyCpuLimit() {
	if (!cppcAllowed || !cppcSupported)
		return;
	CppcJob job {};
	job.maxMHz = cpuMaxMHz;
	job.nominalMHz = nominalMHz;
	job.epp = cpuEpp;
	atomic_init(&job.ok, 0);
	atomic_init(&job.failed, 0);
	atomic_init(&job.recorded, false);
	mp_rendezvous_no_intrs(cppcApplyOnCpu, &job);
	cppcCores = atomic_load(&job.ok);
	cppcFailedCores = atomic_load(&job.failed);
	cppcActive = cppcCores > 0;
	if (cppcActive) {
		cppcHighest = job.highest;
		cppcNominal = job.nominal;
		cppcLowestNonlinear = job.lowestNonlinear;
		cppcLowest = job.lowest;
		cppcMaxPerf = job.maxPerf;
	}
	SYSLOG("rog", "CPU cap %u MHz (nominal %u MHz) EPP %u: max_perf %u (highest %u nominal %u lowest %u) on %u cores, %u failed",
		cpuMaxMHz, nominalMHz, cpuEpp, cppcMaxPerf, cppcHighest, cppcNominal, cppcLowest, cppcCores, cppcFailedCores);
}

void RogControl::refreshSensors() {
	uint32_t rpm[Rog::MaxFans] {};
	int32_t temp[Rog::MaxTemps] {};
	bool ok = false;

	if (haveSensorMethod) {
		// \_SB.ATKD.RGSN from SSDT-ROG: {cpu fan rpm, gpu fan rpm, fan3 rpm, cpu temp, gpu temp}
		OSObject *result = nullptr;
		if (atkd->evaluateObject("RGSN", &result) == kIOReturnSuccess) {
			auto arr = OSDynamicCast(OSArray, result);
			if (arr && arr->getCount() >= 5) {
				auto get = [arr](unsigned i) -> uint32_t {
					auto n = OSDynamicCast(OSNumber, arr->getObject(i));
					return n ? n->unsigned32BitValue() : 0;
				};
				rpm[0] = get(0);
				rpm[1] = get(1);
				temp[0] = static_cast<int32_t>(get(3));
				temp[1] = static_cast<int32_t>(get(4));
				ok = true;
			}
		}
		OSSafeReleaseNULL(result);
	}

	if (!ok) {
		// Generic ASUS path: RPM in units of 100, CPU temperature only.
		uint32_t v = 0;
		if (wmnbInt(Rog::MethodDsts, Rog::DevCpuFanSpeed, 0, v) && v != Rog::DstsUnsupported)
			rpm[0] = (v & 0xFFFF) * 100;
		if (wmnbInt(Rog::MethodDsts, Rog::DevGpuFanSpeed, 0, v) && v != Rog::DstsUnsupported)
			rpm[1] = (v & 0xFFFF) * 100;
		if (wmnbInt(Rog::MethodDsts, Rog::DevCpuTemp, 0, v) && v != Rog::DstsUnsupported)
			temp[0] = static_cast<int32_t>(v & 0xFF);
	}

	for (size_t i = 0; i < Rog::MaxFans; i++)
		if (rpm[i] < 20000)
			atomic_store_explicit(&shared.rpm[i], rpm[i], memory_order_relaxed);
	for (size_t i = 0; i < Rog::MaxTemps; i++)
		if (temp[i] >= 0 && temp[i] < 128)
			atomic_store_explicit(&shared.temp[i], temp[i], memory_order_relaxed);
}

void RogControl::applyFanControl(bool force) {
	if (!haveFanCurves)
		return;

	uint32_t mask = atomic_load_explicit(&shared.manualMask, memory_order_relaxed);
	RogFanCurve desired[Rog::MaxFans] {};
	bool want[Rog::MaxFans] {};
	bool anyCustom = false;

	for (size_t i = 0; i < Rog::MaxFans; i++) {
		if (mask & (1U << i)) {
			uint32_t target = atomic_load_explicit(&shared.target[i], memory_order_relaxed);
			uint32_t maxRpm = atomic_load_explicit(&shared.maxRpm[i], memory_order_relaxed);
			uint32_t pct = maxRpm ? (target * 100 + maxRpm / 2) / maxRpm : 100;
			flatCurve(desired[i], static_cast<uint8_t>(pct > 100 ? 100 : pct));
			want[i] = true;
		} else if (userCurveValid[i]) {
			desired[i] = userCurve[i];
			want[i] = true;
		}
		anyCustom |= want[i];
	}

	if (!anyCustom) {
		if (customApplied) {
			// Back to firmware control: re-selecting the thermal policy restores its stock curves.
			if (!writePerfMode(perfMode)) {
				auto cm = perfMode;
				for (size_t i = 0; i < Rog::MaxFans; i++)
					if (factoryCurveValid[cm][i])
						writeCurve(i, factoryCurve[cm][i]);
			}
			forceReapply = false;
			customApplied = false;
		}
		return;
	}

	// Writing any curve switches the EC into custom mode for both fans, so fans that
	// are not overridden get the stock curve of the current performance mode.
	for (size_t i = 0; i < Rog::MaxFans; i++) {
		const RogFanCurve *curve = want[i] ? &desired[i] : (factoryCurveValid[perfMode][i] ? &factoryCurve[perfMode][i] : nullptr);
		if (!curve)
			continue;
		if (force || !customApplied || memcmp(curve, &appliedCurve[i], sizeof(RogFanCurve)) != 0)
			writeCurve(i, *curve);
	}
	customApplied = true;
}

void RogControl::loadNvramSettings() {
	nvramLoaded = true;

	int32_t mode = -1, charge = -1;
	IORegistryEntry *options = IORegistryEntry::fromPath("/options", gIODTPlane);
	if (options) {
		auto m = OSDynamicCast(OSData, options->getProperty("rog-perf-mode"));
		if (m && m->getLength() == 1)
			mode = *static_cast<const uint8_t *>(m->getBytesNoCopy());
		auto c = OSDynamicCast(OSData, options->getProperty("rog-charge-limit"));
		if (c && c->getLength() == 1)
			charge = *static_cast<const uint8_t *>(c->getBytesNoCopy());
		options->release();
	}

	// Boot arguments take priority over the stored settings.
	int32_t arg = 0;
	if (PE_parse_boot_argn("rogmode", &arg, sizeof(arg)))
		mode = arg;
	if (PE_parse_boot_argn("rogcharge", &arg, sizeof(arg)))
		charge = arg;

	// Like Linux asus-wmi, start from a known policy (Balanced unless one was saved).
	if (mode < 0 || mode >= Rog::PerfModeCount)
		mode = Rog::PerfBalanced;
	writePerfMode(static_cast<uint8_t>(mode));
	if (charge >= 20 && charge <= 100)
		writeChargeLimit(static_cast<uint8_t>(charge));

	// Keyboard backlight level (Fn+F2/F3, rogctl kbd); written once the keyboard is up.
	options = IORegistryEntry::fromPath("/options", gIODTPlane);
	if (options) {
		auto k = OSDynamicCast(OSData, options->getProperty("rog-kbd-light"));
		if (k && k->getLength() == 1 && *static_cast<const uint8_t *>(k->getBytesNoCopy()) <= Rog::KbdMaxLevel) {
			kbdLevel = *static_cast<const uint8_t *>(k->getBytesNoCopy());
			kbdPending = true;
		}
		options->release();
	}

	// The CPU stays stock (legacy P-states) until something asks for a cap or an energy
	// preference: rogd from its config, or boot-args rogcpumax=MHz (0 = none) / rogepp=0..255.
	bool cpuConfigured = false;
	if (PE_parse_boot_argn("rogcpumax", &arg, sizeof(arg)) && arg >= 0) {
		cpuMaxMHz = static_cast<uint32_t>(arg);
		cpuConfigured = true;
	}
	if (PE_parse_boot_argn("rogepp", &arg, sizeof(arg)) && arg >= 0 && arg <= 255) {
		cpuEpp = static_cast<uint8_t>(arg);
		cpuConfigured = true;
	}
	if (cpuConfigured)
		applyCpuLimit();
}

void RogControl::storeNvramByte(const char *name, uint8_t value) {
	storeNvramData(name, &value, sizeof(value));
}

void RogControl::storeNvramData(const char *name, const void *bytes, size_t len) {
	auto options = IORegistryEntry::fromPath("/options", gIODTPlane);
	if (!options)
		return;
	auto key = OSSymbol::withCString(name);
	auto data = OSData::withBytes(bytes, static_cast<unsigned int>(len));
	if (key && data && !options->setProperty(key, data))
		SYSLOG("rog", "failed to store %s in NVRAM", name);
	OSSafeReleaseNULL(key);
	OSSafeReleaseNULL(data);
	options->release();
}

void RogControl::publishStatus() {
	setProperty("CPU Fan RPM", atomic_load_explicit(&shared.rpm[0], memory_order_relaxed), 32);
	setProperty("GPU Fan RPM", atomic_load_explicit(&shared.rpm[1], memory_order_relaxed), 32);
	setProperty("CPU Temperature", atomic_load_explicit(&shared.temp[0], memory_order_relaxed), 32);
	setProperty("GPU Temperature", atomic_load_explicit(&shared.temp[1], memory_order_relaxed), 32);
	setProperty("PerformanceMode", perfModeKnown ? PerfModeNames[perfMode] : "unknown");
	if (haveChargeLimit)
		setProperty("ChargeLimit", chargeLimit, 32);

	uint32_t mask = atomic_load_explicit(&shared.manualMask, memory_order_relaxed);
	const char *control = "auto";
	if (mask)
		control = "manual";
	else if (userCurveValid[0] || userCurveValid[1])
		control = "curve";
	setProperty("FanControl", control);
	setProperty("KeyboardBrightness", kbdLevel, 32);
	setProperty("KeyboardFound", kbd != nullptr && !kbd->isInactive());
	setProperty("LastHotkey", lastHotkey, 32);
	setProperty("HotkeyCount", hotkeyCount, 32);
	setProperty("CPUMaxFrequencyMHz", cpuMaxMHz, 32);
	setProperty("CPUEnergyPreference", cpuEpp, 32);
	setProperty("CPUFrequencyLimitActive", cppcActive);
	if (auto cppc = OSDictionary::withCapacity(8)) {
		auto put = [cppc](const char *key, uint32_t value) {
			if (auto n = OSNumber::withNumber(value, 32)) {
				cppc->setObject(key, n);
				n->release();
			}
		};
		cppc->setObject("Supported", cppcSupported ? kOSBooleanTrue : kOSBooleanFalse);
		put("NominalMHz", nominalMHz);
		put("Cores", cppcCores);
		put("FailedCores", cppcFailedCores);
		put("HighestPerf", cppcHighest);
		put("NominalPerf", cppcNominal);
		put("LowestNonlinearPerf", cppcLowestNonlinear);
		put("LowestPerf", cppcLowest);
		put("MaxPerf", cppcMaxPerf);
		setProperty("CPPC", cppc);
		cppc->release();
	}
	if (auto tun = OSDictionary::withCapacity(Rog::TunableCount)) {
		for (size_t i = 0; i < Rog::TunableCount; i++) {
			if (!haveTunable[i])
				continue;
			if (auto n = OSNumber::withNumber(tunable[i], 32)) {
				tun->setObject(Rog::Tunables[i].name, n);
				n->release();
			}
		}
		setProperty("Tunables", tun);
		tun->release();
	}

	if (customApplied) {
		setProperty("AppliedCurveCPU", &appliedCurve[0], sizeof(RogFanCurve));
		setProperty("AppliedCurveGPU", &appliedCurve[1], sizeof(RogFanCurve));
	} else {
		removeProperty("AppliedCurveCPU");
		removeProperty("AppliedCurveGPU");
	}
}

void RogControl::cyclePerfMode() {
	// Same order as Linux asus-wmi: balanced -> turbo -> silent -> balanced
	uint8_t next = static_cast<uint8_t>((perfMode + 1) % Rog::PerfModeCount);
	if (writePerfMode(next)) {
		storeNvramByte("rog-perf-mode", next);
		applyFanControl(true);
		forceReapply = false;
		publishStatus();
	}
}

void RogControl::handleAtkEvent(uint32_t code) {
	DBGLOG("rog", "ATK event %02X", code);
	lastHotkey = code;
	hotkeyCount++;
	if (code == Rog::EventThermalPolicy || code == Rog::EventFanBoost) {
		cyclePerfMode();
	} else if (code == Rog::EventKbdLightUp || code == Rog::EventKbdLightDown) {
		uint8_t level = kbdLevel;
		if (code == Rog::EventKbdLightUp && level < Rog::KbdMaxLevel)
			level++;
		else if (code == Rog::EventKbdLightDown && level > 0)
			level--;
		if (writeKbdLevel(level))
			storeNvramByte("rog-kbd-light", level);
	}
	messageClients(Rog::MessageHotkey, reinterpret_cast<void *>(static_cast<uintptr_t>(code)));
	publishStatus();
}

IOReturn RogControl::setPropertiesGated(OSDictionary *dict) {
	bool controlChanged = false;
	IOReturn ret = kIOReturnSuccess;

	if (auto obj = dict->getObject("PerformanceMode")) {
		int32_t mode = -1;
		if (auto num = OSDynamicCast(OSNumber, obj)) {
			mode = static_cast<int32_t>(num->unsigned32BitValue());
		} else if (auto str = OSDynamicCast(OSString, obj)) {
			for (int32_t i = 0; i < Rog::PerfModeCount; i++)
				if (str->isEqualTo(PerfModeNames[i]))
					mode = i;
		}
		if (mode < 0 || mode >= Rog::PerfModeCount || !writePerfMode(static_cast<uint8_t>(mode)))
			ret = kIOReturnBadArgument;
		else {
			storeNvramByte("rog-perf-mode", static_cast<uint8_t>(mode));
			controlChanged = true;
		}
	}

	if (auto num = OSDynamicCast(OSNumber, dict->getObject("ChargeLimit"))) {
		auto limit = num->unsigned32BitValue();
		if (limit > 100 || !writeChargeLimit(static_cast<uint8_t>(limit)))
			ret = kIOReturnBadArgument;
		else
			storeNvramByte("rog-charge-limit", static_cast<uint8_t>(limit));
	}

	static const char *const curveKeys[Rog::MaxFans] = {"FanCurveCPU", "FanCurveGPU"};
	for (size_t i = 0; i < Rog::MaxFans; i++) {
		auto obj = dict->getObject(curveKeys[i]);
		if (!obj)
			continue;
		auto data = OSDynamicCast(OSData, obj);
		if (data && data->getLength() == sizeof(RogFanCurve)) {
			RogFanCurve curve;
			lilu_os_memcpy(&curve, data->getBytesNoCopy(), sizeof(curve));
			if (validCurve(curve)) {
				userCurve[i] = curve;
				userCurveValid[i] = true;
				controlChanged = true;
			} else {
				ret = kIOReturnBadArgument;
			}
		} else {
			// Anything else (false, empty data) clears the curve.
			userCurveValid[i] = false;
			controlChanged = true;
		}
	}

	if (auto num = OSDynamicCast(OSNumber, dict->getObject("KeyboardBrightness"))) {
		auto level = num->unsigned32BitValue();
		if (level > Rog::KbdMaxLevel || !writeKbdLevel(static_cast<uint8_t>(level)))
			ret = kIOReturnBadArgument;
		else
			storeNvramByte("rog-kbd-light", static_cast<uint8_t>(level));
	}

	if (auto num = OSDynamicCast(OSNumber, dict->getObject("CPUMaxFrequencyMHz"))) {
		auto mhz = num->unsigned32BitValue();
		if (!cppcSupported || !cppcAllowed || (mhz != 0 && (mhz < 400 || mhz > 6500))) {
			ret = kIOReturnBadArgument;
		} else {
			cpuMaxMHz = mhz;
			applyCpuLimit();
		}
	}

	if (auto obj = dict->getObject("CPUEnergyPreference")) {
		uint8_t epp = 0;
		if (!cppcSupported || !cppcAllowed || !eppFromObject(obj, epp)) {
			ret = kIOReturnBadArgument;
		} else {
			cpuEpp = epp;
			applyCpuLimit();
		}
	}

	// Power limits and NVIDIA settings: watts / degrees; 0 restores the firmware value
	// (re-selecting the performance mode resets them, then the others are written again).
	bool resetTunables = false, tunablesChanged = false;
	for (size_t i = 0; i < Rog::TunableCount; i++) {
		auto num = OSDynamicCast(OSNumber, dict->getObject(Rog::Tunables[i].name));
		if (!num)
			continue;
		tunablesChanged = true;
		auto v = num->unsigned32BitValue();
		if (!haveTunable[i] || (v != 0 && (v < Rog::Tunables[i].min || v > Rog::Tunables[i].max))) {
			ret = kIOReturnBadArgument;
			continue;
		}
		if (v == 0 && tunable[i])
			resetTunables = true;
		tunable[i] = static_cast<uint8_t>(v);
	}
	if (resetTunables && perfModeKnown)
		writePerfMode(perfMode);
	if (tunablesChanged)
		writeTunables();

	if (dict->getObject("FanCurvesReset")) {
		userCurveValid[0] = userCurveValid[1] = false;
		controlChanged = true;
	}

	// FanSpeedPercent: 0-100 forces both fans, anything negative returns them to auto.
	if (auto num = OSDynamicCast(OSNumber, dict->getObject("FanSpeedPercent"))) {
		auto pct = static_cast<int32_t>(num->unsigned32BitValue());
		if (pct >= 0 && pct <= 100) {
			for (size_t i = 0; i < Rog::MaxFans; i++) {
				auto maxRpm = atomic_load_explicit(&shared.maxRpm[i], memory_order_relaxed);
				atomic_store_explicit(&shared.target[i], maxRpm * pct / 100, memory_order_relaxed);
			}
			atomic_store_explicit(&shared.manualMask, (1U << Rog::MaxFans) - 1, memory_order_relaxed);
		} else {
			atomic_store_explicit(&shared.manualMask, 0, memory_order_relaxed);
		}
		controlChanged = true;
	}

	if (controlChanged) {
		atomic_store_explicit(&shared.controlDirty, false, memory_order_relaxed);
		applyFanControl(forceReapply);
		forceReapply = false;
	}
	publishStatus();
	return ret;
}

IOService *RogControl::probe(IOService *provider, SInt32 *score) {
	if (checkKernelArgument("-rogcontroloff") || !IOService::probe(provider, score))
		return nullptr;

	atkd = OSDynamicCast(IOACPIPlatformDevice, provider);
	if (!atkd)
		return nullptr;

	// Several PNP0C14 (WMI) devices exist; ASUS's is the one with _UID "ATK".
	OSObject *uid = nullptr;
	bool isAtk = false;
	if (atkd->evaluateObject("_UID", &uid) == kIOReturnSuccess) {
		auto str = OSDynamicCast(OSString, uid);
		isAtk = str && str->isEqualTo("ATK");
	}
	OSSafeReleaseNULL(uid);
	if (!isAtk || atkd->validateObject("WMNB") != kIOReturnSuccess) {
		atkd = nullptr;
		return nullptr;
	}

	safetyFloor = !checkKernelArgument("-rogcontrolnosafety");
	haveSensorMethod = atkd->validateObject("RGSN") == kIOReturnSuccess;

	uint32_t v = 0;
	havePolicy = wmnbInt(Rog::MethodDsts, Rog::DevThermalPolicy, 0, v) && v != Rog::DstsUnsupported && (v & Rog::DstsPresent);
	haveChargeLimit = wmnbInt(Rog::MethodDsts, Rog::DevChargeLimit, 0, v) && v != Rog::DstsUnsupported && (v & Rog::DstsPresent);
	for (size_t i = 0; i < Rog::TunableCount; i++)
		haveTunable[i] = wmnbInt(Rog::MethodDsts, Rog::Tunables[i].device, 0, v) && v != Rog::DstsUnsupported && (v & Rog::DstsPresent);

	// CPPC: CPUID 0x80000008 EBX bit 27. Nominal clock from P-state 0 (CpuFid / CpuDfsId * 200 MHz).
	cppcAllowed = !checkKernelArgument("-rogcontrolnocppc");
	uint32_t eax = 0x80000008, ebx = 0, ecx = 0, edx = 0;
	asm volatile("cpuid" : "+a"(eax), "=b"(ebx), "+c"(ecx), "=d"(edx));
	cppcSupported = (ebx >> 27) & 1;
	uint64_t p0 = 0;
	if (rogRdmsr(Rog::MsrPState0, p0) && (p0 >> 63)) {
		uint32_t fid = p0 & 0xFF, dfs = (p0 >> 8) & 0x3F;
		if (dfs)
			nominalMHz = fid * 200 / dfs;
	}
	if (!nominalMHz)
		cppcSupported = false;
	for (uint8_t mode = 0; mode < Rog::PerfModeCount; mode++)
		for (size_t fan = 0; fan < Rog::MaxFans; fan++)
			factoryCurveValid[mode][fan] = readFactoryCurve(mode, fan, factoryCurve[mode][fan]);
	haveFanCurves = factoryCurveValid[0][0] && factoryCurveValid[0][1];

	SYSLOG("rog", "tunables PL1 %d PL2 %d FPPT %d NV boost %d NV temp %d, CPPC %d (nominal %u MHz)",
		haveTunable[Rog::TunePl1], haveTunable[Rog::TunePl2], haveTunable[Rog::TuneFppt],
		haveTunable[Rog::TuneNvBoost], haveTunable[Rog::TuneNvTemp], cppcSupported, nominalMHz);
	SYSLOG("rog", "ATKD found: sensors %s, policy %d, fan curves %d, charge limit %d",
		haveSensorMethod ? "RGSN" : "WMI", havePolicy, haveFanCurves, haveChargeLimit);

	// Fan RPM limits, measured on the G713PV; overridable from Info.plist.
	static constexpr uint32_t defaultMax[Rog::MaxFans] = {6600, 6300};
	static constexpr uint32_t defaultMin[Rog::MaxFans] = {2000, 2000};
	auto maxArr = OSDynamicCast(OSArray, getProperty("FanMaxRPM"));
	auto minArr = OSDynamicCast(OSArray, getProperty("FanMinRPM"));
	for (size_t i = 0; i < Rog::MaxFans; i++) {
		auto mx = maxArr ? OSDynamicCast(OSNumber, maxArr->getObject(static_cast<unsigned>(i))) : nullptr;
		auto mn = minArr ? OSDynamicCast(OSNumber, minArr->getObject(static_cast<unsigned>(i))) : nullptr;
		atomic_init(&shared.maxRpm[i], mx ? mx->unsigned32BitValue() : defaultMax[i]);
		atomic_init(&shared.minRpm[i], mn ? mn->unsigned32BitValue() : defaultMin[i]);
		atomic_init(&shared.rpm[i], 0);
		atomic_init(&shared.target[i], 0);
	}
	for (size_t i = 0; i < Rog::MaxTemps; i++)
		atomic_init(&shared.temp[i], 0);

	atomic_init(&shared.manualMask, 0);
	atomic_init(&shared.controlDirty, false);
	refreshSensors();

	static const char *const fanNames[Rog::MaxFans] = {"CPU Fan", "GPU Fan"};
	uint32_t rw = SMC_KEY_ATTRIBUTE_WRITE | SMC_KEY_ATTRIBUTE_READ;
	uint32_t ro = SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ;
	uint32_t fanRw = haveFanCurves ? rw : SMC_KEY_ATTRIBUTE_READ;

	VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(Rog::MaxFans, nullptr, ro));
	VirtualSMCAPI::addKey(KeyFS__, vsmcPlugin.data, VirtualSMCAPI::valueWithUint16(0, new FanForce(&shared), fanRw));
	for (size_t i = 0; i < Rog::MaxFans; i++) {
		VirtualSMCAPI::addKey(KeyF0Ac(i), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new FanActual(&shared, i), SMC_KEY_ATTRIBUTE_READ));
		VirtualSMCAPI::addKey(KeyF0Mn(i), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new FanMin(&shared, i), rw));
		VirtualSMCAPI::addKey(KeyF0Mx(i), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new FanMax(&shared, i), rw));
		VirtualSMCAPI::addKey(KeyF0Md(i), vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(0, new FanMode(&shared, i), fanRw));
		VirtualSMCAPI::addKey(KeyF0Tg(i), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new FanTarget(&shared, i), fanRw));

		// FanTypeDescStruct: type, zone, location, reserved, 12-byte name
		uint8_t desc[16] {};
		desc[0] = 1;            // FAN_PWM_TACH
		desc[1] = 1;            // zone
		desc[2] = i == 0 ? 13 : 15; // centre/right mid rear
		for (size_t c = 0; c < 12 && fanNames[i][c]; c++)
			desc[4 + c] = static_cast<uint8_t>(fanNames[i][c]);
		VirtualSMCAPI::addKey(KeyF0ID(i), vsmcPlugin.data, VirtualSMCAPI::valueWithData(desc, sizeof(desc), SmcKeyTypeFds, nullptr, ro));
	}

	VirtualSMCAPI::addKey(KeyTC0H, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new TempSp78(&shared, 0)));
	if (haveSensorMethod) {
		VirtualSMCAPI::addKey(KeyTG0P, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new TempSp78(&shared, 1)));
		VirtualSMCAPI::addKey(KeyTG0D, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new TempSp78(&shared, 1)));
		VirtualSMCAPI::addKey(KeyTGDD, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new TempSp78(&shared, 1)));
	}

	qsort(const_cast<VirtualSMCKeyValue *>(vsmcPlugin.data.data()), vsmcPlugin.data.size(), sizeof(VirtualSMCKeyValue), VirtualSMCKeyValue::compare);
	return this;
}

bool RogControl::start(IOService *provider) {
	if (!IOService::start(provider)) {
		SYSLOG("rog", "failed to start the parent");
		return false;
	}

	setProperty("VersionInfo", kextVersion);

	workLoop = IOWorkLoop::workLoop();
	commandGate = IOCommandGate::commandGate(this);
	poller = IOTimerEventSource::timerEventSource(this, [](OSObject *owner, IOTimerEventSource *sender) {
		auto self = OSDynamicCast(RogControl, owner);
		if (!self)
			return;
		if (!self->nvramLoaded && self->pollCount >= 2)
			self->loadNvramSettings();
		self->refreshSensors();
		bool dirty = atomic_exchange_explicit(&self->shared.controlDirty, false, memory_order_acquire);
		if (dirty || self->forceReapply) {
			bool force = self->forceReapply;
			self->forceReapply = false;
			self->applyFanControl(force);
		}
		if (self->tunablesDirty) {
			self->tunablesDirty = false;
			self->writeTunables();
		}
		if (self->cpuDirty) {
			self->cpuDirty = false;
			self->applyCpuLimit();
		}
		if (self->kbdPending) {
			if (self->writeKbdLevel(self->kbdLevel) || ++self->kbdWaited > Rog::KbdRetrySeconds)
				self->kbdPending = false;
		}
		if ((self->pollCount++ % 2) == 0)
			self->publishStatus();
		sender->setTimeoutMS(Rog::PollIntervalMS);
	});

	if (!workLoop || !commandGate || !poller ||
		workLoop->addEventSource(commandGate) != kIOReturnSuccess ||
		workLoop->addEventSource(poller) != kIOReturnSuccess) {
		SYSLOG("rog", "failed to set up the work loop");
		return false;
	}

	// Lets the firmware raise ATKD notifications (Fn+F5 etc.), like asus-wmi does.
	uint32_t v = 0;
	wmnbInt(Rog::MethodInit, 0, 0, v);

	sleepNotifier = registerSleepWakeInterest(sleepHandler, this);

	vsmcNotifier = VirtualSMCAPI::registerHandler(vsmcNotificationHandler, this);
	if (!vsmcNotifier) {
		SYSLOG("rog", "failed to register the VirtualSMC handler");
		return false;
	}

	poller->setTimeoutMS(Rog::PollIntervalMS);
	registerService();
	return true;
}

bool RogControl::vsmcNotificationHandler(void *sensors, void *refCon, IOService *vsmc, IONotifier *notifier) {
	if (!sensors || !vsmc)
		return false;
	auto self = static_cast<RogControl *>(sensors);
	auto ret = vsmc->callPlatformFunction(VirtualSMCAPI::SubmitPlugin, true, sensors, &self->vsmcPlugin, nullptr, nullptr);
	if (ret == kIOReturnSuccess) {
		DBGLOG("rog", "submitted plugin");
		return true;
	}
	if (ret != kIOReturnUnsupported)
		SYSLOG("rog", "plugin submission failure %X", ret);
	return false;
}

IOReturn RogControl::sleepHandler(void *target, void *refCon, UInt32 messageType, IOService *provider, void *messageArgument, vm_size_t argSize) {
	auto self = static_cast<RogControl *>(target);
	if (messageType == kIOMessageSystemHasPoweredOn && self && self->commandGate) {
		// The EC forgets custom curves and the policy over sleep; restore both.
		self->commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
			auto s = static_cast<RogControl *>(owner);
			if (s->perfModeKnown)
				s->writePerfMode(s->perfMode);
			if (s->chargeLimit)
				s->writeChargeLimit(s->chargeLimit);
			s->forceReapply = true;
			s->tunablesDirty = true;
			s->cpuDirty = s->cppcActive;
			s->kbdReady = false;
			s->kbdPending = true;
			s->kbdWaited = 0;
			return kIOReturnSuccess;
		});
	}
	if (messageType == kIOMessageSystemWillSleep || messageType == kIOMessageSystemHasPoweredOn ||
		messageType == kIOMessageSystemWillPowerOff || messageType == kIOMessageSystemWillRestart ||
		messageType == kIOMessageSystemWillNotSleep) {
		auto note = static_cast<sleepWakeNote *>(messageArgument);
		if (note) {
			note->returnValue = 0;
			acknowledgeSleepWakeNotification(note->powerRef);
		}
		return kIOReturnSuccess;
	}
	return kIOReturnUnsupported;
}

IOReturn RogControl::message(UInt32 type, IOService *provider, void *argument) {
	if (type == kIOACPIMessageDeviceNotification && argument && commandGate) {
		uint32_t notifyCode = *static_cast<uint32_t *>(argument);
		if (notifyCode == 0xFF) {
			commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
				auto self = static_cast<RogControl *>(owner);
				OSObject *param = OSNumber::withNumber(0xFFULL, 32);
				OSObject *result = nullptr;
				if (self->atkd->evaluateObject("_WED", &result, &param, 1) == kIOReturnSuccess) {
					auto num = OSDynamicCast(OSNumber, result);
					if (num)
						self->handleAtkEvent(num->unsigned32BitValue());
				}
				OSSafeReleaseNULL(param);
				OSSafeReleaseNULL(result);
				return kIOReturnSuccess;
			});
		}
		return kIOReturnSuccess;
	}
	return IOService::message(type, provider, argument);
}

IOReturn RogControl::setProperties(OSObject *properties) {
	auto dict = OSDynamicCast(OSDictionary, properties);
	if (!dict || !commandGate)
		return kIOReturnBadArgument;
	if (IOUserClient::clientHasPrivilege(current_task(), kIOClientPrivilegeAdministrator) != kIOReturnSuccess)
		return kIOReturnNotPrivileged;
	return commandGate->runAction([](OSObject *owner, void *arg, void *, void *, void *) -> IOReturn {
		return static_cast<RogControl *>(owner)->setPropertiesGated(static_cast<OSDictionary *>(arg));
	}, dict);
}

void RogControl::stop(IOService *provider) {
	PANIC("rog", "called stop!!!");
}

EXPORT extern "C" kern_return_t ADDPR(kern_start)(kmod_info_t *, void *) {
	lilu_get_boot_args("liludelay", &ADDPR(debugPrintDelay), sizeof(ADDPR(debugPrintDelay)));
	ADDPR(debugEnabled) = checkKernelArgument("-vsmcdbg") || checkKernelArgument("-rogcontroldbg") || checkKernelArgument("-liludbgall");
	return KERN_SUCCESS;
}

EXPORT extern "C" kern_return_t ADDPR(kern_stop)(kmod_info_t *, void *) {
	// VirtualSMC plugins cannot be unloaded.
	return KERN_FAILURE;
}
