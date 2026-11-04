export as namespace opentype;

export type BufferLike = ArrayBuffer | ArrayBufferView | ArrayLike<number>;

export type LocalizedStrings = Record<string, string>;

export type StandardName =
    | 'copyright'
    | 'fontFamily'
    | 'fontSubfamily'
    | 'uniqueID'
    | 'fullName'
    | 'version'
    | 'postScriptName'
    | 'trademark'
    | 'manufacturer'
    | 'designer'
    | 'description'
    | 'manufacturerURL'
    | 'designerURL'
    | 'license'
    | 'licenseURL'
    | 'reserved'
    | 'preferredFamily'
    | 'preferredSubfamily'
    | 'compatibleFullName'
    | 'sampleText'
    | 'postScriptFindFontName'
    | 'wwsFamily'
    | 'wwsSubfamily';

export type FontNames =
    Partial<Record<StandardName, LocalizedStrings>> & {
        [nameId: string]: LocalizedStrings | undefined;
        [nameId: number]: LocalizedStrings | undefined;
    };

export interface HeadTable {
    version: number;
    fontRevision: number;
    checkSumAdjustment: number;
    magicNumber: number;
    flags: number;
    unitsPerEm: number;
    created: number;
    modified: number;
    xMin: number;
    yMin: number;
    xMax: number;
    yMax: number;
    macStyle: number;
    lowestRecPPEM: number;
    fontDirectionHint: number;
    indexToLocFormat: number;
    glyphDataFormat: number;
}

export interface HheaTable {
    version: number;
    ascender: number;
    descender: number;
    lineGap: number;
    advanceWidthMax: number;
    minLeftSideBearing: number;
    minRightSideBearing: number;
    xMaxExtent: number;
    caretSlopeRise: number;
    caretSlopeRun: number;
    caretOffset: number;
    metricDataFormat: number;
    numberOfHMetrics: number;
}

export interface FontTables {
    head?: HeadTable;
    hhea?: HheaTable;
    [tag: string]: unknown;
}

export class Font {
    constructor();
    tables: FontTables;
    names: FontNames;
    ascender: number | null;
    descender: number | null;
    unitsPerEm: number | null;
}

export function parse(buffer: BufferLike): Font;

declare const _default: {
    parse: typeof parse;
    Font: typeof Font;
};

export default _default;
