# KanaRomaji

Converts Japanese text typed on an iPhone (one `UIKeyInput.insertText` chunk at a time) into the
ASCII characters that, typed as HID keystrokes into a Mac or Windows PC whose Japanese IME is in
**hiragana / romaji input mode with the default romaji table**, make the host IME compose the
same kana. The user then converts (Space) and commits (Return) on the host.

Pure Swift, Foundation only, Swift 6 language mode. Two source files, no dependencies.

```swift
let c = KanaRomaji.convert("きゃ")              // per-kana (default)
c.keys                                           // "kixya"
c.segments                                       // [Segment(kind: .ime, keys: "kixya", ...)]
KanaRomaji.convert("きゃ", mode: .natural).keys  // "kya"
KanaRomaji.classify("漢字です")                   // .partiallySendable
KanaRomaji.romaji(for: "ッ")                     // "xtu"
```

## API

| Symbol | Purpose |
|---|---|
| `convert(_:mode:) -> Conversion` | Converts a chunk. `mode` is `.perKana` (default) or `.natural`. |
| `Conversion.segments: [Segment]` | Runs to type in order. `Segment.kind` is `.ime` (IME on), `.direct` (IME off, ASCII passthrough) or `.space` (the Space key with the IME on, from U+3000). Each has `keys`, `characterRange` (grapheme offsets) and `utf16Range` (NSRange offsets). |
| `Conversion.unconvertible: [Unconvertible]` | Dropped characters: `character`, `characterOffset`, `utf16Offset`, `reason` (`.kanji`, `.emoji`, `.iterationMark`, `.noReliableKey`, `.control`, `.unsupportedScript`). |
| `Conversion.approximations: [Approximation]` | Characters that are sent but will not appear exactly as typed (full-width `Ａ` sent as `A` with the IME off; `ゕ` shown as `ヵ`). |
| `Conversion.keys`, `.isComplete`, `.inputClass` | Convenience. `keys` ignores segment kinds: use `segments` for mixed chunks. |
| `classify(_:) -> InputClass` | `.empty`, `.kanaLike` (needs IME on), `.asciiLike` (needs IME off), `.mixed` (both), `.partiallySendable`, `.unsendable` (kanji, emoji, ...). |
| `mapping(for:) -> CharacterMapping` | Per-character detail: `.ime(keys)`, `.direct(keys)`, `.space`, `.approximate(keys:kind:note:)`, `.unconvertible(reason)`. |
| `romaji(for:) -> String?` | Per-kana keys of one character, `nil` unless it is typed exactly with the IME on. |

Output is **characters, not key codes**. Mapping `[`, `@`, `~`, `_`, `|`, `:` ... to HID usages
(and Shift) depends on the keyboard layout the host assumes for the phone (US vs JIS) and is the
caller's job. `.ime` keys never contain uppercase letters (on the Mac, Shift switches the input
mode).

## Two modes

**Per-kana (`.perKana`, default) — for live typing.** Each character becomes a self-contained
spelling: typed alone into an empty composition it yields exactly that one kana and leaves
nothing pending in the IME's romaji buffer. So the keys of a string are the concatenation of the
keys of its characters, and one host Backspace removes what one phone character added. Small kana
always use explicit `x` forms, ん is `nn`, っ is `xtu`. The flick keyboard's ゛/小 key
(`deleteBackward` + `insertText`) therefore maps to one Backspace + the new spelling.

**Natural (`.natural`) — for paste / send-text.** Digraphs (きゃ → `kya`, ふぁ → `fa`,
てぃ → `thi`) and doubled consonants (っか → `kka`, っちゃ → `ccha`). っ before a vowel, ん,
another っ, a symbol, the end of the string or a non-kana stays `xtu`. ん is always `nn`. The
host result is identical, but characters no longer map 1:1 to key runs, so do not use it for
keystroke-by-keystroke typing.

Both modes are tested by replaying the keys through two independent romaji-IME models (see
Tests) and checking that the host composes the input kana.

## Mapping tables (per-kana)

Katakana (full-width and half-width) is typed as the romaji of the matching hiragana. **The host
composes hiragana**; the user converts to katakana on the host (Space, or F7 on Windows /
Control-K on the Mac — *from memory*). Half-width katakana with ﾞ/ﾟ (one grapheme, e.g. `ｶﾞ`) is normalised
first (ｶﾞ → ガ → `ga`); combining U+3099/U+309A after hiragana is NFC-composed.

