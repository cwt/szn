# szn — TODO

## 1. Text Reflow

Reflow rewraps text when the terminal pane is resized, so long lines adjust
to the new width instead of being truncated.

### Phase 1: Track soft-wrap lines (done)

- [x] Add `wrapped: bool` to `GridLine` in `src/grid.zig`
  - `true` = this line is a continuation from the previous line (auto-wrap)
  - `false` = this line starts fresh (user pressed Enter / `\n`)
- [x] Hook into `Screen.writeChar` in `src/screen.zig`
  - When auto-wrapping (cursor hits right edge, line_wrap on): mark the
    **new** line as `wrapped = true`
  - When processing `\n`: ensure the next line written has `wrapped = false`
  - When the user backspaces from column 0 to the previous line end:
    clear `wrapped` on the line being vacated
- [x] Hook into history: `scrollUp` should preserve `wrapped` flag on the
  line going into history
- [x] Regression test: `\n` at col 0 of already-empty line should not toggle wrapped

### Phase 2: Thai cluster detection (done — `src/thai.zig`)

Thai script (U+0E00–U+0E7F) has base consonants and combining marks.
Clusters must not be split across lines.

Implemented in `src/thai.zig`:

- [x] `isThai(cp: u21) bool` — range check U+0E00–U+0E7F
- [x] `isThaiCombining(cp: u21) bool`
  - Marks with General Category `Mn` in Thai range (16 marks):
    SARA U (◌ุ U+0E38), SARA UU (◌ู), PHINTHU (◌ฺ U+0E3A),
    MAI HAN-AKAT (◌ั U+0E31), SARA I (◌ิ), SARA II (◌ี),
    SARA UE (◌ึ), SARA UEE (◌ื),
    MAITAIKHU (◌็), MAI EK (◌่), MAI THO (◌้),
    MAI TRI (◌๊), MAI CHATTAWA (◌๋), THANTHAKHAT (◌์),
    NIKHAHIT (◌ํ), YAMAKKAN (◌๎)
  - **Not** combining: FONGMAN (U+0E4F, Po punctuation), SARA AM (U+0E33, Lo vowel)
  - SARA E/AE/O/AI MAIMUAN/AI MAIMALAI (U+0E40–U+0E44) were incorrectly listed
    as combining in the original spec — they are **leading vowels** (width 1,
    appear before the base)
- [x] `isThaiLeadingVowel(cp: u21) bool` — U+0E40–U+0E44 (added; not in original TODO)
- [x] `isThaiFollowingVowel(cp: u21) bool` — U+0E30, U+0E32, U+0E33, U+0E45
  (+ U+0E45 LAKKHANGYAO (ๅ) — vowel length marker, acts like SARA AA)
- [x] `isThaiRightAttaching(cp: u21) bool` — U+0E2F PAIYANNOI (ฯ),
  U+0E46 MAI YAMOK ( ๆ); these occupy their own cell but are consumed
  into the preceding cluster so reflow never splits them off
- [x] `isThaiBase(cp: u21) bool` — Thai, width 1, not combining/leading/following/attaching
- [x] `findThaiClusterEnd(line: []Cell, start: usize) usize`
  - Walks: `[leading vowel]`? → `base` → `[following vowel]`? → `[right-attaching marks]*`
  - Combining marks are stored in `comb1`/`comb2` of the base/following-vowel
    cell (not as separate cells), so they don't affect the span
  - Returns start + 1 if start is not a valid cluster start

### Phase 3: Reflow algorithm — width shrink (done)

When `grid.setSize` is called with a narrower width, visible lines must
be reflowed: text that wrapped at e.g. col 80 now wraps at col 60.

