# ZenFS Zip Backend

[ZenFS](https://github.com/zen-fs/core) backend for Zip files:

- `Zip` allows you to create a _readonly_ file system from a zip file.
- This fork adds support for the `caseFold` mode option but keeps file names in their original case and still allows case-insensitive lookups.

For more information, see the [API documentation](https://zenfs.dev/archives).

Please read the ZenFS [core documentation](https://zenfs.dev/core/)!

## Installation

```sh
npm install @lvcabral/zip
```

## Usage

The easiest way to get started is by looking at these examples

#### `Zip`

```js
import { configure, fs } from '@lvcabral/zenfs';
import { Zip } from '@lvcabral/zip';

const res = await fetch('http://example.com/archive.zip');

await configure({
	mounts: {
		'/mnt/zip': { backend: Zip, data: await res.arrayBuffer() },
	},
});

const contents = fs.readFileSync('/mnt/zip/in-archive.txt', 'utf-8');
console.log(contents);
```

## License

This project is licensed under the LGPL (v3+). See the [LICENSE](LICENSE.md) file for details.
