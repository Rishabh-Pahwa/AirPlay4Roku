# sprintf-js

[![NPM Version](https://img.shields.io/npm/v/%40lvcabral%2Fsprintf)](https://www.npmjs.com/package/@lvcabral/sprintf)
[![License BSD 3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](./LICENSE)

**sprintf-js** is a complete open source JavaScript `sprintf` implementation for the **browser** and **Node.js**.

> This is a fork of the original [sprintf-js](https://github.com/alexei/sprintf.js) and adds support to:
>
> - 64bit hex formatting
> - Asterisk (*) width and precision
> - Floating point default precision
> - Improved `g` formatting to be closer to `C` implementation
> - `NaN`, infinity and `-0` formatted like `C` (`nan`, `-nan`, `inf`, `-inf`, `-0.000000`) by the float conversions
> - The space and `#` flags, flags in any order, and the `a`, `A`, `E`, `F` and `G` conversions

## Usage

    import { sprintf, vsprintf } from "@lvcabral/sprintf";

    sprintf('%2$s %3$s a %1$s', 'cracker', 'Polly', 'wants')
    vsprintf('The first 4 letters of the english alphabet are: %s, %s, %s and %s', ['a', 'b', 'c', 'd'])

## Installation

### NPM

    npm install @lvcabral/sprintf

### Yarm

    yarn add @lvcabral/sprintf

## API

### `sprintf`

Returns a formatted string:

    string sprintf(string format, mixed arg1?, mixed arg2?, ...)

### `vsprintf`

Same as `sprintf` except it takes an array of arguments, rather than a variable number of arguments:

    string vsprintf(string format, array arguments?)

## Format specification

The placeholders in the format string are marked by `%` and are followed by one or more of these elements, in this order (the flags — sign, padding, `-` and `#` — can come in any order between them):

- An optional number followed by a `$` sign that selects which argument index to use for the value. If not specified, arguments will be placed in the same order as the placeholders in the input string.
- An optional `+` sign that forces to precede the result with a plus or minus sign on numeric values. By default, only the `-` sign is used on negative numbers. A space instead of the `+` puts a space before non-negative numbers.
- An optional padding specifier that says what character to use for padding (if specified). Possible values are `0` or any other character preceded by a `'` (single quote). The default is to pad with *spaces*.
- An optional `-` sign, that causes `sprintf` to left-align the result of this placeholder. The default is to right-align the result. As in C, it overrides `0` padding.
- An optional `#` sign for the alternate form: `0x`, `0X`, `0b` or `0` before non-zero `x`, `X`, `b` and `o` values, a decimal point always written by the float conversions, and trailing zeros kept by `g` and `G`.
- An optional number, that says how many characters the result should have. If the value to be returned is shorter than this number, the result will be padded. When used with the `j` (JSON) type specifier, the padding length specifies the tab size used for indentation.
- An optional precision modifier, consisting of a `.` (dot) followed by a number, that says how many digits should be displayed for floating point numbers. When used with the `g` type specifier, it specifies the number of significant digits. When used on a string, it causes the result to be truncated.
- An optional `*` (asterisk) modifier that specifies the width and precision of the field.
- A type specifier that can be any of:
  - `%` — yields a literal `%` character
  - `a` — yields a float as a hexadecimal number with a binary exponent, like `0x1.8p+1`; `A` writes it in upper-case
  - `b` — yields an integer as a binary number
  - `c` — yields an integer as the character with that ASCII value
  - `d` or `i` — yields an integer as a signed decimal number
  - `e` — yields a float using scientific notation; `E` writes it in upper-case
  - `u` — yields an integer as an unsigned decimal number
  - `f` — yields a float as is; see notes on precision above; `F` writes `NaN` and infinity in upper-case
  - `g` — yields a float as is; see notes on precision above; `G` writes it in upper-case
  - `o` — yields an integer as an octal number
  - `s` — yields a string as is
  - `t` — yields `true` or `false`
  - `T` — yields the type of the argument<sup><a href="#fn-1" name="fn-ref-1">1</a></sup>
  - `v` — yields the primitive value of the specified argument
  - `x` — yields an integer as a hexadecimal number (lower-case)
  - `X` — yields an integer as a hexadecimal number (upper-case)
  - `j` — yields a JavaScript object or array as a JSON encoded string

## Features

### Argument swapping

You can also swap the arguments. That is, the order of the placeholders doesn't have to match the order of the arguments. You can do that by simply indicating in the format string which arguments the placeholders refer to:

    sprintf('%2$s %3$s a %1$s', 'cracker', 'Polly', 'wants')

And, of course, you can repeat the placeholders without having to increase the number of arguments.

### Named arguments

Format strings may contain replacement fields rather than positional placeholders. Instead of referring to a certain argument, you can now refer to a certain key within an object. Replacement fields are surrounded by rounded parentheses - `(` and `)` - and begin with a keyword that refers to a key:

    var user = {
        name: 'Dolly',
    }
    sprintf('Hello %(name)s', user) // Hello Dolly

Keywords in replacement fields can be optionally followed by any number of keywords or indexes:

    var users = [
        {name: 'Dolly'},
        {name: 'Molly'},
        {name: 'Polly'},
    ]
    sprintf('Hello %(users[0].name)s, %(users[1].name)s and %(users[2].name)s', {users: users}) // Hello Dolly, Molly and Polly

Note: mixing positional and named placeholders is not (yet) supported

### Computed values

You can pass in a function as a dynamic value and it will be invoked (with no arguments) in order to compute the value on the fly.

    sprintf('Current date and time: %s', function() { return new Date().toString() })

## Support

### Node.js

`sprintf-js` runs in all active Node versions (4.x+).

### Browser

`sprintf-js` should work in all modern browsers. As of v1.1.1, you might need polyfills for the following:

 - `String.prototype.repeat()` (any IE)
 - `Array.isArray()` (IE < 9)
 - `Object.create()` (IE < 9)

YMMV

## License

**sprintf-js** is licensed under the terms of the BSD 3-Clause License.

## Notes

<small><sup><a href="#fn-ref-1" name="fn-1">1</a></sup> `sprintf` doesn't use the `typeof` operator. As such, the value `null` is a `null`, an array is an `array` (not an `object`), a date value is a `date` etc.</small>
