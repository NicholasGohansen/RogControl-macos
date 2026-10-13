//
//  KeyImplementations.cpp
//  RogControl
//

#include "KeyImplementations.hpp"

static inline uint16_t readFpe2(const SMC_DATA *src) {
	return VirtualSMCAPI::decodeIntFp(SmcKeyTypeFpe2, *reinterpret_cast<const uint16_t *>(src));
}

static inline void writeFpe2(SMC_DATA *dst, uint32_t value) {
	if (value > 0x3FFF)
		value = 0x3FFF;
	*reinterpret_cast<uint16_t *>(dst) = VirtualSMCAPI::encodeIntFp(SmcKeyTypeFpe2, static_cast<uint16_t>(value));
}

SMC_RESULT FanActual::readAccess() {
	writeFpe2(data, atomic_load_explicit(&state->rpm[index], memory_order_relaxed));
	return SmcSuccess;
}

SMC_RESULT FanMin::readAccess() {
	writeFpe2(data, atomic_load_explicit(&state->minRpm[index], memory_order_relaxed));
	return SmcSuccess;
}

SMC_RESULT FanMin::update(const SMC_DATA *src) {
	RogKey::update(src);
	atomic_store_explicit(&state->minRpm[index], readFpe2(src), memory_order_relaxed);
	return SmcSuccess;
}

SMC_RESULT FanMax::readAccess() {
	writeFpe2(data, atomic_load_explicit(&state->maxRpm[index], memory_order_relaxed));
	return SmcSuccess;
}

SMC_RESULT FanMax::update(const SMC_DATA *src) {
	// Max is a physical property of the fan; accept the write but keep our value.
	RogKey::update(src);
	return SmcSuccess;
}

SMC_RESULT FanMode::readAccess() {
	auto mask = atomic_load_explicit(&state->manualMask, memory_order_relaxed);
	*reinterpret_cast<uint8_t *>(data) = (mask >> index) & 1;
	return SmcSuccess;
}

SMC_RESULT FanMode::update(const SMC_DATA *src) {
	RogKey::update(src);
	uint32_t bit = 1U << index;
	if (*src)
		atomic_fetch_or_explicit(&state->manualMask, bit, memory_order_relaxed);
	else
		atomic_fetch_and_explicit(&state->manualMask, ~bit, memory_order_relaxed);
	atomic_store_explicit(&state->controlDirty, true, memory_order_release);
	return SmcSuccess;
}

SMC_RESULT FanTarget::readAccess() {
	writeFpe2(data, atomic_load_explicit(&state->target[index], memory_order_relaxed));
	return SmcSuccess;
}

SMC_RESULT FanTarget::update(const SMC_DATA *src) {
	RogKey::update(src);
	atomic_store_explicit(&state->target[index], readFpe2(src), memory_order_relaxed);
	atomic_store_explicit(&state->controlDirty, true, memory_order_release);
	return SmcSuccess;
}

SMC_RESULT FanForce::readAccess() {
	auto mask = atomic_load_explicit(&state->manualMask, memory_order_relaxed);
	data[0] = (mask >> 8) & 0xFF;
	data[1] = mask & 0xFF;
	return SmcSuccess;
}

SMC_RESULT FanForce::update(const SMC_DATA *src) {
	RogKey::update(src);
	uint32_t mask = (static_cast<uint32_t>(src[0]) << 8) | src[1];
	mask &= (1U << Rog::MaxFans) - 1;
	atomic_store_explicit(&state->manualMask, mask, memory_order_relaxed);
	atomic_store_explicit(&state->controlDirty, true, memory_order_release);
	return SmcSuccess;
}

SMC_RESULT TempSp78::readAccess() {
	auto value = atomic_load_explicit(&state->temp[index], memory_order_relaxed);
	*reinterpret_cast<uint16_t *>(data) = VirtualSMCAPI::encodeIntSp(SmcKeyTypeSp78, static_cast<int16_t>(value));
	return SmcSuccess;
}
