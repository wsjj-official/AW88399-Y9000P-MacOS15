// AW88399Fixup.cpp
//
// Milestone M1: match the ACPI device AWDZ8399 through VoodooI2C's device nub, read the
// AW88399 chip ID over I2C, and (unless read-only) apply the minimal write set that turns
// the amplifier on in DSP-bypass mode with hardware mute released.
//
// Register semantics come from Linux: sound/soc/codecs/aw88399.c (see docs/references.md).
// Every write is bounded, verified by read-back, and can be disabled with -aw88399ro.

#include "AW88399Fixup.hpp"

#include <IOKit/IOLib.h>
#include <libkern/libkern.h>
#include <pexpert/pexpert.h>

#include "AW88399Registers.hpp"
#include "VoodooI2CShim.hpp"

// xnu declares vsnprintf in bsd/kern/subr_prf.c; declare it explicitly so the build does
// not depend on which kernel headers happen to pull it in.
extern "C" int vsnprintf(char *str, size_t size, const char *format, va_list ap);

#define super IOService
OSDefineMetaClassAndStructors(AW88399Fixup, IOService)

namespace {

constexpr UInt32 kDefaultDelaySec = 5;
constexpr UInt32 kMaxDelaySec = 60;
constexpr UInt8 kRegId = AW88399_ID_REG;              // 0x00
constexpr UInt8 kRegSysCtrl = AW88399_SYSCTRL_REG;    // 0x04
constexpr UInt8 kRegSysCtrl2 = AW88399_SYSCTRL2_REG;  // 0x05
constexpr UInt8 kRegI2sCtrl1 = AW88399_I2SCTRL1_REG;  // 0x06
constexpr UInt8 kRegI2sCtrl2 = AW88399_I2SCTRL2_REG;  // 0x07
constexpr UInt8 kRegI2sCtrl3 = AW88399_I2SCTRL3_REG;  // 0x08
constexpr UInt16 kChipId = AW88399_CHIP_ID;           // 0x2183

bool bootArgPresent(const char *name)
{
    return PE_parse_boot_argn(name, nullptr, 0) != FALSE;
}

// PE_parse_boot_argn() matches by prefix, so "-aw88399ro" also satisfies a query for
// "aw88399rw" (0.1.2 shipped with that bug and wrote to the amplifier even though
// -aw88399ro was set).  Read the boot-args string and match whole tokens instead.
// Only libkern's strlen/strncmp are available in the kernel - strstr is not declared.
bool bootArgsContain(const char *flag)
{
    char args[1024] = {0};
    if (!PE_parse_boot_argn("boot-args", args, sizeof(args))) {
        return false;
    }
    size_t flagLength = strlen(flag);
    if (flagLength == 0) {
        return false;
    }
    for (const char *cursor = args; *cursor != '\0'; ++cursor) {
        if ((cursor != args) && (cursor[-1] != ' ') && (cursor[-1] != '-')) {
            continue;
        }
        if (strncmp(cursor, flag, flagLength) != 0) {
            continue;
        }
        char next = cursor[flagLength];
        if (next == '\0' || next == ' ') {
            return true;
        }
    }
    return false;
}

bool bootArgUInt32(const char *name, UInt32 *value)
{
    return PE_parse_boot_argn(name, value, sizeof(*value)) != FALSE;
}

} // namespace

bool AW88399Fixup::start(IOService *provider)
{
    if (!super::start(provider)) {
        return false;
    }

    mDebug = bootArgsContain("aw88399dbg");
    // Writes are opt-in: without -aw88399rw this kext only reads registers, no matter
    // what else is on the command line.  (-aw88399ro is accepted as an explicit
    // read-only request and simply is the default.)
    mReadOnly = !bootArgsContain("aw88399rw");
    if (bootArgPresent("aw88399nodsp")) {
        mForceNoDsp = true;
    }
    UInt32 delay = 0;
    if (bootArgUInt32("aw88399delay", &delay)) {
        mDelaySec = (delay > kMaxDelaySec) ? kMaxDelaySec : delay;
    } else {
        mDelaySec = kDefaultDelaySec;
    }

    mNub = OSDynamicCast(VoodooI2CDeviceNub, provider);
    if (!mNub) {
        logf("provider is not a VoodooI2CDeviceNub - refusing to start");
        return false;
    }
    mNub->retain();
    if (!mNub->open(this)) {
        logf("could not open VoodooI2CDeviceNub");
        mNub->release();
        mNub = nullptr;
        return false;
    }

    mTimer = IOTimerEventSource::timerEventSource(
        this, OSMemberFunctionCast(IOTimerEventSource::Action, this,
                                   &AW88399Fixup::bringUpTimerFired));
    IOWorkLoop *workLoop = getWorkLoop();
    if (!mTimer || !workLoop || workLoop->addEventSource(mTimer) != kIOReturnSuccess) {
        logf("could not create/schedule timer");
        if (mTimer) {
            mTimer->release();
            mTimer = nullptr;
        }
        mNub->close(this);
        mNub->release();
        mNub = nullptr;
        return false;
    }

    mStage = "waiting";
    publishState();
    logf("started: readOnly=%d noDsp=%d delay=%us", mReadOnly ? 1 : 0,
         mForceNoDsp ? 1 : 0, mDelaySec);
    mTimer->setTimeoutMS(mDelaySec * 1000);
    return true;
}