| Row | Kana | Keys |
|---|---|---|
| あ | あ い う え お | a i u e o |
| か が | か き く け こ / が ぎ ぐ げ ご | ka ki ku ke ko / ga gi gu ge go |
| さ ざ | さ し す せ そ / ざ じ ず ぜ ぞ | sa shi su se so / za ji zu ze zo |
| た だ | た ち つ て と / だ ぢ づ で ど | ta chi tsu te to / da di du de do |
| な | な に ぬ ね の | na ni nu ne no |
| は ば ぱ | は ひ ふ へ ほ / ば… / ぱ… | ha hi fu he ho / ba bi bu be bo / pa pi pu pe po |
| ま | ま み む め も | ma mi mu me mo |
| や | や ゆ よ | ya yu yo |
| ら | ら り る れ ろ | ra ri ru re ro |
| わ | わ ゐ ゑ を ん | wa wyi wye wo nn |
| ゔ | ゔ (ヴ, ｳﾞ) | vu |
| small | ぁ ぃ ぅ ぇ ぉ | xa xi xu xe xo |
| small | っ ゃ ゅ ょ ゎ | xtu xya xyu xyo xwa |
| small | ヵ ヶ (and hiragana ゕ ゖ, approximated) | xka xke |
| long | ー (ｰ) | - |

