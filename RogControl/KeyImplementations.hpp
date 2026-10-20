//
//  KeyImplementations.hpp
//  RogControl
//
//  SMC key handlers. They run in whatever context VirtualSMC services the
//  request from, so they only read/write the atomics in RogSharedState.
//

#ifndef KeyImplementations_hpp
#define KeyImplementations_hpp

#include <VirtualSMCSDK/kern_vsmcapi.hpp>
#include "RogControl.hpp"

class RogKey : public VirtualSMCValue {
protected:
	RogSharedState *state;
	size_t index;
public:
	RogKey(RogSharedState *state, size_t index = 0) : state(state), index(index) {}
};

class FanActual : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; };
class FanMin    : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; SMC_RESULT update(const SMC_DATA *src) override; };
class FanMax    : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; SMC_RESULT update(const SMC_DATA *src) override; };
class FanMode   : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; SMC_RESULT update(const SMC_DATA *src) override; };
class FanTarget : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; SMC_RESULT update(const SMC_DATA *src) override; };
// 'FS! ': bitmask of fans in forced (manual) mode
class FanForce  : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; SMC_RESULT update(const SMC_DATA *src) override; };
class TempSp78  : public RogKey { using RogKey::RogKey; protected: SMC_RESULT readAccess() override; };

#endif /* KeyImplementations_hpp */