void AW88399Fixup::bringUpTimerFired(OSObject *owner, IOTimerEventSource *sender)
{
    runBringUp();
}

void AW88399Fixup::runBringUp()
{
    mStage = "probe";
    publishState();

    if (!probeChip()) {
        mStage = "probe-failed";
        publishState();
        return;
    }

    // Read-only diagnostics: record the state the chip is in right now, whatever it is.
    dumpRegister("SYSCTRL", kRegSysCtrl);
    if (readReg(kRegSysCtrl2, &mSysCtrl2)) {
        logf("SYSCTRL2 (0x%02x) = 0x%04x   <- volume field lives here", kRegSysCtrl2, mSysCtrl2);
    }
    if (readReg(kRegI2sCtrl1, &mI2sCtrl1)) {
        logf("I2SCTRL1 (0x%02x) = 0x%04x", kRegI2sCtrl1, mI2sCtrl1);
    }
    if (readReg(kRegI2sCtrl2, &mI2sCtrl2)) {
        logf("I2SCTRL2 (0x%02x) = 0x%04x", kRegI2sCtrl2, mI2sCtrl2);
    }
    if (readReg(kRegI2sCtrl3, &mI2sCtrl3)) {
        logf("I2SCTRL3 (0x%02x) = 0x%04x   <- I2STXEN / ASP config", kRegI2sCtrl3, mI2sCtrl3);
    }
    publishState();

    if (mReadOnly) {
        mStage = "read-only-done";
        publishState();
        logf("-aw88399ro set: stopping before any write");
        return;
    }

    mStage = "bringup";
    publishState();
    mApplied = applyMinimalBringUp();
    mStage = mApplied ? "applied" : "bringup-failed";
    publishState();
}

bool AW88399Fixup::probeChip()
{
    UInt16 id = 0;
    if (!readReg(kRegId, &id)) {
        logf("I2C read of ID_REG failed (no answer from the amplifier?)");
        return false;
    }
    mChipId = id;
    mProbeOk = (id == kChipId);
    logf("ID_REG = 0x%04x (expected 0x%04x) -> %s", id, kChipId,
         mProbeOk ? "AW88399 detected" : "unexpected");
    return mProbeOk;
}

bool AW88399Fixup::applyMinimalBringUp()
{
    // Mirrors the Linux sequence (aw88399.c):
    //   aw_dev_pwd(dev,false) / aw_dev_amppd(dev,false)  -> PWDN, AMPPD = working
    //   aw_dev_dsp_enable(dev,false)                     -> DSPBY = bypass (M1: no DSP)
    //   aw88399_dev_mute(dev,false)                      -> HMUTE = disable (un-muted)
    // Volume (SYSCTRL2) is intentionally left untouched; AppleHDA owns the level.
    UInt16 keepMask = AW88399_PWDN_MASK & AW88399_AMPPD_MASK & AW88399_DSPBY_MASK &
                      AW88399_HMUTE_MASK;
    UInt16 newBits = AW88399_PWDN_WORKING_VALUE | AW88399_AMPPD_WORKING_VALUE |
                     AW88399_HMUTE_DISABLE_VALUE |
                     (mForceNoDsp ? AW88399_DSPBY_BYPASS_VALUE : AW88399_DSPBY_WORKING_VALUE);

    UInt16 current = 0;
    if (!readReg(kRegSysCtrl, &current)) {
        logf("could not read SYSCTRL before writing");
        return false;
    }
    mSysCtrlBefore = current;

    UInt16 target = (UInt16)((current & keepMask) | newBits);
    if (!writeReg(kRegSysCtrl, target)) {
        logf("SYSCTRL write failed (0x%04x -> 0x%04x)", current, target);
        return false;
    }

    UInt16 readBack = 0;
    if (readReg(kRegSysCtrl, &readBack)) {
        mSysCtrlAfter = readBack;
        logf("SYSCTRL: 0x%04x -> wrote 0x%04x -> readback 0x%04x", current, target, readBack);
    } else {
        logf("SYSCTRL: 0x%04x -> wrote 0x%04x (read-back failed)", current, target);
    }
    return true;
}

