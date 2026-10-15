// AW88399Fixup.hpp
//
// macOS kernel extension bringing up the two Awinic AW88399 smart amplifiers that drive
// the internal speakers of the Lenovo Legion Y9000P 2025 (ALC287 + 2x AW88399).
//
// Milestone M1: probe the chip over I2C (ID check) and optionally apply the minimal
// "power up + DSP bypass + un-mute" write set.  DSP/ACF download, _DSM calibration,
// GPIO reset, fault IRQ and the second I2C address are later milestones - see
// docs/design.md.

#ifndef AW88399_FIXUP_HPP
#define AW88399_FIXUP_HPP

#include <IOKit/IOService.h>
#include <IOKit/IOTimerEventSource.h>
#include <IOKit/IOWorkLoop.h>

class VoodooI2CDeviceNub;

class AW88399Fixup : public IOService {
    OSDeclareDefaultStructors(AW88399Fixup)

public:
    bool start(IOService *provider) override;
    void stop(IOService *provider) override;
    void free() override;

private:
    // ---- I2C register access (AW88399 wire format: 8-bit register, 16-bit data) ----
    bool readReg(UInt8 reg, UInt16 *value);
    bool writeReg(UInt8 reg, UInt16 value);
    /* Mirrors Linux regmap_update_bits(reg, linuxMask, value), where the header's
       AW88399_xxx_MASK constant is the *complement* of the field mask. */
    bool updateField(UInt8 reg, UInt16 linuxMask, UInt16 value);

    // ---- bring-up ----
    void runBringUp();
    void bringUpTimerFired(OSObject *owner, IOTimerEventSource *sender);
    bool probeChip();
    bool applyMinimalBringUp();

    // ---- diagnostics ----
    void publishState();
    void dumpRegister(const char *name, UInt8 reg);
    void logf(const char *fmt, ...) __attribute__((format(printf, 2, 3)));

    VoodooI2CDeviceNub *mNub{nullptr};
    IOTimerEventSource *mTimer{nullptr};

    bool mDebug{false};
    bool mReadOnly{false};
    bool mForceNoDsp{true};
    UInt32 mDelaySec{5};
    bool mWriteRequested{false};
    bool mReadOnlyRequested{false};

    UInt16 mChipId{0};
    UInt16 mSysCtrlBefore{0};
    UInt16 mSysCtrlAfter{0};
    UInt16 mSysCtrl2{0};
    UInt16 mI2sCtrl1{0};
    UInt16 mI2sCtrl2{0};
    UInt16 mI2sCtrl3{0};
    bool mProbeOk{false};
    bool mApplied{false};
    const char *mStage{"init"};
};

#endif /* AW88399_FIXUP_HPP */