Natural-mode digraphs (all present with the same meaning in both IMEs' tables):
`Cy`+vowel for き ぎ に ひ び ぴ み り ぢ (kya, kyi, kyu, kye, kyo ...); しゃ sha, しぃ syi,
しゅ shu, しぇ she, しょ sho; じゃ ja, じぃ jyi, じゅ ju, じぇ je, じょ jo; ちゃ cha, ちぃ cyi,
ちゅ chu, ちぇ che, ちょ cho; てゃ…てょ tha thi thu the tho; でゃ…でょ dha dhi dhu dhe dho;
とぁ…とぉ twa twi twu twe two; どぁ…どぉ dwa … dwo; つぁ tsa, つぃ tsi, つぇ tse, つぉ tso;
ふぁ fa, ふぃ fi, ふぅ fwu, ふぇ fe, ふぉ fo, ふゃ fya, ふゅ fyu, ふょ fyo; うぁ wha, うぃ wi,
うぇ we, うぉ who, いぇ ye; ゔぁ va, ゔぃ vi, ゔぇ ve, ゔぉ vo, ゔゃ vya, ゔゅ vyu, ゔょ vyo;
くぁ qa, くぃ qwi, くぅ qwu, くぇ qwe, くぉ qwo, くゃ qya, くゅ qyu, くょ qyo; ぐぁ…ぐぉ gwa …
gwo; すぁ…すぉ swa … swo.

### Punctuation, symbols, digits, space

| Phone char | Keys | Mode | Notes / setting dependence |
|---|---|---|---|
| 、 。 (､ ｡) | `,` `.` | IME | 句読点 setting on both IMEs; default 「、。」. With ，． configured the host shows those instead. |
| ・ (･) | `/` | IME | Mac: "“/”キーで入力する文字" (・ or /) setting, documented for JIS keyboards; MS IME: 記号 setting, default 「」・. |
| 「 」 (｢ ｣) | `[` `]` | IME | MS IME 記号 setting can make these ［］. |
| ー | `-` | IME | Prolonged sound mark on both. |
| 〜 ～ | `~` | IME | Mac gives 〜 (U+301C), MS IME gives ～ (U+FF5E). *From memory.* |
| ？ ！ （ ） ： ； ＠ ＃ ＄ ％ ＆ ＊ ＋ ＝ ＿ ｜ ＜ ＞ | ASCII equivalent | IME | Full-width in hiragana mode by default. *From memory.* |
| ０–９ | `0`–`9` | IME | Width is a setting: Mac "数字を全角入力"; MS IME default full-width in hiragana mode (*memory*). Lands in the composition. |
| 　 (U+3000) | Space | `.space` | With an open composition Space **converts**; with none it inserts a space (width per host setting, *from memory*). Caller decides. |
| ASCII (incl. space, `\t`, `\n`) | unchanged | direct | Type with the IME off. |
| Ａ–Ｚ ａ–ｚ ／ － ， ． ＾ ＂ ＇ ｛ ｝ ＼ ` and other full-width ASCII forms | ASCII equivalent | direct, *approximation* | No IME-on key gives these under default settings (`/` gives ・, `-` gives ー, `,` gives 、). Sent half-width with the IME off. |

### Unconvertible

| Characters | Reason |
|---|---|
| Kanji (incl. 〆 〇, CJK extensions) | `.kanji` — only its reading can be typed. |
| Emoji (incl. keycaps, ZWJ sequences, flags, ❤️) | `.emoji` |
| 々 〃 ゝ ゞ ヽ ヾ 〻 | `.iterationMark` — no romaji in either table (type a reading and convert). |
| 『 』 … ‥ 【 】 ※ 〒 “ ” → ☆ ¥ ￥ and other symbols | `.noReliableKey` — reached by converting a reading or by IME-specific keys (Mac: Option-; for …, Option-8/9 for 【】, `zh/zj/zk/zl` for ←↓↑→; not in Microsoft's table). |
| ヷ ヸ ヹ ヺ, lone ゛ ゜ ﾞ ﾟ U+3099/309A, ｱﾞ (no voiced form), ゟ, ㇰ… | `.noReliableKey` |
| Control/format characters (BEL, ZWSP, ...) | `.control` |
| Other scripts (é, 한, ...) | `.unsupportedScript` |

## Differences between Apple and Microsoft IME (from the sources)

The first three rows are the complete mechanical diff of the two oracle tables (pinned by
`OracleSanityTests.completeTableDifference`). The library emits none of the one-sided or
conflicting spellings except the v-row, whose only difference is the script of ゔ/ヴ.

| Keys | Apple [A] | Microsoft [M1]/[M2] | Library |
|---|---|---|---|
| Apple only: `hwa hwi hwe hwo`, `kwi kwu kwe kwo` | ふぁ ふぃ ふぇ ふぉ, くぃ くぅ くぇ くぉ | not listed | Not used. |
| Microsoft only: `ca ci cu ce co`, `yi`, `wu whu`, `lyi xyi`, `vyi vye` | not listed | か し く せ こ, い, う う, ぃ ぃ, ヴぃ ヴぇ | Not used. |
| Same keys, different kana: `qu`, `qwa`, `va vi vu ve vo vya vyu vyo` | くぅ, くゎ, ゔぁ ゔぃ ゔ ゔぇ ゔぉ ゔゃ ゔゅ ゔょ | く, くぁ, ヴぁ ヴぃ ヴ ヴぇ ヴぉ ヴゃ ヴゅ ヴょ | `qu`/`qwa` not used (くぁ → `qa`, くぅ → `qwu`, くゎ → `ku`+`xwa`). v-row used: same sound, host-dependent script; a difference, not a failure. |
| `n` + consonant | not documented | ん ([M2] "子音の前のみ n") | Not used; ん is always `nn`. |
| `wyi` `wye` | ゐ ゑ | ゐ ゑ in [M1] (2016); not typeable in MS-IME 2000 [M2] | Used. ゐ/ゑ are convertible. |
| `xka` `xke` | ヵ ヶ | ヵ ヶ | Used. Both give **katakana**, so hiragana ゕ/ゖ are approximations. |
| `~` | 〜 (*memory*) | ～ (*memory*) | Used for both 〜 and ～. |

## Assumptions

- Host IME is on, in **hiragana mode with romaji input** and the **default romaji table**
  (no custom romaji table edits, Google Japanese Input / ATOK not assumed).
- Host "kana input" (かな入力) mode is **not supported**.
- Default punctuation/symbol settings (、。 and 「」・).
- The caller maps the output characters to HID usages for the layout the host uses for the phone.

## Caller guidance

- **Intercept the phone's space and return keys first.** A lone `" "` (U+0020), `"\u{3000}"` and
  `"\n"` from `insertText` are key presses, not text: route them to the Space / Return handling
  below *before* calling `classify`/`convert`. The library itself treats ASCII space, tab and
  newline as ordinary `.direct` ASCII (so `"かな\n"` is `.mixed`), which would otherwise make a
  caller commit and switch the IME off on every space or return.
- **Mode switching.** `.ime` and `.space` segments need the host IME on; `.direct` segments need
  it off. Everything typed with the IME on lands in the composition, including punctuation and
  digits. **Commit (Return) before switching the IME off**, otherwise the host may commit,
  discard or convert the pending text depending on the IME. A chunk of `.partiallySendable` /
  `.unsendable` text (kanji picked from iOS predictions, emoji) cannot be typed: show the user
  that it was dropped (`unconvertible` has grapheme and UTF-16 offsets).
- **`deleteBackward`.** In per-kana mode, each phone character that produced a segment adds
  exactly one character on the host, so send one Backspace per deleted phone character. Keep a
  shadow of what was actually sent (0 host characters for dropped ones) and send no Backspace
  for characters that were never sent. This holds while the host text is an unconverted
  composition; after Space (conversion) the host composition is a converted clause and Backspace
  semantics differ per IME, so treat the shadow as unknown until the next commit.
- **Space (convert).** Send the Space key while a composition is open to convert; repeat to cycle
  candidates. A phone-side U+3000 arrives as a `.space` segment: the caller decides whether it
  means "convert" or "insert a space".
- **Return (commit).** Return commits the composition; with an empty composition it is a newline.
  The caller should track whether the composition is non-empty (shadow count > 0).
- **macOS Live Conversion (ライブ変換)** converts while typing. Composition/Backspace behaviour
  with it on has not been verified; consider asking users to turn it off.

## Sources and verification status

- **[A] Apple, primary, full table, read as text** — "Macの日本語での英字とかなの対応",
  日本語入力プログラムユーザガイド 6.3:
  <https://support.apple.com/ja-jp/guide/japanese-input-method/jpim10277/mac> (fetched 2026-11-17).
  The test oracle `Tests/KanaRomajiTests/AppleRomajiTable.swift` was generated from this page's
  text by a throwaway Python script (277 cells; the script is not part of the package, so treat
  the file as a checked-in snapshot). Apple settings page for 句読点の種類, "/" key, "¥" key and
  数字を全角入力: <https://support.apple.com/ja-jp/guide/japanese-input-method/jpim662a12b9/mac>.
  Symbol shortcuts (Option-; for …): <https://support.apple.com/ja-jp/guide/japanese-input-method/jpim10286/mac>.
- **[M1] Microsoft, primary but partial, read from an image** — Windows Blog for Japan,
  2016-09-27, section "いまさら聞けないローマ字入力":
  <https://blogs.windows.com/japan/2016/09/27/jpimetips3/>, image
  <https://blogs.windows.com/wp-content/uploads/prod/sites/31/2016/09/romaji1.png>. Covers small
  kana, っ, ゎ, ゐ, ゑ, ん, ヵ, ヶ, ヴ rows and digraphs; not the basic rows.
- **[M2] Third party, old** — "ローマ字とかな対応一覧（MS-IME 2000）", handout hosted at
  <https://www.chiba-kc.ac.jp/user/~iseri/siryo/romakana.pdf>. Used for Microsoft's basic rows
  (shi, chi, tsu, fu, ji, ...) and the `n`-before-consonant / doubled-consonant notes.
- No Microsoft support.microsoft.com page with the romaji table was found.
- **From memory (not found in a primary source):** Microsoft IME's default 句読点 「、。」 and
  記号 「」・ settings; that `? ! ( ) : ; @ # $ % & * + = _ | < >` give full-width forms in
  hiragana mode on both; `~` → 〜 (Mac) vs ～ (Windows); MS IME digit width default; Space
  behaviour with an empty composition; Mac `/` → ・ with a US layout.
- **Not verified on real hosts.** All checks are against the published tables via the test
  oracle, not against running IMEs. Worth checking on hardware: `xtu`, `nn`, `wyi`, `wye`, `vu`,
  `cchi`/`ccha` (doubled `c`), the symbol table, and Live Conversion.

## Known gaps

- No IME-mode key for 『』 … 【】 and similar; they are reported, not typed.
- Full-width letters and ／ － ， ． are approximated as half-width ASCII.
- Custom romaji tables, kana input mode, AZIK, Google Japanese Input and ATOK are not modelled.
- IME on/off switching keys, HID usages and keyboard layouts are out of scope.

## Tests

`swift test` runs:
- reviewable per-character tables for every supported character, every approximation and every
  unconvertible class, plus a check that every code point in the hiragana, katakana and
  half-width katakana blocks is accounted for;
- a round-trip oracle: an incremental romaji-IME model (waits on prefixes, doubled consonant →
  っ, emits on full match, reports leftover keys) run with the Apple table [A] and a hand
  transcription of [M1]+[M2]; every IME character, every pair of characters (per-kana), every
  natural digraph and っ before every character, in both IMEs;
- a check that no table key strictly extends a per-kana spelling (nothing left pending);
- a corpus of 98 words and sentences with hand-written natural keys, round-tripped in both modes;
- mixed kana/ASCII/kanji/emoji chunks with grapheme and UTF-16 offsets, empty input, and the
  classifier.
