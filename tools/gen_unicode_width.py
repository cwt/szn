import urllib.request
import os
import re
import sys
import subprocess

CACHE_DIR = "tools/unicode_cache"
EAW_URL = "https://www.unicode.org/Public/UCD/latest/ucd/extracted/DerivedEastAsianWidth.txt"
EMOJI_URL = "https://www.unicode.org/Public/UCD/latest/ucd/emoji/emoji-data.txt"
TARGET_FILE = "src/char_width.zig"

def download_file(url, filename):
    os.makedirs(CACHE_DIR, exist_ok=True)
    filepath = os.path.join(CACHE_DIR, filename)
    if not os.path.exists(filepath):
        print(f"Downloading {url}...")
        urllib.request.urlretrieve(url, filepath)
    return filepath

def parse_ranges(filepath, property_filter=None):
    ranges = []
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            parts = [p.strip() for p in line.split(";")]
            if len(parts) < 2:
                continue
            cp_range = parts[0]
            prop = parts[1]
            if property_filter and prop not in property_filter:
                continue
            
            if ".." in cp_range:
                start_str, end_str = cp_range.split("..")
            else:
                start_str = end_str = cp_range
            
            start = int(start_str, 16)
            end = int(end_str, 16)
            ranges.append((start, end))
    return ranges

def codepoints_from_ranges(ranges):
    cps = set()
    for start, end in ranges:
        for cp in range(start, end + 1):
            cps.add(cp)
    return cps

def codepoints_to_merged_ranges(cps):
    if not cps:
        return []
    sorted_cps = sorted(list(cps))
    ranges = []
    start = sorted_cps[0]
    prev = start
    for cp in sorted_cps[1:]:
        if cp == prev + 1:
            prev = cp
        else:
            ranges.append((start, prev))
            start = cp
            prev = cp
    ranges.append((start, prev))
    return ranges

def generate_zig_array(ranges):
    lines = []
    for start, end in ranges:
        lines.append(f"    .{{ .start = 0x{start:X}, .end = 0x{end:X}, .width = 2 }},")
    return "\n" + "\n".join(lines) + "\n"

def main():
    eaw_path = download_file(EAW_URL, "DerivedEastAsianWidth.txt")
    emoji_path = download_file(EMOJI_URL, "emoji-data.txt")
    
    # 1. Parse Wide and Fullwidth properties from DerivedEastAsianWidth.txt
    wide_ranges = parse_ranges(eaw_path, {"W", "F"})
    wide_cps = codepoints_from_ranges(wide_ranges)
    
    # 2. Parse Emoji_Presentation from emoji-data.txt
    emoji_presentation_ranges = parse_ranges(emoji_path, {"Emoji_Presentation"})
    emoji_cps = codepoints_from_ranges(emoji_presentation_ranges)
    
    # 3. Optimize: remove Wide/Fullwidth codepoints from emoji-presentation to shrink the array
    emoji_only_cps = emoji_cps - wide_cps
    
    # 4. Convert back to merged ranges
    final_wide_ranges = codepoints_to_merged_ranges(wide_cps)
    final_emoji_ranges = codepoints_to_merged_ranges(emoji_only_cps)
    
    # 5. Read target Zig source file
    if not os.path.exists(TARGET_FILE):
        print(f"Error: Target file {TARGET_FILE} not found.", file=sys.stderr)
        sys.exit(1)
        
    with open(TARGET_FILE, "r", encoding="utf-8") as f:
        orig_content = f.read()
        
    # Backup original content
    backup_content = orig_content
    
    # 6. Format the new arrays
    wide_array_str = generate_zig_array(final_wide_ranges)
    emoji_array_str = generate_zig_array(final_emoji_ranges)
    
    # 7. Replace the arrays using regex
    # Match: const wide_ranges = [_]WidthRange{ ... };
    wide_pattern = r"(const wide_ranges = \[\_\]WidthRange\{)(.*?)(\};)"
    new_content, count1 = re.subn(wide_pattern, rf"\g<1>{wide_array_str}\g<3>", orig_content, flags=re.DOTALL)
    
    # Match: const emoji_presentation_ranges = [_]WidthRange{ ... };
    emoji_pattern = r"(const emoji_presentation_ranges = \[\_\]WidthRange\{)(.*?)(\};)"
    new_content, count2 = re.subn(emoji_pattern, rf"\g<1>{emoji_array_str}\g<3>", new_content, flags=re.DOTALL)
    
    if count1 == 0 or count2 == 0:
        print(f"Error: Could not locate wide_ranges or emoji_presentation_ranges arrays in {TARGET_FILE}", file=sys.stderr)
        sys.exit(1)
        
    # Write to TARGET_FILE
    with open(TARGET_FILE, "w", encoding="utf-8") as f:
        f.write(new_content)
        
    print(f"Successfully updated {TARGET_FILE} in-place.")
    print(f"Generated {len(final_wide_ranges)} wide ranges and {len(final_emoji_ranges)} emoji presentation ranges.")
    
    # 8. Run tests to verify the correctness of the new width table
    print("Running zig test...")
    res = subprocess.run(["zig", "test", TARGET_FILE], capture_output=True, text=True)
    if res.returncode != 0:
        print("Zig tests failed! Reverting changes...", file=sys.stderr)
        print(res.stderr, file=sys.stderr)
        with open(TARGET_FILE, "w", encoding="utf-8") as f:
            f.write(backup_content)
        sys.exit(1)
        
    print("All tests passed successfully!")

if __name__ == "__main__":
    main()
