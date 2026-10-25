#!/usr/bin/env python3
"""Validate pinned official CIE files and independently integrate D65 (Python stdlib only).

--fetch downloads into a temporary directory, validates everything, then replaces the six files.
No flag validates the checked-in copies without network access.
"""
import argparse
import csv
from decimal import Decimal
import hashlib
import io
import json
import math
from pathlib import Path
import shutil
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1] / "Sources/D65Core/Resources/CIE"
BASE = "https://files.cie.co.at/Publications-datasets/"
SOURCES = [
    ("CIE_cfb_stv_2deg.csv", "_metadata.json", 390, 830, 4,
     "472cc50b14a6cf41ba9f08f8935aedc8", "a10751ec8aecdb023f16ba079557e7fb794806884fe3da982dd63da285f872a9"),
    ("CIE_cfb_stv_10deg.csv", "_metadata.json", 390, 830, 4,
     "c8504e70d7f4760253a0a4d3a42b7d20", "9019a35f8f51215e245f818e87d4251147d1925a8fbe9a49944fe7f011f16e38"),
    ("CIE_std_illum_D65.csv", "_metadata_v2.json", 300, 830, 2,
     "03d4eb9b837c60671627c946fb534deb", "e76f210bffff3d552ef7113025da5f325d5dfec200dd4b878b1a2f3a507032cb"),
]


def validate(directory):
    tables = {}
    for name, suffix, first, last, columns, md5, sha256 in SOURCES:
        payload = (directory / name).read_bytes()
        meta = json.loads((directory / (name + suffix)).read_bytes())
        official = {item["hashMethod"]: item["checksum"] for item in meta["checksums"]}
        for method, expected in [("md5", md5), ("sha256", sha256)]:
            if official[method] != expected or hashlib.new(method, payload).hexdigest() != expected:
                raise ValueError(f"{name}: {method} differs from pinned CIE checksum")
        rows = [[Decimal(v) for v in row] for row in csv.reader(io.StringIO(payload.decode("utf-8"))) ]
        if len(rows) != last - first + 1:
            raise ValueError(f"{name}: missing/extra wavelengths")
        for wavelength, row in zip(range(first, last + 1), rows):
            if len(row) != columns or not all(v.is_finite() and v >= 0 for v in row) or row[0] != wavelength:
                raise ValueError(f"{name}: invalid row at {wavelength} nm")
        validations = meta["datatableInfo"]["validations"]
        if {v["validationType"] for v in validations} != {"sumOfColumns", "sampleRow"}:
            raise ValueError(f"{name}: unexpected validation definitions")
        for validation in validations:
            if validation["validationType"] == "sumOfColumns":
                expected = json.loads(validation["validationValue"], parse_float=Decimal, parse_int=Decimal)
                actual = [sum(row[i] for row in rows) for i in range(columns)]
            else:
                expected = [Decimal(v) for v in validation["validationValue"].split(",")]
                actual = rows[int(validation["validationParameter"]) - 1]  # CIE sample rows are 1-based.
            if actual != expected:
                raise ValueError(f"{name}: failed published {validation['validationType']}: {actual} vs {expected}")
        for column, header in enumerate(meta["datatableInfo"]["columnHeaders"]):
            grid = (header["wavelength_first"], header["wavelength_last"], header["wavelength_step"])
            if grid != (first, last, 1):
                if name == "CIE_std_illum_D65.csv" and column == 1 and grid == (360, 830, 1):
                    print("NOTE: D65 metadata spectrum column starts at 360 nm; checksum-valid CSV starts at 300 nm.")
                else:
                    raise ValueError(f"{name}: unexpected metadata grid {grid}")
        if meta["rightsList"][0]["rightsIdentifier"] != "CC BY-SA 4.0":
            raise ValueError(f"{name}: review changed licensing metadata")
        tables[name] = rows
        print(f"PASS {name}: {len(rows)} rows, {first}–{last} nm / 1 nm; MD5, SHA-256, grids, values, column sums, sample row")
    spectrum = {int(row[0]): row[1] for row in tables["CIE_std_illum_D65.csv"]}
    for name, *_ in SOURCES[:2]:
        # Decimal summation provides an independent check of the Swift Double implementation.
        xyz = [sum(spectrum[int(row[0])] * row[channel] for row in tables[name]) for channel in (1, 2, 3)]
        white = [v / xyz[1] for v in xyz]
        xy = [v / sum(xyz) for v in xyz[:2]]
        if not all(math.isfinite(float(v)) for v in white + xy):
            raise ValueError(f"{name}: non-finite D65 integral")
        print(f"{name} D65 XYZ (Y=1): " + ", ".join(f"{v:.16f}" for v in white))
        print("  xy: " + ", ".join(f"{v:.16f}" for v in xy))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fetch", action="store_true", help="fetch official files and replace local copies only after validation")
    args = parser.parse_args()
    if not args.fetch:
        validate(ROOT)
        return
    with tempfile.TemporaryDirectory(prefix="d65-cie-") as temporary:
        directory = Path(temporary)
        for name, suffix, *_ in SOURCES:
            for filename in (name, name + suffix):
                with urlopen(BASE + filename, timeout=60) as response:
                    (directory / filename).write_bytes(response.read())
        validate(directory)
        ROOT.mkdir(parents=True, exist_ok=True)
        for file in directory.iterdir():
            shutil.copyfile(file, ROOT / file.name)


if __name__ == "__main__":
    main()
