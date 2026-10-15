// VoodooI2CShim.hpp
//
// Minimal declaration of the two VoodooI2C entry points this kext uses, so that the
// project can be built without vendoring the whole VoodooI2C source tree.
//
// Provenance: these signatures are copied verbatim from VoodooI2C's public header
//   VoodooI2C/VoodooI2C/VoodooI2CDevice/VoodooI2CDeviceNub.hpp
// (class EXPORT VoodooI2CDeviceNub : public IOService; methods are public and NOT
//  virtual, so the mangled names below resolve against the loaded VoodooI2C.kext at
//  kext-load time).
//
// The provider chain is:
//   VoodooI2CControllerDriver  →  publishes VoodooI2CDeviceNub (one per ACPI I2C client)
//   our kext matches that nub by IOName == "AWDZ8399"
//
// If you prefer to compile against the real headers, drop the VoodooI2C sources in a
// sibling directory and remove this shim (see docs/design.md §3).

#ifndef AW88399_VOODOOI2C_SHIM_HPP
#define AW88399_VOODOOI2C_SHIM_HPP

#include <IOKit/IOService.h>

class VoodooI2CDeviceNub : public IOService {
public:
    /* Transmits an I2C read request to the slave device. */
    IOReturn readI2C(UInt8 *values, UInt16 length);

    /* Transmits an I2C write request to the slave device. */
    IOReturn writeI2C(UInt8 *values, UInt16 length);

    /* Transmits an I2C write-read (repeated start) request to the slave device. */
    IOReturn writeReadI2C(UInt8 *write_buffer, UInt16 write_length,
                          UInt8 *read_buffer, UInt16 read_length);
};

#endif /* AW88399_VOODOOI2C_SHIM_HPP */
