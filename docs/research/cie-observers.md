# CIE 2015 observers and D65 targets

The project now bundles the CIE's official 2015 2° and 10° cone-fundamental-based XYZ
colour-matching functions and standard illuminant D65 spectrum. The original CSV and metadata
bytes are in `Sources/D65Core/Resources/CIE`; SwiftPM copies this directory into D65Core's
resource bundle, including in the Mac/iPhone apps. No network access is needed at runtime.

## Sources and validation

Fetched from the CIE on 2026-10-25:

| Dataset | Source publication | Official dataset |
|---|---|---|
| 2015 2° XYZ CMFs | CIE 170-2:2015, Table 10.7a | [CIE 2° spectral tristimulus values](https://cie.co.at/datatable/cie-cone-fundamental-based-spectral-tristimulus-values-2-degree-field-size) |
| 2015 10° XYZ CMFs | CIE 170-2:2015, Table 10.8 | [CIE 10° spectral tristimulus values](https://cie.co.at/datatable/cie-cone-fundamental-based-spectral-tristimulus-values-10-field-size) |
| D65 relative SPD | ISO/CIE 11664-2:2022, Table B.1 | [CIE standard illuminant D65](https://cie.co.at/datatable/cie-standard-illuminant-d65) |

All three CSVs match both hashes published by the CIE and supplied in the accompanying metadata:

| File | MD5 | SHA-256 |
|---|---|---|
| `CIE_cfb_stv_2deg.csv` | `472cc50b14a6cf41ba9f08f8935aedc8` | `a10751ec8aecdb023f16ba079557e7fb794806884fe3da982dd63da285f872a9` |
| `CIE_cfb_stv_10deg.csv` | `c8504e70d7f4760253a0a4d3a42b7d20` | `9019a35f8f51215e245f818e87d4251147d1925a8fbe9a49944fe7f011f16e38` |
| `CIE_std_illum_D65.csv` | `03d4eb9b837c60671627c946fb534deb` | `e76f210bffff3d552ef7113025da5f325d5dfec200dd4b878b1a2f3a507032cb` |

The CMFs each have 441 rows on 390–830 nm; D65 has 531 rows on 300–830 nm, all at 1 nm spacing.
Checks include the complete wavelength sequence, column counts, finite/nonnegative values, exact
published column sums, and the metadata's 1-based sample row 120. No NaNs or gaps occur.

There is one metadata inconsistency: the D65 revision-2 JSON describes its wavelength column as
starting at 300 nm and its spectrum column as starting at 360 nm. The hash-verified CSV contains
both columns starting at 300 nm. This is retained unchanged and reported by the checker. It does
not affect the shared 390–830 nm integration range.

```sh
python3 scripts/check_cie_data.py           # offline validation and independent Decimal integration
python3 scripts/check_cie_data.py --fetch   # validate fresh official downloads before replacement
swift run d65 observers                    # targets from the actual packaged Swift resources
```

The checker runs in CI. Swift tests independently verify the bundle's hashes, pin the numerical
integration results, exercise malformed grids and absent spectral coverage, and run synthetic
sessions for each observer/metric. `.gitattributes` preserves original CSV/JSON line endings.
The CIE files carry **CC BY-SA 4.0**, not the project's MIT code license; attribution, DOIs and the
license link are retained in the bundled [source notice](../../Sources/D65Core/Resources/CIE/README.md).

## Calculation and results

For each observer, sum the products of the D65 SPD and its three CMF columns at all 441 wavelengths:

```text
X = Σ S_D65(λ) x̄(λ) Δλ
Y = Σ S_D65(λ) ȳ(λ) Δλ       λ = 390, 391, …, 830 nm; Δλ = 1 nm
Z = Σ S_D65(λ) z̄(λ) Δλ
XYZ_normalized = XYZ / Y
x = X / (X + Y + Z); y = Y / (X + Y + Z)
```

This is equal-step spectral summation, including both tabulated endpoints, with no interpolation.
The spectrum covers every required wavelength; no extrapolated tail is added. The CIE metadata
specifies zero extrapolation for the CMFs. Swift Double integration agrees with independent
Python Decimal integration within 10⁻¹³ in normalized XYZ.

| Observer | X (Y=1) | Z (Y=1) | D65 x | D65 y |
|---|---:|---:|---:|---:|
| CIE 1931 2° (existing rounded reference) | 0.950455927052 | 1.089057750760 | 0.312700000000 | 0.329000000000 |
| CIE 2015 2° | 0.9475535585704792 | 1.0754043433613863 | 0.3134524493261819 | 0.3308018280244443 |
| CIE 2015 10° | 0.9472085246870145 | 1.0714337379222504 | 0.3137862794872099 | 0.3312747629577068 |

`Observer.d65` now provides each target. It retains an optional return type: missing or malformed
resources return nil, rather than silently choosing a different observer's white. The 1931 default
stays unchanged. CIEDE2000 uses the selected target as its Lab reference white; CAM16 uses it as
the adopted white. Initial and residual solver calls receive the selected target as well.

For xy already expressed in one of the 2015 observer coordinate systems:

```sh
swift run d65 error 0.3134524493261819 0.3308018280244443 --observer cie2015-2
swift run d65 error 0.3137862794872099 0.3312747629577068 --observer cie2015-10
```

Both metrics report zero at the corresponding target (up to floating-point precision).
`--observer cie1931-2` is the default for this read-only command.

## Scope and observer consistency

A spectral D65 target is not an XYZ conversion. Existing iPhone ALS values are still treated as
CIE 1931 2°, an assumption not yet verified against a reference instrument. Its current network
adapter does not advertise a 2015 coordinate system. There is deliberately no `serve --observer`
flag that could relabel those readings. `CalibrationProbe.observer` declares a source's coordinate
system, and the engine rejects a configuration/source mismatch before touching the display.
Synthetic or future programmatic sources can explicitly declare a matching CIE 2015 observer.

A valid 2015 measurement requires spectral data or a sensor characterization for that observer;
1931 XYZ alone does not determine 2015 XYZ for arbitrary spectra. Display-primary matrices must
also use consistent observer coordinates: the existing default sRGB primary matrix is a 1931
model, not a newly characterized 2015 display model. Enabling these targets does not establish
physical CIE 2015 calibration accuracy, change historical records, or validate the new observers
against the iPhone hardware. No display correction was applied for this dataset/code change.
