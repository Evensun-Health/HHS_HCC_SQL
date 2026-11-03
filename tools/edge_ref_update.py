#!/usr/bin/env python3
"""Align the Table-Load-Scripts with an EDGE Global Reference Data workbook.

Source: the monthly "Global-Ref-Data-Update-*.xlsx" that CMS deploys to the EDGE
server (title rows 1-2, header row 4, data from row 5; OPERATION is OLD / NEW /
UPDATE / DELETE).  The workbook lists the *complete* table every time, so it is
applied as a full snapshot.

Dry run unless --write.

  1. dbo.RiskScoreFactors.Table.sql  (verify only)
       Compares the rows tagged with the benefit year's Model_Year (see the
       @model_year mapping in the DIY Model Script) against the workbook's factor
       tabs and reports any differing cell.  Nothing is written: if this ever
       reports differences, add a new Model_Year tag and point the script at it
       rather than editing a published tag.
  2. dbo.NDC_RXC.Table.sql
       Mappings EDGE DELETEd that are still valid in <year> are end-dated at
       <year>-1 (history kept).  EDGE-active mappings that are not valid in <year>
       get a new <year>-<year+1> row.  ACF_01 rows are never touched (the workbook
       does not carry them).
  3. dbo.HCPCSRXC.Table.sql  (no year columns, so this one is a true add/remove)
       Non-ACF rows EDGE no longer lists (DELETE rows and codes dropped from the
       tab) are removed; missing EDGE-active codes are added.

The .sql files are UTF-16LE with a BOM and CRLF line endings; that is preserved.

Usage:
    python tools/edge_ref_update.py WORKBOOK.xlsx [--year 2026] [--model-year 2026_DIY_073126] [--write]

Needs pandas + openpyxl.
"""
import argparse
import re
import sys
from collections import Counter
from pathlib import Path

import pandas as pd

LOAD_DIR = Path(__file__).resolve().parent.parent / 'Table-Load-Scripts'
METALS = ['01', '02', '03', '04', '05']  # Platinum, Gold, Silver, Bronze, Catastrophic
HCC_SUFFIX = {'351': '035_1', '352': '035_2', '371': '037_1', '372': '037_2',
              '871': '087_1', '872': '087_2', '1611': '161_1', '1612': '161_2'}
MATURITY = {'A1': 'AGE1', 'EI': 'EXTREMELY_IMMATURE', 'I': 'IMMATURE',
            'PM': 'PREMATURE_MULTIPLES', 'T': 'TERM'}


def read_sheet(path, sheet):
    return pd.read_excel(path, sheet_name=sheet, header=3, dtype=str, engine='openpyxl')


def build_factors(path):
    """Return {'Adult'|'Child'|'Infant': {variable: [P, G, S, B, C]}} in CMS-package names."""
    out = {}

    def put(model, var, level, value):
        row = out.setdefault(model, {}).setdefault(var, [None] * 5)
        i = METALS.index(level)
        assert row[i] is None, (model, var, level, 'duplicate')
        row[i] = float(value)

    for r in read_sheet(path, 'Demographic Factors').itertuples():
        lo, hi = int(r.AGE_MIN_INCL), int(r.AGE_MAX_EXCL)
        if r.AGE_MDL_TYP == 'Infant':
            var = f'AGE{lo}_MALE'
        else:
            band = f'{lo}_GT' if hi >= 999 else f'{lo}_{hi - 1}'
            var = f'{r.GENDER_TYPE}AGE_LAST_{band}'
        put(r.AGE_MDL_TYP, var, r.MTL_LVL_CD, r.DMGRPHC_FCTR)

    # An HCC inside a group carries 0 on its own row; the value sits on the G-group row.
    for r in read_sheet(path, 'HCC and HCC Group Factors').itertuples():
        if r.HCC_CD != 'BLNK':
            assert r.GRP_CD == 'BLNK'
            var = f'HHS_HCC{HCC_SUFFIX.get(r.HCC_CD, r.HCC_CD.zfill(3))}'
        else:
            var = r.GRP_CD
        put(r.AGE_MDL_TYP, var, r.MTL_LVL_CD, r.FACTOR_QTY)

    # Severity / transplant counters (CMS-package buckets): Adult SEVERE 10+, TRANSPLANT 8+;
    # Child SEVERE 6-7 share a column, 8+, TRANSPLANT 4+.  Every count in a bucket must
    # carry the same value.
    for r in read_sheet(path, 'HCCCOUNT_SEVTRANSPLANT_FACTOR').itertuples():
        n = int(r.HCC_COUNT)
        if r.SEVERITY_TYPE == 'S':
            if r.AGE_MODEL == 'Adult':
                tag = '10PLUS' if n >= 10 else str(n)
            else:
                tag = '6_7' if n in (6, 7) else '8PLUS' if n >= 8 else str(n)
            var = f'SEVERE_HCC_COUNT{tag}'
        else:
            tag = ('8PLUS' if n >= 8 else str(n)) if r.AGE_MODEL == 'Adult' else '4PLUS'
            var = f'TRANSPLANT_HCC_COUNT{tag}'
        row = out.setdefault(r.AGE_MODEL, {}).setdefault(var, [None] * 5)
        i = METALS.index(r.MTL_LVL_CD)
        if row[i] is not None:
            assert abs(row[i] - float(r.FACTOR_QTY)) < 1e-9, (r.AGE_MODEL, var, n, row[i], r.FACTOR_QTY)
        row[i] = float(r.FACTOR_QTY)

    # Enrollment-duration factors: Adult only; months 7-12 are zero and not stored.
    for r in read_sheet(path, 'HCC_ENROLLMENT_DURATION_FACTOR').itertuples():
        m = int(r.ENROLLMENT_MONTHS)
        if m <= 6:
            assert r.HCC_COUNT == '1'
            put('Adult', f'HCC_ED{m}', r.MTL_LVL_CD, r.FACTOR_QTY)
        else:
            assert float(r.FACTOR_QTY) == 0

    for r in read_sheet(path, 'Infant Severity Maturity Factor').itertuples():
        put('Infant', f'{MATURITY[r.MATURITY_CD]}_X_SEVERITY{r.SVRTY_TYP_CD[1]}',
            r.MTL_LVL_CD, r.INFNT_SVRTY_MTRTY_FCTR)

    for r in read_sheet(path, 'RXC_STANDALONE_FACTOR').itertuples():
        assert r.MODEL_TYPE == 'ADULT'
        put('Adult', f'RXC_{int(r.RXC):02d}', r.MTL_LVL, r.FACTOR)
    for r in read_sheet(path, 'RXC_HCC_INTERACTION_FACTOR').itertuples():
        assert r.MODEL_TYPE == 'ADULT'
        put('Adult', r.INTERACTION, r.MTL_LVL, r.FACTOR)

    for model in out.values():
        for var, vals in model.items():
            assert None not in vals, var
    return out


