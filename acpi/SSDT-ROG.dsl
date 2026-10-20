/*
 * SSDT-ROG: ASUS TUF Gaming F15 FX507VV
 * Exposes the ITE EC's fan tachometers and temperatures to RogControl.kext.
 * The EC is memory mapped (0xFE700600, region IT55) under \_SB.PC00.LPCB.
 * Offsets taken from this machine's DSDT:
 *   FA1L/H 0x02-0x03  CPU fan RPM
 *   FA2L/H 0x24-0x25  GPU fan RPM
 *   RCPU   0x04       CPU temp
 *   RVGA   0x0A       GPU temp
 * This DSDT has no third fan, so fan 3 is reported as 0.
 *
 * \_SB.ATKD.RGSN returns Package { CPU fan RPM, GPU fan RPM, fan 3 RPM, CPU temp C, GPU temp C }
 */
DefinitionBlock ("", "SSDT", 2, "PENGU", "ROGCTL", 0x00001000)
{
    External (_SB_.ATKD, DeviceObj)
    External (_SB_.PC00.LPCB.FA1L, FieldUnitObj)
    External (_SB_.PC00.LPCB.FA1H, FieldUnitObj)
    External (_SB_.PC00.LPCB.FA2L, FieldUnitObj)
    External (_SB_.PC00.LPCB.FA2H, FieldUnitObj)
    External (_SB_.PC00.LPCB.RCPU, FieldUnitObj)
    External (_SB_.PC00.LPCB.RVGA, FieldUnitObj)

    Scope (\_SB.ATKD)
    {
        Name (RGSB, Package (0x05)
        {
            Zero, Zero, Zero, Zero, Zero
        })

        Method (RGSN, 0, Serialized)
        {
            RGSB [Zero] = ((\_SB.PC00.LPCB.FA1H << 0x08) | \_SB.PC00.LPCB.FA1L)
            RGSB [One] = ((\_SB.PC00.LPCB.FA2H << 0x08) | \_SB.PC00.LPCB.FA2L)
            RGSB [0x02] = Zero
            RGSB [0x03] = \_SB.PC00.LPCB.RCPU
            RGSB [0x04] = \_SB.PC00.LPCB.RVGA
            Return (RGSB)
        }
    }
}
