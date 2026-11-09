# Sensors

`FanSensor` opens AppleSMC and admits only commands 9 (key information) and 5 (read bytes). It decodes `ui8`, `ui16`, `ui32`, `sp78`, `fpe2` and finite little-endian floats. Unknown types and out-of-range values remain unavailable.

| Model | Temperature preference | Fan handling |
| --- | --- | --- |
| MacBookAir10,1 (M1 Air) | TCHP, then TC0P | Known fanless |
| Mac16,12 / Mac16,13 (M4 Air) | Tp09, then TC0P | Known fanless |
| Other models | Tp09, then TC0P | Read FNum and F0Ac… |

The M1 mapping was verified with real reads on an M1 Air. Older code only tried Tp09 and TC0P, both missing on that machine, and omitted the M1 identifier from its fanless list. The fix selects a readable sensor and explicitly recognizes the fanless hardware.

SEN labels a single SMC sensor. Apple does not publish a stable cross-model contract for these keys; the value is not presented as a package average or the hottest component. Temperature readings outside 0–125°C are rejected. Supported-model entries are deliberately explicit; an unknown model is not inferred to be fanless.

For fans, an unavailable count, a verified zero fan count, an unreadable RPM and a stopped fan are distinct states. Fan speed is never adjusted. GPU metrics also depend on driver-provided counters and may be unavailable.

To report a new model, include its model identifier, macOS version and the missing metric. Do not include serial numbers or full I/O registry dumps. Add a model mapping only with reproducible hardware evidence.