# ---------------------------------------------------------------- SQL file helpers
def read_sql(path):
    raw = Path(path).read_bytes()
    assert raw[:2] == b'\xff\xfe', f'{path} is not UTF-16LE with BOM'
    text = raw.decode('utf-16')
    assert '\r\n' in text
    return text


def write_sql(path, text):
    Path(path).write_bytes(b'\xff\xfe' + text.encode('utf-16-le'))


def sql_factor_names(model, cms_name):
    """CMS-package variable -> the names dbo.RiskScoreFactors stores (DIY spelling)."""
    if cms_name == 'SEVERE_HCC_COUNT6_7':
        return ['SEVERE_6_HCC', 'SEVERE_7_HCC']
    if cms_name == 'SEVERE_HCC_COUNT8PLUS' and model == 'Child':
        return [f'SEVERE_{n}_HCC' for n in (8, 9, 10)]
    if cms_name == 'TRANSPLANT_HCC_COUNT4PLUS':
        return [f'TRANSPLANT_{n}_HCC' for n in range(4, 9)]
    m = re.fullmatch(r'SEVERE_HCC_COUNT(\d+)(PLUS)?', cms_name)
    if m:
        return [f'SEVERE_{m.group(1)}_HCC']
    m = re.fullmatch(r'TRANSPLANT_HCC_COUNT(\d+)(PLUS)?', cms_name)
    if m:
        return [f'TRANSPLANT_{m.group(1)}_HCC']
    m = re.fullmatch(r'HCC_ED(\d+)', cms_name)
    if m:
        return [f'ED_{m.group(1)}']
    return [cms_name]


ROW_RE = re.compile(r"VALUES \(N'([^']*)', N'([^']*)', N'([^']*)', ([-\d.eE]+), ([-\d.eE]+), "
                    r"([-\d.eE]+), ([-\d.eE]+), ([-\d.eE]+), N'([^']*)'\)")


def verify_factors(workbook, model_year):
    factors = build_factors(workbook)
    stored = {}
    for line in read_sql(LOAD_DIR / 'dbo.RiskScoreFactors.Table.sql').split('\r\n'):
        if line.startswith('INSERT'):
            g = ROW_RE.search(line).groups()
            if g[8] == model_year:
                stored.setdefault(g[0], {})[g[1]] = [float(x) for x in g[3:8]]
    report = {}
    for model, rows in factors.items():
        cells = diff = 0
        missing, bad = [], []
        for cms_name, edge in rows.items():
            for name in sql_factor_names(model, cms_name):
                if name not in stored.get(model, {}):
                    missing.append(name)
                    continue
                for a, b in zip(stored[model][name], edge):
                    cells += 1
                    if abs(a - b) > 1e-9:
                        diff += 1
                        bad.append(name)
        report[model] = dict(cells=cells, differ=diff, missing=missing, differing_vars=sorted(set(bad)))
    return report


# ---------------------------------------------------------------- mappings
NDC_ROW = re.compile(r"^(INSERT \[dbo\]\.\[NDC_RXC\] \(\[NDC_CODE\], \[RXC\], \[start_year\], \[end_year\]\) "
                     r"VALUES \(N')([^']+)(', N')([^']*)(', )(\d+)(, )(\d+)(\))$")  # NDC may contain letters