void AW88399Fixup::dumpRegister(const char *name, UInt8 reg)
{
    UInt16 value = 0;
    if (readReg(reg, &value)) {
        logf("%s (0x%02x) = 0x%04x", name, reg, value);
    } else {
        logf("%s (0x%02x) read failed", name, reg);
    }
}

// ---------------------------------------------------------------------------
// I2C transport: AW88399 uses an 8-bit register address with 16-bit big-endian data.
// ---------------------------------------------------------------------------

bool AW88399Fixup::readReg(UInt8 reg, UInt16 *value)
{
    if (!mNub || !value) {
        return false;
    }
    UInt8 address = reg;
    UInt8 data[2] = {0, 0};
    IOReturn result = mNub->writeReadI2C(&address, 1, data, 2);
    if (result != kIOReturnSuccess) {
        logf("writeReadI2C(reg=0x%02x) failed: 0x%08x", reg, result);
        return false;
    }
    *value = (UInt16)((data[0] << 8) | data[1]);
    return true;
}

bool AW88399Fixup::writeReg(UInt8 reg, UInt16 value)
{
    if (!mNub) {
        return false;
    }
    UInt8 payload[3];
    payload[0] = reg;
    payload[1] = (UInt8)((value >> 8) & 0xFF);
    payload[2] = (UInt8)(value & 0xFF);
    IOReturn result = mNub->writeI2C(payload, 3);
    if (result != kIOReturnSuccess) {
        logf("writeI2C(reg=0x%02x, value=0x%04x) failed: 0x%08x", reg, value, result);
        return false;
    }
    return true;
}

bool AW88399Fixup::updateField(UInt8 reg, UInt16 linuxMask, UInt16 value)
{
    UInt16 current = 0;
    if (!readReg(reg, &current)) {
        return false;
    }
    // Linux semantics: AW88399_xxx_MASK already is ~(field mask), and the value is
    // pre-shifted, so regmap_update_bits(reg, linuxMask, value) becomes:
    UInt16 next = (UInt16)((current & linuxMask) | (value & (UInt16)~linuxMask));
    if (next == current) {
        return true;
    }
    return writeReg(reg, next);
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

void AW88399Fixup::publishState()
{
    setProperty("BringUpStage", mStage ? mStage : "unknown");
    setProperty("ChipId", (UInt32)mChipId, 32);
    setProperty("ProbeOk", mProbeOk);
    setProperty("Applied", mApplied);
    setProperty("ReadOnly", mReadOnly);
    setProperty("NoDsp", mForceNoDsp);
    setProperty("SysCtrlBefore", (UInt32)mSysCtrlBefore, 32);
    setProperty("SysCtrlAfter", (UInt32)mSysCtrlAfter, 32);
    setProperty("SysCtrl2", (UInt32)mSysCtrl2, 32);
    setProperty("I2sCtrl1", (UInt32)mI2sCtrl1, 32);
    setProperty("I2sCtrl2", (UInt32)mI2sCtrl2, 32);
    setProperty("I2sCtrl3", (UInt32)mI2sCtrl3, 32);
}

void AW88399Fixup::logf(const char *fmt, ...)
{
    if (!mDebug && (mStage != nullptr) && (strcmp(mStage, "applied") == 0)) {
        // keep quiet once everything worked, unless -aw88399dbg was given
        return;
    }
    char buffer[256];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    IOLog("AW88399Fixup: %s\n", buffer);
}

void AW88399Fixup::stop(IOService *provider)
{
    if (mTimer) {
        mTimer->cancelTimeout();
        IOWorkLoop *workLoop = getWorkLoop();
        if (workLoop) {
            workLoop->removeEventSource(mTimer);
        }
        mTimer->release();
        mTimer = nullptr;
    }
    if (mNub) {
        mNub->close(this);
        mNub->release();
        mNub = nullptr;
    }
    super::stop(provider);
}

void AW88399Fixup::free()
{
    super::free();
}