- [x] Implement `reflowShrink(grid, new_width)`
  - Walk visible lines top to bottom
  - For each line, determine the "logical line" by following `wrapped` flags:
    collect consecutive lines where line[N+1].wrapped = true
  - Flatten the logical line into a single cell sequence
  - Re-wrap the sequence to `new_width`, respecting:
    - Never break inside a Thai cluster
    - Never split a 2-wide CJK character (char + padding pair)
    - Never split a base char from its combining marks
    - Tab stops recalibrated to new width
    - Preserve per-cell colour/attr/SGR state through the rewrap
  - Write the new shorter-but-more-numerous lines back into `grid.lines`
  - Spill excess lines into history if the new visible area can't fit them all
- [x] Also process `grid.history` lines

### Phase 4: Reflow algorithm — width grow (done)

When width grows, adjacent wrapped lines can join back together.

- [x] Implement `reflowGrow(grid, new_width)`
  - Walk lines bottom to top (reverse, to pull content up)
  - When `line.wrapped == true`: try to merge cells from line into the
    end of the previous line if there's room at `new_width`
  - After merging, the emptied line becomes a blank line
  - Handle: a blank line may need to be filled by pulling up content
    from history or the line below
  - Same cluster/CJK integrity rules as shrink

### Phase 5: Edge cases (done)

- [x] **Scroll regions**: lines inside an active scroll region should not pull/push
      cells from outside the region during reflow
- [x] **Alternate screen**: alt_grid also needs reflow; but alt screen
      programs (vim, less) typically redraw on SIGWINCH anyway, so maybe
      skip reflow for alt grid and just truncate
- [x] **Cursor repositioning programs**: apps like dialog, tui progress bars,
      columnar output get corrupted by reflow. Consider a heuristic:
      if a line was written by cursor-motion (not sequential flow), don't reflow it.
      One approach: track `last_write_mode` per line (sequential vs random-access).
- [x] **Tab recalculation**: when width changes, tabs at fixed positions (every 8)
      shift. Reflow should re-expand tabs to the new grid positions.
- [x] **Performance**: O(n*m) could be slow with 2000+ history lines.
      Cap reflow to visible area + N history lines (configurable).
      Batch dirty-marking to avoid per-cell flag updates.
- [x] **Double-width line**: CJK wide chars at the last column—wrapping must
      move the whole 2-cell char to the next line, not split it.

### Phase 6: Thai line-breaking rules (done)

Beyond cluster integrity, Thai text needs line-breaking at appropriate
boundaries since Thai has no spaces between words.

- [x] Implement Thai-specific line-break rules (subset of UAX #14 / TIS-620):
  - **Never start a line with**: SARA AM (ำ U+0E33), MAI TA KHU (ๆ U+0E46),
    MAI YAMOK, any Thai combining mark
  - **Never end a line with**: SARA E (เ U+0E40), SARA AE (แ U+0E41),
    SARA O (โ U+0E42), SARA AI MAIMUAN (ใ U+0E43),
    SARA AI MAIMALAI (ไ U+0E44) — these are leading vowels
  - **Prefer breaking at**: spaces (of course), between Thai/non-Thai script
    boundaries, after SARA A (า), after tone marks
- [x] Add these as `reflowBreakAllowed(cell_before: Cell, cell_after: Cell) bool`
  - Called during the re-wrap phase to decide if a break point is valid
  - If the only valid break at current column is inside a forbidden spot,
    push the entire cluster to the next line (widow protection)
- [x] Write test cases:
  - `"ทำดีที่สุด"` at width 3 → must not split ทำ or ดี or ที่ or สุด
  - `"แล้วก็ไป"` at width 4 → valid breaks: แล้ว|ก็ไป / แล้วก็|ไป
  - Mixed Thai/ASCII: `"hello สวัสดี world"` → can break at space boundaries

### Test plan

- [x] Unit tests in `grid.zig`: reflow with simple ASCII wrapping
- [x] Unit tests in `screen.zig`: writeChar marks wrapped correctly, \n clears it
- [x] Unit tests for Thai clusters: cluster detection edge cases
- [x] Integration test: simulate terminal output, resize pane, verify text integrity
- [x] Fuzz test: random sequence of writes + resizes, assert no panics, no cell corruption
