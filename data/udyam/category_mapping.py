import math

def get_general_industry_category(nic_division_code):
    """
    Maps a NIC division code (which can be a 3-digit group code)
    to a broader general industry category based on the NIC 2008 structure (Sections A-U).
    """
    if nic_division_code is None or (
        isinstance(nic_division_code, float) and math.isnan(nic_division_code)
    ):
        return "X. Unclassified"

    # Keep leading zeroes so codes such as 01462 map to division 01.
    nic_division_code = str(nic_division_code).strip()
    if len(nic_division_code) < 2 or not nic_division_code[:2].isdigit():
        return "X. Unclassified"
    nic_division_code = int(nic_division_code[:2])

    # Section A: Agriculture, Forestry & Fishing (Divisions 01-03)
    # Corresponds to 2-digit codes 01, 02, 03
    if 1 <= nic_division_code <= 3: return "A. Agriculture, Forestry & Fishing"

    # Section B: Mining & Quarrying (Divisions 05-09)
    # Corresponds to 2-digit codes 05, 06, 07, 08, 09
    if 5 <= nic_division_code <= 9: return "B. Mining & Quarrying"

    # Section C: Manufacturing (Divisions 10-33)
    if 10 <= nic_division_code <= 33: return "C. Manufacturing"

    # Section D/E: Electricity, Gas, Water & Waste (Divisions 35-39)
    if 35 <= nic_division_code <= 39: return "D_E. Electricity, Gas, Water & Waste"

    # Section F: Construction (Divisions 41-43)
    if 41 <= nic_division_code <= 43: return "F. Construction"

    # Section G: Wholesale & Retail Trade (Divisions 45-47)
    if 45 <= nic_division_code <= 47: return "G. Wholesale & Retail Trade"

    # Section H: Transportation & Storage (Divisions 49-53)
    if 49 <= nic_division_code <= 53: return "H. Transportation & Storage"

    # Section I: Accommodation & Food Services (Divisions 55-56)
    if 55 <= nic_division_code <= 56: return "I. Accommodation & Food Services"

    # Section J: Information & Communication (Divisions 58-63)
    if 58 <= nic_division_code <= 63: return "J. Information & Communication"

    # Section K: Financial & Insurance (Divisions 64-66)
    if 64 <= nic_division_code <= 66: return "K. Financial & Insurance"

    # Section L: Real Estate (Division 68)
    if nic_division_code == 68: return "L. Real Estate"

    # Section M: Professional, Scientific & Technical (Divisions 69-75)
    if 69 <= nic_division_code <= 75: return "M. Professional, Scientific & Technical"

    # Section N: Administrative & Support Services (Divisions 77-82)
    if 77 <= nic_division_code <= 82: return "N. Administrative & Support Services"

    # Section O: Public Administration & Defence (Division 84)
    if nic_division_code == 84: return "O. Public Administration & Defence"

    # Section P: Education (Division 85)
    if nic_division_code == 85: return "P. Education"

    # Section Q: Human Health & Social Work (Divisions 86-88)
    if 86 <= nic_division_code <= 88: return "Q. Human Health & Social Work"

    # Section R: Arts, Entertainment & Recreation (Divisions 90-93)
    if 90 <= nic_division_code <= 93: return "R. Arts, Entertainment & Recreation"

    # Section S: Other Service Activities (Divisions 94-96)
    if 94 <= nic_division_code <= 96: return "S. Other Service Activities"

    # Section T: Households as Employers (Divisions 97-98)
    if 97 <= nic_division_code <= 98: return "T. Households as Employers"

    # Section U: Extraterritorial Organizations (Division 99)
    if nic_division_code == 99: return "U. Extraterritorial Organizations"

    return "X. Unclassified"