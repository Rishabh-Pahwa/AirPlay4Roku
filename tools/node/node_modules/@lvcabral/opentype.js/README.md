# opentype.js (parse only)

This fork contains a light-weight version of `opentype.js` that only parses OpenType/TrueType/WOFF font buffers and returns metadata. There are no drawing helpers, glyph constructors, or layout utilities—`parse()` is the entire public API.

## Installation

```sh
npm install @lvcabral/opentype.js
```

## Usage

```js
import { readFileSync } from 'fs';
import { parse } from '@lvcabral/opentype.js';

const data = readFileSync('./test/fonts/Roboto-Black.ttf');
const font = parse(data);

console.log(font.unitsPerEm);           // 2048
console.log(font.ascender, font.descender);
console.log(font.tables.head.macStyle);
console.log(font.names.fontFamily.en);
```

The returned `Font` object exposes:

- `unitsPerEm`, `ascender`, `descender`
- `tables.head` and `tables.hhea` objects exactly as they appear in the font tables
- `names`, keyed by name ID (e.g. `font.names.fullName`) with locale entries (BCP-47 tags when available, otherwise the raw `0x####` language ID).

Unsupported table data is ignored. If a required table (`head` or `hhea`) is missing the parser throws.

## Formats

- TrueType and OpenType fonts (`\x00\x01\x00\x00`, `true`, `typ1`, `OTTO`)
- WOFF containers (tables are decompressed automatically)
- Format 0/1 `name` tables encoded in UTF-16

## Development

- `npm run build` – bundles `src/opentype.mjs` into `dist/opentype.module.js` (ESM) and `dist/opentype.js` with sourcemaps for local debugging
- `npm run dist` – produces the minified distributables `dist/opentype.module.min.js` and `dist/opentype.min.js` (with sourcemaps)
- `npm test` – runs the minimal Mocha suite that loads sample fonts and asserts metadata
- `npm run lint` – ESLint over the `src/` directory

The parser lives in `src/opentype.mjs` and only depends on:

- `src/parse.mjs` for DataView helpers
- `src/tables/{head,hhea,name}.mjs`
- `src/tiny-inflate@1.0.3.esm.mjs` for WOFF decompression

Test fonts are stored in `test/fonts/`. Published consumers load from the generated `dist/` artifacts (`main`/`module` point there).

## Versioning

We use [SemVer](https://semver.org/) for versioning.

## License

MIT

Thanks
======
We would like to acknowledge the work of others without which opentype.js wouldn't be possible:

* [pdf.js](https://mozilla.github.io/pdf.js/): for an awesome implementation of font parsing in the browser.
* [FreeType](https://www.freetype.org/): for the nitty-gritty details and filling in the gaps when the spec was incomplete.
* [ttf.js](https://ynakajima.github.io/ttf.js/demo/glyflist/): for hints about the TrueType parsing code.
* [CFF-glyphlet-fonts](https://pomax.github.io/CFF-glyphlet-fonts/): for a great explanation/implementation of CFF font writing.
* [fontkit](https://github.com/foliojs/fontkit/): for a great implementation of CFF2 parsing and variable font features
* [tiny-inflate](https://github.com/foliojs/tiny-inflate): for WOFF decompression.
* [Microsoft Typography](https://docs.microsoft.com/en-us/typography/opentype/spec/otff): the go-to reference for all things OpenType.
* [Adobe Compact Font Format spec](http://download.microsoft.com/download/8/0/1/801a191c-029d-4af3-9642-555f6fe514ee/cff.pdf) and the [Adobe Type 2 Charstring spec](http://download.microsoft.com/download/8/0/1/801a191c-029d-4af3-9642-555f6fe514ee/type2.pdf): explains the data structures and commands for the CFF glyph format.
* All [contributors](https://github.com/opentypejs/opentype.js/graphs/contributors).