NDC_INSERT = ("INSERT [dbo].[NDC_RXC] ([NDC_CODE], [RXC], [start_year], [end_year]) "
              "VALUES (N'{}', N'{}', {}, {})")
HCPCS_ROW = re.compile(r"^INSERT \[dbo\]\.\[HCPCSRXC\] \(\[HCPCS_CODE\], \[RXC\]\) VALUES \(N'([^']*)', N'([^']*)'\)$")
HCPCS_INSERT = "INSERT [dbo].[HCPCSRXC] ([HCPCS_CODE], [RXC]) VALUES (N'{}', N'{}')"


def update_ndc(workbook, year, write):
    df = read_sheet(workbook, 'NDC_RXC_MAPPING')
    df['RXC'] = df.RXC.str.strip()
    active = set(map(tuple, df[df.OPERATION != 'DELETE'][['NDC_CODE', 'RXC']].values))
    deleted = set(map(tuple, df[df.OPERATION == 'DELETE'][['NDC_CODE', 'RXC']].values))
    is_new = set(map(tuple, df[df.OPERATION == 'NEW'][['NDC_CODE', 'RXC']].values))
    path = LOAD_DIR / 'dbo.NDC_RXC.Table.sql'
    lines = read_sql(path).split('\r\n')
    out, ended, valid, pairs, last_insert = [], 0, set(), set(), None
    for ln in lines:
        m = NDC_ROW.match(ln)
        if m:
            ndc, rxc, s, e = m.group(2), m.group(4), int(m.group(6)), int(m.group(8))
            if not rxc.startswith('ACF') and (ndc, rxc) in deleted and e >= year:
                assert s < year, (ndc, rxc, s, e)
                e = year - 1
                ended += 1
                ln = m.group(1) + ndc + m.group(3) + rxc + m.group(5) + str(s) + m.group(7) + str(e) + m.group(9)
            if not rxc.startswith('ACF') and s <= year <= e:
                valid.add((ndc, rxc))
            pairs.add((ndc, rxc))
            last_insert = len(out)
        out.append(ln)
    add = sorted(active - valid, key=lambda k: (int(k[1]), k[0]))
    out[last_insert + 1:last_insert + 1] = [NDC_INSERT.format(n, r, year, year + 1) for n, r in add]
    assert (valid | set(add)) == active, f'BY{year} valid set != EDGE active set'
    if write:
        write_sql(path, '\r\n'.join(out))
    return dict(ended=ended, added=len(add), added_marked_new=len(is_new & set(add)),
                added_by_rxc=dict(sorted(Counter(r for _, r in add).items(), key=lambda kv: int(kv[0]))),
                added_pairs_with_other_year_rows=sum(1 for k in add if k in pairs), edge_active=len(active),
                insert_rows=sum(1 for ln in out if NDC_ROW.match(ln)))


def update_hcpcs(workbook, write):
    df = read_sheet(workbook, 'HCPCS_RXC_MAPPING')
    df['RXC'] = df.RXC.str.strip()
    active = set(map(tuple, df[df.OPERATION != 'DELETE'][['HCPCS_CODE', 'RXC']].values))
    path = LOAD_DIR / 'dbo.HCPCSRXC.Table.sql'
    lines = read_sql(path).split('\r\n')
    out, removed, seen, last_insert = [], [], set(), None
    for ln in lines:
        m = HCPCS_ROW.match(ln)
        if m:
            code, rxc = m.groups()
            if not rxc.startswith('ACF') and (code, rxc) not in active:
                removed.append((code, rxc))
                continue
            seen.add((code, rxc))
            last_insert = len(out)
        out.append(ln)
    add = sorted(active - seen, key=lambda k: (int(k[1]), k[0]))
    # keep the ACF_01 block last, as the file has it: new rows go after the last non-ACF row
    pos = max(i for i, ln in enumerate(out) if HCPCS_ROW.match(ln) and not HCPCS_ROW.match(ln).group(2).startswith('ACF'))
    out[pos + 1:pos + 1] = [HCPCS_INSERT.format(c, r) for c, r in add]
    if write:
        write_sql(path, '\r\n'.join(out))
    return dict(removed=removed, added=add, insert_rows=sum(1 for ln in out if HCPCS_ROW.match(ln)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('workbook')
    ap.add_argument('--year', type=int, default=2026)
    ap.add_argument('--model-year', default='2026_DIY_073126',
                    help='Model_Year tag in dbo.RiskScoreFactors to verify (default: the BY2026 tag)')
    ap.add_argument('--write', action='store_true', help='apply changes (default is a dry run)')
    a = ap.parse_args()
    print('WRITING' if a.write else 'DRY RUN')
    for model, rep in verify_factors(a.workbook, a.model_year).items():
        print(f'RiskScoreFactors {a.model_year} {model}: {rep["differ"]}/{rep["cells"]} cells differ '
              f'{rep["differing_vars"][:10]}; EDGE variables absent: {rep["missing"]}')
    print('NDC_RXC :', update_ndc(a.workbook, a.year, a.write))
    print('HCPCSRXC:', update_hcpcs(a.workbook, a.write))


if __name__ == '__main__':
    sys.exit(main())
