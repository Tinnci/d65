# CIE source data

Downloaded unchanged from the International Commission on Illumination (CIE), 2026-10-25.
The CSV files retain their original bytes/line endings; accompanying JSON is the official metadata.

| Dataset | CIE source page | DOI |
|---|---|---|
| `CIE_cfb_stv_2deg.csv` | [2° cone-fundamental-based spectral tristimulus values](https://cie.co.at/datatable/cie-cone-fundamental-based-spectral-tristimulus-values-2-degree-field-size) | [10.25039/CIE.DS.548rw69q](https://doi.org/10.25039/CIE.DS.548rw69q) |
| `CIE_cfb_stv_10deg.csv` | [10° cone-fundamental-based spectral tristimulus values](https://cie.co.at/datatable/cie-cone-fundamental-based-spectral-tristimulus-values-10-field-size) | [10.25039/CIE.DS.dm6qiig7](https://doi.org/10.25039/CIE.DS.dm6qiig7) |
| `CIE_std_illum_D65.csv` | [CIE standard illuminant D65](https://cie.co.at/datatable/cie-standard-illuminant-d65) | [10.25039/CIE.DS.hjfjmt59](https://doi.org/10.25039/CIE.DS.hjfjmt59) |

Attribution: CIE (2015), CIE cone-fundamental-based spectral tristimulus values for 2° and 10°
field size; CIE (2019), CIE standard illuminant D65; International Commission on Illumination (CIE),
Vienna, AT. The CMFs originate in CIE 170-2:2015, Tables 10.7a and 10.8; the D65 spectrum originates
in ISO/CIE 11664-2:2022, Table B.1. See each metadata file for the complete supplied citation.

## Dataset license

These six CIE files are **CC BY-SA 4.0**, as specified in their `rightsList` metadata, independently
of this repository's MIT source-code license. Retain CIE attribution and this notice when
redistributing them. License: [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/).
No source dataset values were changed. The project's Swift implementation and validation script
are separate original code; computed target values are attributed to these CIE datasets.

## Checks

Run `python3 scripts/check_cie_data.py` from the repository root. `--fetch` downloads a fresh copy
from the CIE into a temporary directory and validates all files before replacing the local copies.
The script pins the CIE's MD5 and SHA-256 digests, and checks their metadata, exact wavelength grids,
row/column counts, finite nonnegative values, published column sums, and published sample rows.
It independently integrates the spectra with Decimal arithmetic. Swift tests verify bundled
checksums and integration against those independently calculated values.

Both CMFs have 441 rows, 390–830 nm in 1 nm steps. The D65 CSV has 531 rows, 300–830 nm in 1 nm
steps. There are no missing/NaN values in these files. The D65 metadata revision 2 contains a
known discrepancy: its wavelength column starts at 300 nm but its spectrum-column descriptor
starts at 360 nm. The checksum-valid CSV actually supplies both columns starting at 300 nm.
We retain that metadata unchanged and report the discrepancy. Our integration uses only
390–830 nm, so it is unaffected.

Target calculation is the equal-step sum of D65 × each CMF, with every tabulated CMF sample
included, followed by normalization to Y=1. No interpolation is needed; no extrapolated tail is
added. The CIE metadata specifies zero extrapolation for the CMFs. Results:

| Observer | X (Y=1) | Z (Y=1) | x | y |
|---|---:|---:|---:|---:|
| CIE 2015 2° | 0.9475535585704792 | 1.0754043433613863 | 0.3134524493261819 | 0.3308018280244443 |
| CIE 2015 10° | 0.9472085246870145 | 1.0714337379222504 | 0.3137862794872099 | 0.3312747629577068 |

The existing CIE 1931 2° target remains the rounded sRGB/Rec.709 reference x=0.3127, y=0.3290.
These are different observer coordinate systems: loading the targets does not convert iPhone ALS
XYZ, sRGB primary coordinates, or historical measurements into CIE 2015 coordinates.
