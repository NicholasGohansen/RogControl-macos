/*
 * SSDT-ROG: ASUS ROG Strix G17 G713PV
 * Exposes the embedded controller's fan tachometers and temperatures to RogControl.kext.
 * The ITE EC is memory mapped (0xFE700600); offsets verified against Linux asus-wmi
 * and k10temp on BIOS G713PV.334.
 *
 * \_SB.ATKD.RGSN returns Package { CPU fan RPM, GPU fan RPM, fan 3 RPM, CPU temp C, GPU temp C }
 */
DefinitionBlock ("", "SSDT", 2, "PENGU", "ROGCTL", 0x00001000)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.PCI0.SBRG.FA1L, FieldUnitObj)
    External (_SB_.PCI0.SBRG.FA1H, FieldUnitObj)
    External (_SB_.PCI0.SBRG.FA2L, FieldUnitObj)
    External (_SB_.PCI0.SBRG.FA2H, FieldUnitObj)
    External (_SB_.PCI0.SBRG.FA3L, FieldUnitObj)
    External (_SB_.PCI0.SBRG.FA3H, FieldUnitObj)
    External (_SB_.PCI0.SBRG.RCPU, FieldUnitObj)
    External (_SB_.PCI0.SBRG.RVGA, FieldUnitObj)

    Scope (\_SB.ATKD)
    {
        Name (RGSB, Package (0x05)
        {
            Zero, Zero, Zero, Zero, Zero
        })

        Method (RGSN, 0, Serialized)
        {
            RGSB [Zero] = ((\_SB.PCI0.SBRG.FA1H << 0x08) | \_SB.PCI0.SBRG.FA1L)
            RGSB [One] = ((\_SB.PCI0.SBRG.FA2H << 0x08) | \_SB.PCI0.SBRG.FA2L)
            RGSB [0x02] = ((\_SB.PCI0.SBRG.FA3H << 0x08) | \_SB.PCI0.SBRG.FA3L)
            RGSB [0x03] = \_SB.PCI0.SBRG.RCPU
            RGSB [0x04] = \_SB.PCI0.SBRG.RVGA
            Return (RGSB)
        }
    }
}
